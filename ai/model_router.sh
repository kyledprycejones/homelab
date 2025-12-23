#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

: "${MODEL_ROUTER_CONFIG:=ai/config/model_router.yaml}"
: "${ROUTER_STATE_FILE:=ai/state/router_state.json}"
: "${MODEL_ROUTER_LOG_DIR:=logs/router}"

LOG_FILE="${MODEL_ROUTER_LOG_DIR}/router.log"

export MODEL_ROUTER_CONFIG
export ROUTER_STATE_FILE
export ROUTER_LOG_FILE="$LOG_FILE"

if [ ! -f "$MODEL_ROUTER_CONFIG" ]; then
  echo "ERROR: Router config missing: $MODEL_ROUTER_CONFIG" >&2
  exit 1
fi

ensure_directories() {
  mkdir -p "$(dirname "$ROUTER_STATE_FILE")"
  mkdir -p "$MODEL_ROUTER_LOG_DIR"
  if [ ! -s "$ROUTER_STATE_FILE" ]; then
    cat <<'EOF' > "$ROUTER_STATE_FILE"
{
  "providers": {},
  "episode_routes": {},
  "last_updated": null
}
EOF
  fi
}

usage() {
  cat <<EOF
Usage:
  $0 select <role> <error_key> [context_json]
  $0 record_outcome <candidate_key> <outcome> [reason] [extra_json]
  $0 status [role]

Commands:
  select         Determine the next provider/tier/model for the role.
  record_outcome Update circuit breaker/health state after an attempt.
  status         Dump router health/state summary (optional role filter).
EOF
  exit 1
}

ensure_directories

if [ "$#" -lt 1 ]; then
  usage
fi

command="$1"
shift

case "$command" in
  select)
    if [ "$#" -lt 2 ]; then
      usage
    fi
    role="$1"
    error_key="$2"
    context="${3:-{}}"
    python3 - "$role" "$error_key" "$context" <<'PY'
import json
import os
import sys
from datetime import datetime, timedelta, timezone

config_path = os.environ.get("MODEL_ROUTER_CONFIG")
state_path = os.environ.get("ROUTER_STATE_FILE")
log_path = os.environ.get("ROUTER_LOG_FILE")

if not config_path or not state_path:
    print("router configuration not found", file=sys.stderr)
    sys.exit(1)

with open(config_path) as fh:
    config = json.load(fh)

with open(state_path) as fh:
    state = json.load(fh)

state.setdefault("providers", {})
state.setdefault("episode_routes", {})

role, error_key, context_json = sys.argv[1:4]
sticky_cfg = config.get("sticky_routes", {})
role_cfg = config.get("roles", {}).get(role, {})
priority = role_cfg.get("priority", [])
fallback_mode = role_cfg.get("fallback_mode", "safe_mode")
context = {}
try:
    context = json.loads(context_json)
except json.JSONDecodeError:
    context = {}

providers_cfg = config.get("providers", {})
tiers_cfg = config.get("provider_tiers", {})

default_cb = config.get("circuit_breaker", {})
failure_threshold = default_cb.get("failure_threshold", 3)
cooldown_seconds = default_cb.get("cooldown_seconds", 60)

now = datetime.now(timezone.utc)
health_reason = None
cooldown_remaining = None
cooldown_expiry_events = []
sticky_break_event = None

def refresh_provider_health(name, entry):
    global cooldown_expiry_events
    circuit = entry.get("circuit_state", "closed")
    cooldown = entry.get("cooldown_until")
    if circuit != "open" or not cooldown:
        return
    try:
        cooldown_dt = datetime.fromisoformat(cooldown)
    except ValueError:
        return
    if cooldown_dt <= now:
        entry["circuit_state"] = "closed"
        entry["failure_count"] = 0
        entry["cooldown_until"] = None
        entry["health"] = "healthy"
        cooldown_expiry_events.append(name)

def record_health_skip(name, reason_type, cooldown_val=None):
    global health_reason, cooldown_remaining
    if health_reason is not None:
        return
    reason = f"{name}_{reason_type}"
    if cooldown_val:
        try:
            cooldown_dt = datetime.fromisoformat(cooldown_val)
        except ValueError:
            cooldown_dt = None
        if cooldown_dt and cooldown_dt > now:
            remaining = int((cooldown_dt - now).total_seconds())
            if remaining > 0:
                cooldown_remaining = f"{remaining}s"
                reason = f"{name}_{reason_type}_remaining={cooldown_remaining}"
    health_reason = reason

def get_provider_state(key):
    entry = state["providers"].setdefault(key, {})
    refresh_provider_health(key, entry)
    entry.setdefault("health", "healthy")
    entry.setdefault("circuit_state", "closed")
    entry.setdefault("failure_count", 0)
    entry.setdefault("cooldown_until", None)
    entry.setdefault("rate_limit_remaining", None)
    return entry

def provider_is_ready(name):
    entry = get_provider_state(name)
    health = entry.get("health", "healthy")
    if health == "unhealthy":
        return False
    circuit = entry.get("circuit_state", "closed")
    cooldown = entry.get("cooldown_until")
    if circuit == "open":
        if cooldown:
            try:
                cooldown_dt = datetime.fromisoformat(cooldown)
            except ValueError:
                return False
            if cooldown_dt > now:
                return False
        else:
            return False
    if entry.get("rate_limit_remaining") == 0:
        return False
    return True

def provider_has_required_env(name, cfg):
    """v7 requirement: Check if provider has required environment variables."""
    provider_type = cfg.get("provider", name)
    if provider_type == "openrouter" or name.startswith("openrouter"):
        api_key = os.environ.get("OPENROUTER_API_KEY", "")
        if not api_key:
            return False, "missing_env_OPENROUTER_API_KEY"
    return True, None

def provider_has_valid_model(name, cfg):
    """v7 requirement: Providers with no model = misconfigured.

    Exceptions:
    - OpenRouter free tier discovers models dynamically
    - Codex CLI has a default model (no model required)
    """
    model = cfg.get("model", "")
    # Free tiers discover models at runtime - skip model check
    if cfg.get("capacity") == "free":
        return True, None
    # Codex CLI has a built-in default model - no explicit model required
    if name == "codex":
        return True, None
    # Empty string or None means misconfigured
    if not model or model == "None":
        return False, "misconfigured_model_empty"
    return True, None

def provider_has_required_runtime(name, cfg):
    """Ensure Ollama providers are only considered when Ollama is reachable."""
    provider_type = cfg.get("provider", name)
    is_ollama_provider = provider_type == "ollama" or name.startswith("ollama")
    if not is_ollama_provider:
        return True, None
    if os.environ.get("OLLAMA_UNREACHABLE", "") == "1":
        entry = state.setdefault("providers", {}).setdefault(name, {})
        entry["health"] = "unhealthy"
        entry["last_failure_reason"] = "ollama_unreachable"
        return False, "ollama_unreachable"
    return True, None

def provider_has_valid_output_contract(name, cfg):
    """v7 requirement: Skip providers that recently returned invalid architect output."""
    entry = state.get("providers", {}).get(name, {})
    if entry.get("last_failure_reason") == "invalid_output":
        return False, "invalid_output"
    return True, None

def provider_enabled(cfg):
    if not cfg:
        return True
    return cfg.get("enabled", True)

for provider_name, provider_entry in state["providers"].items():
    refresh_provider_health(provider_name, provider_entry)

def drop_sticky_route():
    episode = state.get("episode_routes", {}).get(error_key, {})
    if not episode or role not in episode:
        return
    episode.pop(role, None)
    if episode:
        state["episode_routes"][error_key] = episode
    else:
        state["episode_routes"].pop(error_key, None)

def sticky_route():
    global sticky_break_event
    if not sticky_cfg.get("enabled", True):
        return None, None
    episode = state["episode_routes"].get(error_key, {})
    route = episode.get(role)
    if not route:
        return None, None
    selected = route.get("candidate")
    if not selected:
        return None, None
    config_entry = providers_cfg.get(selected) or tiers_cfg.get(selected, {})
    if not provider_enabled(config_entry):
        record_health_skip(selected, "disabled")
        return None, None
    has_runtime, runtime_reason = provider_has_required_runtime(selected, config_entry)
    if not has_runtime:
        record_health_skip(selected, runtime_reason)
        sticky_break_event = {"candidate": selected, "reason": runtime_reason}
        drop_sticky_route()
        return None, None
    info = get_provider_state(selected)
    cooldown = info.get("cooldown_until")
    if cooldown:
        cooldown_dt = datetime.fromisoformat(cooldown)
        if cooldown_dt > now:
            return None, None
    health = info.get("health", "unknown")
    if health == "unhealthy":
        return None, None
    # v7 guardrail: Break sticky route on missing env
    has_env, env_reason = provider_has_required_env(selected, config_entry)
    if not has_env:
        record_health_skip(selected, env_reason)
        return None, None
    # v7 guardrail: Break sticky route on misconfigured (empty model)
    sticky_model = route.get("model", config_entry.get("model", ""))
    if not sticky_model or sticky_model == "None":
        record_health_skip(selected, "misconfigured_model_empty")
        return None, None
    # v7 guardrail: Break sticky route if provider failed output contract
    has_output_contract, output_reason = provider_has_valid_output_contract(selected, config_entry)
    if not has_output_contract:
        record_health_skip(selected, output_reason)
        return None, None
    # v7 requirement: Codex-first when healthy. If Codex is ready, prefer it even if sticky route says otherwise.
    if role == "executor" and selected != "codex":
        if provider_is_ready("codex"):
            return None, None  # Break sticky route, let priority selection choose Codex
    return selected, route

sticky_candidate, sticky_route_data = sticky_route()
if sticky_candidate:
    selected_name = sticky_candidate
    selected_cfg = providers_cfg.get(selected_name) or tiers_cfg.get(selected_name, {})
    selected_cfg = dict(selected_cfg)
    selected_cfg["model"] = sticky_route_data.get("model", selected_cfg.get("model", ""))
    reason = "sticky"
else:
    candidates = []
    for name in priority:
        entry = {}
        if name in tiers_cfg:
            tier = tiers_cfg[name]
            entry.update(tier)
            entry["candidate"] = name
            entry["tier_name"] = name
            entry["capacity"] = tier.get("capacity", "")
            entry["model"] = tier.get("preferred_models", [None])[0]
        elif name in providers_cfg:
            provider = providers_cfg[name]
            entry.update(provider)
            entry["candidate"] = name
            entry["tier_name"] = provider.get("tier", "default")
            entry.setdefault("model", "")
            if provider.get("local_model_preferences"):
                prefs = provider["local_model_preferences"]
                entry["model"] = prefs[0] if prefs else entry["model"]
        else:
            continue

        entry.setdefault("availability_weight", 0.0)
        entry.setdefault("capability_score", 0.0)
        entry.setdefault("cost_weight", 0.0)
        entry.setdefault("latency_ms", 0)
        if not provider_enabled(entry):
            record_health_skip(entry["candidate"], "disabled")
            continue
        has_runtime, runtime_reason = provider_has_required_runtime(entry["candidate"], entry)
        if not has_runtime:
            record_health_skip(entry["candidate"], runtime_reason)
            continue
        # v7 preflight: Check required environment variables
        has_env, env_reason = provider_has_required_env(entry["candidate"], entry)
        if not has_env:
            record_health_skip(entry["candidate"], env_reason)
            continue
        # v7 rule: No model = misconfigured (skip provider)
        has_model, model_reason = provider_has_valid_model(entry["candidate"], entry)
        if not has_model:
            record_health_skip(entry["candidate"], model_reason)
            continue
        # v7 rule: Providers must honor the architect output contract
        has_output_contract, output_reason = provider_has_valid_output_contract(entry["candidate"], entry)
        if not has_output_contract:
            record_health_skip(entry["candidate"], output_reason)
            continue
        entry["_is_paid"] = entry.get("capacity") != "free"
        state_entry = get_provider_state(entry["candidate"])
        if state_entry.get("health") == "unhealthy":
            record_health_skip(entry["candidate"], "unhealthy")
            continue
        circuit = state_entry.get("circuit_state", "closed")
        cooldown = state_entry.get("cooldown_until")
        if circuit == "open" and cooldown:
            if datetime.fromisoformat(cooldown) > now:
                record_health_skip(entry["candidate"], "cooldown", cooldown)
                continue
        rate_limit = state_entry.get("rate_limit_remaining")
        if rate_limit == 0:
            record_health_skip(entry["candidate"], "rate_limited")
            continue
        score = entry["availability_weight"] + entry["capability_score"] - entry["cost_weight"]
        entry["_score"] = score
        entry["_health"] = state_entry.get("health")
        entry["_circuit"] = circuit
        candidates.append(entry)

    if candidates:
        selected = None
        if role == "architect" and os.environ.get("OLLAMA_UNREACHABLE", "") == "1":
            for override_candidate in ("openrouter_free", "openrouter_paid"):
                for candidate_entry in candidates:
                    if candidate_entry["candidate"] == override_candidate:
                        selected = candidate_entry
                        break
                if selected:
                    break
        if not selected:
            candidates.sort(key=lambda c: (
                -c["_score"],
                not c.get("_is_paid", False),
                c.get("latency_ms", 0),
                c["candidate"]
            ))
            selected = candidates[0]
        selected_name = selected["candidate"]
        selected_cfg = selected
        reason = "priority"
    else:
        print(f"fallback_mode={fallback_mode}")
        sys.exit(2)

episode = state["episode_routes"].setdefault(error_key, {})
episode[role] = {
    "candidate": selected_name,
    "tier": selected_cfg.get("tier_name", selected_name),
    "model": selected_cfg.get("model", ""),
    "selected_at": now.isoformat(),
    "reason": reason,
}

state["last_updated"] = now.isoformat()

tmp_path = f"{state_path}.tmp"
with open(tmp_path, "w") as fh:
    json.dump(state, fh, indent=2)
os.replace(tmp_path, state_path)

logged_health_reason = health_reason or "healthy"
cooldown_str = cooldown_remaining or "0s"
if selected_name == "codex":
    final_reason = health_reason or "healthy_preferred"
else:
    final_reason = health_reason or "priority"

if log_path:
    with open(log_path, "a") as logfh:
        logfh.write(
            f"[{now.isoformat()}] role={role.upper()} error_key={error_key} selected={selected_name} model={selected_cfg.get('model','')} reason={final_reason} selection_reason={reason} health_reason={logged_health_reason} cooldown_remaining={cooldown_str}\n"
        )
        for provider_name in cooldown_expiry_events:
            logfh.write(
                f"[{now.isoformat()}] provider={provider_name} role={role.upper()} event=cooldown_expired reason=reset_after_expiry\n"
            )
        if sticky_break_event:
            logfh.write(
                f"[{now.isoformat()}] role={role.upper()} event=sticky_broken candidate={sticky_break_event['candidate']} reason={sticky_break_event['reason']}\n"
            )

print(f"provider={selected_name}")
print(f"service={selected_cfg.get('provider', selected_name)}")
print(f"tier={selected_cfg.get('tier_name', selected_name)}")
print(f"model={selected_cfg.get('model', '')}")
print(f"reason={reason}")
print(f"score={selected_cfg.get('_score', 0.0):.3f}")
print(f"health_reason={logged_health_reason}")
print(f"cooldown_remaining={cooldown_str}")
PY
    ;;
  record_outcome)
    if [ "$#" -lt 2 ]; then
      usage
    fi
    candidate_key="$1"
    outcome="$2"
    reason="${3:-}"
    extra_json="${4:-{}}"
    python3 - "$candidate_key" "$outcome" "$reason" "$extra_json" <<'PY'
import json
import os
import sys
from datetime import datetime, timedelta, timezone

config_path = os.environ.get("MODEL_ROUTER_CONFIG")
state_path = os.environ.get("ROUTER_STATE_FILE")
log_path = os.environ.get("ROUTER_LOG_FILE")

if not config_path or not state_path:
    print("router configuration not found", file=sys.stderr)
    sys.exit(1)

with open(config_path) as fh:
    config = json.load(fh)

with open(state_path) as fh:
    state = json.load(fh)

state.setdefault("providers", {})
state.setdefault("episode_routes", {})

candidate_key, outcome, reason, extra = sys.argv[1:5]
extra_data = {}
try:
    extra_data = json.loads(extra)
except json.JSONDecodeError:
    extra_data = {}

cb_cfg = config.get("circuit_breaker", {})
failure_threshold = cb_cfg.get("failure_threshold", 3)
cooldown_seconds = cb_cfg.get("cooldown_seconds", 60)

now = datetime.now(timezone.utc)

entry = state["providers"].setdefault(candidate_key, {
    "health": "healthy",
    "circuit_state": "closed",
    "failure_count": 0,
    "cooldown_until": None,
    "last_transition": None,
})

if outcome == "success":
    entry["health"] = "healthy"
    entry["circuit_state"] = "closed"
    entry["failure_count"] = 0
else:
    entry["failure_count"] = entry.get("failure_count", 0) + 1
    if reason == "misconfigured_model":
        entry["health"] = "unhealthy"
        entry["circuit_state"] = "open"
        entry["failure_count"] = max(entry["failure_count"], failure_threshold)
        entry["cooldown_until"] = None
    elif reason in ("provider_failure", "invalid_output"):
        entry["health"] = "unhealthy"
        entry["circuit_state"] = "open"
        entry["failure_count"] = max(entry["failure_count"], failure_threshold)
        entry["cooldown_until"] = (now + timedelta(seconds=cooldown_seconds)).isoformat()
    else:
        if entry["failure_count"] >= failure_threshold:
            entry["circuit_state"] = "open"
            entry["cooldown_until"] = (now + timedelta(seconds=cooldown_seconds)).isoformat()
        else:
            entry["circuit_state"] = "closed"
        entry["health"] = "degraded"

if "rate_limit_remaining" in extra_data:
    entry["rate_limit_remaining"] = extra_data["rate_limit_remaining"]

entry["last_transition"] = now.isoformat()
if reason:
    entry["last_failure_reason"] = reason

state["last_updated"] = now.isoformat()

tmp_path = f"{state_path}.tmp"
with open(tmp_path, "w") as fh:
    json.dump(state, fh, indent=2)
os.replace(tmp_path, state_path)

if log_path:
    with open(log_path, "a") as logfh:
        logfh.write(
            f"[{now.isoformat()}] outcome candidate={candidate_key} result={outcome} reason={reason}\n"
        )

print("recorded")
PY
    ;;
  status)
    role_filter="${1:-}"
    python3 - "$role_filter" <<'PY'
import json
import os
import sys

state_path = os.environ.get("ROUTER_STATE_FILE")
config_path = os.environ.get("MODEL_ROUTER_CONFIG")

if not state_path or not config_path:
    print("router configuration missing", file=sys.stderr)
    sys.exit(1)

with open(state_path) as fh:
    state = json.load(fh)

with open(config_path) as fh:
    config = json.load(fh)

role_filter = sys.argv[1]
providers = state.get("providers", {})
roles = config.get("roles", {})

if role_filter:
    candidates = roles.get(role_filter, {}).get("priority", [])
    filtered = {k: providers.get(k, {}) for k in candidates}
else:
    filtered = providers

print(json.dumps(filtered, indent=2))
PY
    ;;
  *)
    usage
    ;;
esac
