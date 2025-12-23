#!/usr/bin/env bash
# Orchestrator v7 - Bootstrap Loop (Plumbing Layer)
#
# This script is the main entry point for running stages and v7 convergence.
# It is deliberately "dumb" - runs commands, logs results, computes error hashes,
# and decides when to escalate. It does NOT make intelligent decisions.
#
# Usage: ./ai/bootstrap_loop.sh <command> [options]
#
# Commands:
#   converge        - v7 memo-driven convergence mode (recommended)
#   <stage>         - Legacy stage-based mode (vms, k3s, infra, apps, ingress, obs)
#   all             - Run all stages in order (legacy)
#   status          - Show current status
#
# Safety: This file is considered plumbing and should only be modified by humans.
# AI MUST NOT modify this file during convergence.
# See docs/orchestrator_v7.txt for the authoritative specification.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# =============================================================================
# Configuration
# =============================================================================
: "${CONTEXT_MAP:=ai/context_map.yaml}"
: "${STATE_DIR:=ai/state}"
: "${LOG_DIR:=logs}"
: "${ESCALATION_DIR:=logs/ai/escalations}"
: "${ERRORS_JSON:=${STATE_DIR}/errors.json}"
: "${STAGE_STATUS_JSON:=${STATE_DIR}/stage_status.json}"
: "${EXECUTOR_RUNNER:=ai/executor_runner.sh}"
: "${CASE_FILE_GENERATOR:=ai/scripts/case_file_generator.sh}"
: "${DIAGNOSTICS_RUNNER:=ai/scripts/diagnostics/diagnostics_runner.sh}"
: "${CLUSTER_CONFIG_FILE:=config/clusters/prox-n100.yaml}"
: "${DIAGNOSTICS_COMMAND_TIMEOUT:=30}"
: "${ISSUES_FILE:=ai/issues.yaml}"
: "${MODEL_ROUTER_CONFIG:=ai/config/model_router.yaml}"
: "${MODEL_ROUTER_CMD:=ai/model_router.sh}"
: "${SAFE_MODE_SUMMARY:=ai/state/safe_mode_summary.json}"
: "${ROUTER_STATE_FILE:=ai/state/router_state.json}"
: "${OPENROUTER_PROVIDER_CMD:=ai/providers/openrouter.sh}"
: "${PREFLIGHT_SCRIPT:=ai/preflight/preflight_tools.sh}"

# v7 Drift Engine and Convergence
: "${DRIFT_ENGINE:=ai/drift_engine.py}"
: "${ARCHITECTURE_MEMO:=docs/master_memo.txt}"
: "${DRIFT_STATE_FILE:=ai/state/drift.json}"
: "${NOW_STATE_FILE:=ai/state/now.json}"
: "${TIMELINE_FILE:=ai/state/timeline.json}"
: "${MAX_CONVERGE_CYCLES:=50}"
: "${CLAIM_ATTEMPT_THRESHOLD:=3}"
: "${MAX_ARCHITECT_PROVIDER_FAILOVERS:=3}"

# =============================================================================
# v7 Environment Loading - Load secrets for providers
# =============================================================================
: "${OPENROUTER_SECRETS_FILE:=config/secrets/openrouter.env}"
if [ -f "$OPENROUTER_SECRETS_FILE" ]; then
  # shellcheck disable=SC1090
  source "$OPENROUTER_SECRETS_FILE"
fi

# Export for child processes (router, providers)
export OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"

__safe_mode_cfg=()
while IFS= read -r line; do
  __safe_mode_cfg+=("$line")
done < <(python3 - "$MODEL_ROUTER_CONFIG" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    cfg = json.load(open(path))
except Exception:
    print(3)
    print(2)
    print(5)
    print(30)
    sys.exit(0)

safe = cfg.get("safe_mode", {})
print(safe.get("patch_failure_threshold", 3))
print(safe.get("no_effect_threshold", 2))
print(safe.get("max_cycles_no_new_evidence", 5))
print(safe.get("max_duration_minutes", 30))
PY
)
SAFE_MODE_PATCH_FAILURE_THRESHOLD="${__safe_mode_cfg[0]:-3}"
SAFE_MODE_NO_EVIDENCE_THRESHOLD="${__safe_mode_cfg[1]:-2}"
SAFE_MODE_MAX_CYCLES="${__safe_mode_cfg[2]:-5}"
SAFE_MODE_MAX_DURATION_MINUTES="${__safe_mode_cfg[3]:-30}"

# Escalation thresholds
: "${EXECUTOR_RETRY_THRESHOLD:=3}"
: "${API_CALL_BUDGET:=3}"

# Branch for AI-driven changes
: "${AI_BRANCH:=ai/orchestrator-stage1}"

# Transient failure backoff settings
: "${TRANSIENT_BACKOFF_1:=30}"
: "${TRANSIENT_BACKOFF_2:=60}"
: "${TRANSIENT_BACKOFF_3:=120}"

# Patch size limit (lines changed)
: "${PATCH_SIZE_LIMIT:=100}"

# Lock file for atomic state updates
LOCK_DIR="${STATE_DIR}/.lockdir"
LOCK_INFO="${LOCK_DIR}/lock.info"

CURRENT_STAGE_IN_PROGRESS=""

# Protected files that patches cannot modify (v7 canonical list)
# Source of truth: ai/config/config.yaml (protected_files)
# Keep in sync with drift_engine.py
PROTECTED_FILES=(
  "docs/master_memo.txt"
  "docs/master_memo.md"
  "ai/context_map.yaml"
  "ai/bootstrap_loop.sh"
  "ai/drift_engine.py"
  "infrastructure/proxmox/wipe_proxmox.sh"
)

# Allowlisted paths for modifications
ALLOWED_PATHS=(
  "ai/"
  "infrastructure/"
  "cluster/"
  "apps/"
  "docs/"
)

GIVE_UP_STATE_FILE="${STATE_DIR}/give_up.json"
LAST_STAGE_FAILURE_COMMAND=""
LAST_STAGE_FAILURE_LOG=""
LAST_STAGE_PROBE_SUMMARY=""

: "${OLLAMA_HEALTH_ENDPOINT:=http://localhost:11434/api/tags}"
: "${OLLAMA_REACHABILITY_TTL:=30}"
: "${OLLAMA_REACHABILITY_CACHE:=${STATE_DIR}/ollama_reachability.cache}"
export OLLAMA_UNREACHABLE=0

# =============================================================================
# Helpers
# =============================================================================
log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[%s] %s\n' "$ts" "$*"
}

log_to_file() {
  local file="$1"
  shift
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[%s] %s\n' "$ts" "$*" >> "$file"
}

announce_attempt_brief() {
  local msg="--- Attempt $1 ---"
  printf '%s\n' "$msg" || true
}

announce_attempt_with_key() {
  local attempt="$1"
  local error_key="$2"
  local msg="--- Attempt $attempt (error_key=$error_key) ---"
  printf '%s\n' "$msg" || true
}

announce_stage_command() {
  printf '[stage] Running %s\n' "$1"
}

announce_stage_success() {
  printf '[stage] %s completed successfully\n' "$1"
}

announce_stage_failure() {
  printf '[stage] %s failed (rc=%s)\n' "$1" "$2"
}

clear_current_stage_progress() {
  CURRENT_STAGE_IN_PROGRESS=""
}

announce_executor_invocation() {
  local attempt="$1"
  local provider="${EXECUTOR_PROVIDER:-unknown}"
  local model="${EXECUTOR_PROVIDER_MODEL:-}"
  printf '[executor] Provider: %s\n' "$provider"
  printf '[executor] Role: EXECUTOR\n'
  if [ -n "$model" ]; then
    printf '[executor] Model: %s\n' "$model"
  fi
  printf '[executor] Attempt: %s\n' "$attempt"
}

announce_executor_tooling_failure() {
  local rc="$1"
  local provider="${EXECUTOR_PROVIDER:-unknown}"
  printf '[executor] Tooling failure: %s (rc=%s)\n' "$provider" "$rc"
}

announce_executor_no_patch() {
  local provider="${EXECUTOR_PROVIDER:-unknown}"
  local model="${EXECUTOR_PROVIDER_MODEL:-}"
  if [ -n "$model" ]; then
    printf '[executor] %s (%s) returned no_patch\n' "$provider" "$model"
  else
    printf '[executor] %s returned no_patch\n' "$provider"
  fi
  printf '[executor] Outcome: attempt consumed (no patch generated)\n'
  printf '[executor] Exit reason: no_patch\n'
  printf '[executor] Provider: %s (healthy)\n' "$provider"
}

announce_executor_patch_generated() {
  local lines="$1"
  printf '[executor] Patch generated (%s lines changed)\n' "$lines"
}

announce_diagnostics_running() {
  printf '[diagnostics] Running diagnostics for stage %s\n' "$1"
}

announce_give_up() {
  local stage="$1"
  local attempts="$2"
  printf '[orchestrator] %s reached give_up after %s attempts\n' "$stage" "$attempts"
  printf '[orchestrator] See ai/issues.yaml and logs/ai/escalations/\n'
}

ensure_directories() {
  mkdir -p "$STATE_DIR" "$LOG_DIR" "$ESCALATION_DIR"
  # Canonical logs structure: logs/stages/<stage>, logs/provider, logs/diagnostics, etc.
  mkdir -p "$LOG_DIR/stages/k3s" "$LOG_DIR/stages/vms" "$LOG_DIR/stages/infra"
  mkdir -p "$LOG_DIR/stages/apps" "$LOG_DIR/stages/ingress" "$LOG_DIR/stages/obs"
  mkdir -p "$LOG_DIR/diagnostics" "$LOG_DIR/provider" "$LOG_DIR/executor" "$LOG_DIR/router" "$LOG_DIR/runs"
  mkdir -p "$(dirname "$ISSUES_FILE")"
  touch "$ISSUES_FILE" 2>/dev/null || true
}

record_ollama_unreachable_issue() {
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$ISSUES_FILE")"
  printf '\n- timestamp: %s\n  type: provider_unreachable\n  provider: ollama\n  reason: ollama_unreachable\n  message: "Ollama unreachable; routing will skip Ollama providers."\n' \
    "$timestamp" >> "$ISSUES_FILE"
}

refresh_ollama_reachability() {
  local now last_ts last_status last_notified
  local should_check status notify_status timestamp update_cache
  now="$(date +%s)"
  last_ts=""
  last_status=""
  last_notified=""
  if [ -f "$OLLAMA_REACHABILITY_CACHE" ]; then
    if read -r last_ts last_status last_notified < "$OLLAMA_REACHABILITY_CACHE"; then
      :
    fi
  fi
  should_check=1
  if [ -n "$last_ts" ]; then
    if [ "$((now - last_ts))" -lt "$OLLAMA_REACHABILITY_TTL" ]; then
      should_check=0
    fi
  fi
  status="${last_status:-}"
  notify_status="${last_notified:-}"
  timestamp="$last_ts"

  if [ "$should_check" -eq 1 ]; then
    set +e
    if curl -sS --max-time 1 "$OLLAMA_HEALTH_ENDPOINT" >/dev/null 2>&1; then
      status="reachable"
    else
      status="unreachable"
    fi
    set -e
    timestamp="$now"
  fi

  status="${status:-reachable}"
  update_cache=0
  if [ "$status" = "unreachable" ] && [ "$notify_status" != "unreachable" ]; then
    log "Ollama unreachable -> routing will skip Ollama providers"
    record_ollama_unreachable_issue
    notify_status="unreachable"
    update_cache=1
  elif [ "$status" != "unreachable" ] && [ "$notify_status" != "reachable" ]; then
    notify_status="reachable"
    update_cache=1
  fi
  if [ "$should_check" -eq 1 ]; then
    update_cache=1
  fi
  if [ "$update_cache" -eq 1 ]; then
    mkdir -p "$(dirname "$OLLAMA_REACHABILITY_CACHE")"
    printf '%s %s %s\n' "$timestamp" "$status" "${notify_status:-}" > "$OLLAMA_REACHABILITY_CACHE"
  fi
  if [ "$status" = "unreachable" ]; then
    export OLLAMA_UNREACHABLE=1
  else
    export OLLAMA_UNREACHABLE=0
  fi
}

SELECTED_PROVIDER=""
SELECTED_SERVICE=""
SELECTED_TIER=""
SELECTED_MODEL=""
SELECTED_REASON=""
SELECTED_SCORE=""
SELECTOR_FALLBACK_MODE=""
LAST_EXECUTOR_SUMMARY_STATUS=""
LAST_EXECUTOR_SUMMARY_RC=""
SELECTED_HEALTH_REASON=""
SELECTED_COOLDOWN_REMAINING=""

router_select_provider() {
  local role="$1"
  local error_key="$2"
  local context="${3:-{}}"
  refresh_ollama_reachability
  local output
  output="$("$MODEL_ROUTER_CMD" select "$role" "$error_key" "$context" 2>&1)" || true
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    SELECTOR_FALLBACK_MODE="$(printf '%s\n' "$output" | awk -F= '/^fallback_mode/ {print $2}')"
    SELECTED_PROVIDER=""
    return "$rc"
  fi
  SELECTOR_FALLBACK_MODE=""
  SELECTED_PROVIDER=""
  SELECTED_SERVICE=""
  SELECTED_HEALTH_REASON=""
  SELECTED_COOLDOWN_REMAINING=""
  while IFS='=' read -r key value; do
    case "$key" in
      provider) SELECTED_PROVIDER="$value" ;;
      service) SELECTED_SERVICE="$value" ;;
      tier) SELECTED_TIER="$value" ;;
      model) SELECTED_MODEL="$value" ;;
      reason) SELECTED_REASON="$value" ;;
      health_reason) SELECTED_HEALTH_REASON="$value" ;;
      cooldown_remaining) SELECTED_COOLDOWN_REMAINING="$value" ;;
      score) SELECTED_SCORE="$value" ;;
    esac
  done <<< "$output"
  return 0
}

router_record_outcome() {
  local provider="$1"
  local outcome="$2"
  local reason="$3"
  local extra="${4:-{}}"
  "$MODEL_ROUTER_CMD" record_outcome "$provider" "$outcome" "$reason" "$extra" >/dev/null 2>&1 || true
}

break_router_sticky_route() {
  local role="$1"
  local error_key="$2"
  if [ -z "$ROUTER_STATE_FILE" ]; then
    return
  fi
  python3 - "$ROUTER_STATE_FILE" "$role" "$error_key" <<'PY'
import json, sys, os

path, role, key = sys.argv[1:4]
try:
    data = json.load(open(path))
except (FileNotFoundError, json.JSONDecodeError):
    sys.exit(0)

episode_routes = data.get("episode_routes", {})
episode = episode_routes.get(key, {})
if not episode or role not in episode:
    sys.exit(0)

episode.pop(role, None)
if episode:
    episode_routes[key] = episode
else:
    episode_routes.pop(key, None)

data["episode_routes"] = episode_routes
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
PY
}

are_all_executor_providers_unhealthy() {
  python3 - "$MODEL_ROUTER_CONFIG" "$ROUTER_STATE_FILE" <<'PY'
import json
import sys
import os

config_path, state_path = sys.argv[1], sys.argv[2]
try:
    with open(config_path) as cfgf:
        config = json.load(cfgf)
except (json.JSONDecodeError, FileNotFoundError):
    print("false")
    sys.exit(0)
try:
    with open(state_path) as sf:
        state = json.load(sf)
except (json.JSONDecodeError, FileNotFoundError):
    state = {}

executors = config.get("roles", {}).get("executor", {}).get("priority", [])
providers = state.get("providers", {})

for candidate in executors:
    entry = providers.get(candidate, {})
    health = entry.get("health", "healthy")
    circuit = entry.get("circuit_state", "closed")
    if health in ("healthy", "degraded") and circuit != "open":
        print("false")
        sys.exit(0)
print("true")
PY
}

set_orchestrator_status() {
  local status_value="$1"
  local reason="$2"
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  python3 - "$STATE_DIR/status.json" "$status_value" "$reason" "$timestamp" <<'PY'
import json
import os
import sys

path, status_value, reason, ts = sys.argv[1:5]
data = {}
if os.path.exists(path):
    try:
        with open(path) as fh:
            data = json.load(fh)
    except json.JSONDecodeError:
        data = {}
data["orchestrator_status"] = status_value
data["safe_mode_reason"] = reason
data["safe_mode_timestamp"] = ts
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
PY
}

enter_safe_mode() {
  local reason="$1"
  local stage="$2"
  local error_key="$3"
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local executor_health
  executor_health="$("$MODEL_ROUTER_CMD" status executor 2>/dev/null || echo '{}')"

  python3 - "$SAFE_MODE_SUMMARY" "$stage" "$error_key" "$reason" "$executor_health" "$timestamp" <<'PY'
import json
import sys
import os

path, stage, error_key, reason, executor_health, timestamp = sys.argv[1:7]
try:
    executor_state = json.loads(executor_health)
except json.JSONDecodeError:
    executor_state = executor_health
summary = {
    "mode": "safe",
    "entered_at": timestamp,
    "stage": stage,
    "error_key": error_key,
    "reason": reason,
    "executor_health": executor_state
}
with open(path, "w") as fh:
    json.dump(summary, fh, indent=2)
PY

  printf '[%s] SAFE MODE: %s (stage=%s error_key=%s)\n' "$timestamp" "$reason" "$stage" "$error_key" >> "$ISSUES_FILE"
  set_orchestrator_status "halted_safe_mode" "$reason"
  enter_stage_give_up "$stage" "Safe mode triggered ($reason); inspect logs before retrying."
  clear_current_stage_progress
  return 1
}

# =============================================================================
# Secret Redaction (CRITICAL - v5 requirement)
# =============================================================================
redact_secrets() {
  sed -E '
    s/sk-[a-zA-Z0-9]+/[REDACTED]/g
    s/Bearer [a-zA-Z0-9._-]+/Bearer [REDACTED]/g
    s/-----BEGIN [A-Z ]+ PRIVATE KEY-----[^-]*-----END [A-Z ]+ PRIVATE KEY-----/[REDACTED PEM BLOCK]/g
    s/certificate-authority-data:[[:space:]]*[^[:space:]]+/certificate-authority-data: [REDACTED]/g
    s/client-certificate-data:[[:space:]]*[^[:space:]]+/client-certificate-data: [REDACTED]/g
    s/client-key-data:[[:space:]]*[^[:space:]]+/client-key-data: [REDACTED]/g
    s/token:[[:space:]]*[a-zA-Z0-9._-]+/token: [REDACTED]/g
    s/password[=:][^[:space:]]+/password=[REDACTED]/gi
    s/secret[=:][^[:space:]]+/secret=[REDACTED]/gi
  ' || true
}

# =============================================================================
# Log Normalization (v5 requirement for stable error hashes)
# =============================================================================
normalize_log() {
  sed -E '
    s/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[^ ]* //g
    s/attempt[ _]?[0-9]+//gi
    s/retry[ _#]?[0-9]+//gi
    s|/tmp/[^ ]*||g
    s|/var/folders/[^ ]*||g
    s/\x1b\[[0-9;]*m//g
    s/[[:space:]]+/ /g
    s/^[[:space:]]+//
    s/[[:space:]]+$//
  ' || true
}

# =============================================================================
# Error Signature Extraction (v5: first fatal line + last 60 lines)
# =============================================================================
extract_error_signature() {
  local log_file="$1"
  local fatal_line tail_lines
  # Find first fatal/error line
  fatal_line="$(grep -i -m1 -E '(error:|fatal:|failed:|panic:|exited with code [1-9])' "$log_file" 2>/dev/null || true)"
  # Get last 60 lines
  tail_lines="$(tail -n 60 "$log_file" 2>/dev/null || true)"
  if [ -n "$fatal_line" ]; then
    printf '%s\n%s' "$fatal_line" "$tail_lines"
  else
    tail -n 100 "$log_file" 2>/dev/null || true  # fallback
  fi
}

# =============================================================================
# Transient Failure Detection (v5 requirement)
# =============================================================================
is_transient_failure() {
  local log_file="$1"
  # Check for transient error patterns in the last 50 lines
  if { tail -n 50 "$log_file" 2>/dev/null || true; } | grep -qiE '(connection refused|connection timed out|name resolution failed|context deadline exceeded|i/o timeout|no route to host|network unreachable)'; then
    return 0  # true - is transient
  fi
  return 1  # false - not transient
}

handle_transient_failure() {
  local stage="$1"
  local backoff_attempt="$2"

  case "$backoff_attempt" in
    1)
      log "Transient failure detected. Waiting ${TRANSIENT_BACKOFF_1}s (backoff 1/3)"
      sleep "$TRANSIENT_BACKOFF_1"
      ;;
    2)
      log "Transient failure persists. Waiting ${TRANSIENT_BACKOFF_2}s (backoff 2/3)"
      sleep "$TRANSIENT_BACKOFF_2"
      ;;
    3)
      log "Transient failure persists. Waiting ${TRANSIENT_BACKOFF_3}s (backoff 3/3)"
      sleep "$TRANSIENT_BACKOFF_3"
      ;;
    *)
      log "Transient backoff exhausted. Proceeding with normal error handling."
      return 1
      ;;
  esac
  return 0
}

cleanup_stale_lock() {
  if [ ! -d "$LOCK_DIR" ] || [ ! -f "$LOCK_INFO" ]; then
    return
  fi

  local existing_pid existing_started
  existing_pid="$(grep -E '^pid=' "$LOCK_INFO" 2>/dev/null | cut -d'=' -f2)"
  existing_started="$(grep -E '^started=' "$LOCK_INFO" 2>/dev/null | cut -d'=' -f2)"

  if [ -z "$existing_pid" ]; then
    return
  fi

  if kill -0 "$existing_pid" >/dev/null 2>&1; then
    return
  fi

  local lock_age
  lock_age="$(
printf '%s' "$existing_started" | python3 <<'PY'
import datetime, sys

timestamp = sys.stdin.read().strip()
try:
    started = datetime.datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ")
    now = datetime.datetime.utcnow()
    delta = int((now - started).total_seconds())
    if delta < 0:
        delta = 0
    print(delta)
except Exception:
    print(0)
PY
  )"

  log "Clearing stale lock $LOCK_DIR (pid=${existing_pid:-unknown} age=${lock_age}s) because pid not running"
  rm -rf "$LOCK_DIR" >/dev/null 2>&1 || true
}

# =============================================================================
# Atomic State Updates (v5 requirement - file locking)
# =============================================================================
acquire_lock() {
  cleanup_stale_lock
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    {
      printf 'pid=%s\nstarted=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$LOCK_INFO"
    return 0
  fi

  log "ERROR: Could not acquire state lock. Another orchestrator may be running."
  if [ -f "$LOCK_INFO" ]; then
    log "Lock info:"
    cat "$LOCK_INFO"
  fi
  return 1
}

release_lock() {
  rm -f "$LOCK_INFO" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

# =============================================================================
# Diagnostics helpers
# =============================================================================
get_stage_diagnostics() {
  local stage="$1"
  if [ ! -f "$CONTEXT_MAP" ]; then
    return
  fi

  python3 - "$CONTEXT_MAP" "$stage" <<'PY'
import sys
import re

path, stage = sys.argv[1:3]

def emit_from_yaml():
    try:
        import yaml
    except ImportError:
        return False
    try:
        with open(path) as f:
            data = yaml.safe_load(f) or {}
    except Exception:
        return False
    stages = data.get("stages", {})
    stage_data = stages.get(stage, {})
    diag = stage_data.get("diagnostics", [])
    if isinstance(diag, list):
        for entry in diag:
            if entry:
                print(entry)
    elif diag:
        print(diag)
    return True

if emit_from_yaml():
    sys.exit(0)

with open(path) as f:
    lines = f.readlines()

stage_pattern = re.compile(r'^\\s*' + re.escape(stage) + r'\\s*:\\s*$')
diag_pattern = re.compile(r'^\\s*diagnostics\\s*:\\s*$')
item_pattern = re.compile(r'^\\s*-\\s*(.+)$')

in_stage = False
stage_indent = 0
in_diag = False
diag_indent = 0

for line in lines:
    if not in_stage:
        if stage_pattern.match(line):
            in_stage = True
            stage_indent = len(line) - len(line.lstrip())
        continue

    if not in_diag:
        if diag_pattern.match(line):
            in_diag = True
            diag_indent = len(line) - len(line.lstrip())
        elif line.strip() and (len(line) - len(line.lstrip()) <= stage_indent):
            break
        continue

    stripped = line.strip()
    if not stripped:
        continue
    indent = len(line) - len(line.lstrip())
    if indent <= diag_indent and not stripped.startswith("-"):
        break
    match = item_pattern.match(line)
    if match:
        print(match.group(1).strip())
PY
}

get_controller_ip() {
  if [ ! -f "$CLUSTER_CONFIG_FILE" ]; then
    return
  fi

  python3 - "$CLUSTER_CONFIG_FILE" <<'PY'
import sys
import re

path = sys.argv[1]
block_pattern = re.compile(r'^(?P<indent>[ \\t]*)controller\\s*:\\s*$')
key_pattern = re.compile(r'^[ \\t]*ip\\s*:\\s*(\\S+)\\s*$')
inside = False
block_indent = 0

try:
    with open(path) as fh:
        for line in fh:
            if not inside:
                match = block_pattern.match(line)
                if match:
                    inside = True
                    block_indent = len(match.group('indent'))
                continue
            if not line.strip():
                continue
            indent = len(line) - len(line.lstrip())
            if indent <= block_indent:
                break
            match = key_pattern.match(line)
            if match:
                print(match.group(1).strip())
                sys.exit(0)
except FileNotFoundError:
    pass
PY
}

load_stage_env_for_diagnostics() {
  local ctrl_ip
  ctrl_ip="$(get_controller_ip)"
  if [ -n "$ctrl_ip" ]; then
    CTRL_IP="$ctrl_ip"
    export CTRL_IP
  fi
}

run_stage_diagnostics() {
  local stage="$1"
  local attempt="$2"
  announce_diagnostics_running "$stage"
  local diag_dir="${LOG_DIR}/diagnostics/${stage}_attempt${attempt}_auto"
  mkdir -p "$diag_dir"

  local diagnostics=()
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    diagnostics+=("$cmd")
  done < <(get_stage_diagnostics "$stage")

  if [ "${#diagnostics[@]}" -eq 0 ]; then
    log "No diagnostics defined for stage '$stage'"
    return 0
  fi

  load_stage_env_for_diagnostics

  local idx=0
  for cmd in "${diagnostics[@]}"; do
    idx=$((idx + 1))
    local diag_file="${diag_dir}/diag_${idx}.log"
    {
      printf '# Stage: %s\n' "$stage"
      printf '# Command: %s\n' "$cmd"
      printf '# Timestamp: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      local cmd_rc=0
      if command -v timeout >/dev/null 2>&1; then
        set +e
        timeout "$DIAGNOSTICS_COMMAND_TIMEOUT" bash -lc "$cmd" 2>&1 | redact_secrets
        cmd_rc=${PIPESTATUS[0]}
        set -e
      else
        set +e
        bash -lc "$cmd" 2>&1 | redact_secrets
        cmd_rc=${PIPESTATUS[0]}
        set -e
      fi
      printf '\n# Exit Code: %s\n' "$cmd_rc"
    } > "$diag_file"
  done

  log "Diagnostics captured for stage '$stage' attempt $attempt at $diag_dir"
}

# Atomic JSON update - write to temp, then rename
atomic_json_write() {
  local target_file="$1"
  local content="$2"
  local temp_file="${target_file}.tmp"
  echo "$content" > "$temp_file"
  mv "$temp_file" "$target_file"
}

ensure_state_files() {
  if [ ! -f "$ERRORS_JSON" ]; then
    atomic_json_write "$ERRORS_JSON" '{}'
  fi
  if [ ! -f "$STAGE_STATUS_JSON" ]; then
    local stage_status_template
    stage_status_template="$(cat <<'EOF'
{
  "vms": "idle",
  "k3s": "idle",
  "infra": "idle",
  "apps": "idle",
  "ingress": "idle",
  "obs": "idle"
}
EOF
)"
    atomic_json_write "$STAGE_STATUS_JSON" "$stage_status_template"
  fi
  ensure_give_up_file
}

record_give_up_entry() {
  local stage="$1"
  local command="${2:-}"
  local log_path="${3:-}"
  local next_action="${4:-}"
  local probe_summary="${5:-}"

  ensure_give_up_file

  # v7 P0: Get evidence capsule from drift engine for rich give_up data
  local evidence_capsule=""
  if [ -n "$log_path" ] && [ "$log_path" != "unknown" ]; then
    evidence_capsule="$(python3 ai/drift_engine.py evidence --stage "$stage" --log-path "$log_path" --json 2>/dev/null || echo "{}")"
  else
    evidence_capsule="$(python3 ai/drift_engine.py evidence --stage "$stage" --json 2>/dev/null || echo "{}")"
  fi

  local payload
  payload="$(
python3 - "$GIVE_UP_STATE_FILE" "$stage" "$command" "$log_path" "$next_action" "$probe_summary" "$evidence_capsule" <<'PY'
import json, os, sys
from datetime import datetime, timezone

path, stage, command, log_path, next_action, probe_summary, evidence_json = sys.argv[1:8]

data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except json.JSONDecodeError:
        data = {}

# Parse evidence capsule
evidence = {}
try:
    evidence = json.loads(evidence_json) if evidence_json else {}
except json.JSONDecodeError:
    pass

# v7 P0: Use evidence capsule to enrich the entry
entry = {
    "stage": stage,
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "last_command": command,
    "log_path": evidence.get("log_path", log_path) or log_path or "unknown",
    "next_action": evidence.get("suggested_next_action", next_action) or next_action or "Review logs",
    "probe_summary": probe_summary,
    # v7 P0 additions:
    "failing_claim_id": evidence.get("failing_claim_id"),
    "failing_claim_evidence": evidence.get("failing_claim_evidence"),
    "evidence_excerpt": evidence.get("evidence_excerpt", "")[:500],
    "gating_status": evidence.get("gating_status", {}),
}

data[stage] = entry
print(json.dumps(data, indent=2))
PY
  )"
  atomic_json_write "$GIVE_UP_STATE_FILE" "$payload"
}

clear_stage_give_up_entry() {
  if [ ! -f "$GIVE_UP_STATE_FILE" ]; then
    return 0
  fi

  local payload
  payload="$(
python3 - "$GIVE_UP_STATE_FILE" "$stage" <<'PY'
import json, os, sys

path, stage = sys.argv[1:3]
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except json.JSONDecodeError:
        data = {}
data.pop(stage, None)
print(json.dumps(data, indent=2))
PY
  )"
  atomic_json_write "$GIVE_UP_STATE_FILE" "$payload"
}

get_stage_give_up_info() {
  if [ ! -f "$GIVE_UP_STATE_FILE" ]; then
    return 1
  fi
  python3 - <<'PY' "$GIVE_UP_STATE_FILE" "$1"
import json, sys

path, stage = sys.argv[1:3]
try:
    data = json.load(open(path))
except (json.JSONDecodeError, FileNotFoundError):
    sys.exit(1)
entry = data.get(stage)
if not entry:
    sys.exit(1)
print(entry.get("next_action", ""))
print(entry.get("log_path", ""))
PY
}

print_stage_give_up_notice() {
  local stage="$1"
  local info
  info="$(get_stage_give_up_info "$stage" 2>/dev/null || true)"
  if [ -z "$info" ]; then
    log "Stage '$stage' is in give_up state. Human intervention required."
    return
  fi
  local next_action log_path
  IFS=$'\n' read -r next_action log_path <<< "$info"
  printf "Stage '%s' halted.\nNEXT ACTION: %s\nLogs: %s\n" "$stage" "${next_action:-Review logs}" "${log_path:-unknown}"
}

reset_give_up_stage() {
  local stage="$1"
  local force="${2:-false}"

  if [ -z "$stage" ]; then
    printf 'ERROR: Missing stage for reset\\n'
    return 1
  fi

  python3 - <<'PY' "$GIVE_UP_STATE_FILE" "$stage" "$force"
import json, os, sys
from datetime import datetime, timezone

path, stage, force_flag = sys.argv[1:4]
force = force_flag == "true"
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except json.JSONDecodeError:
        data = {}
entry = data.get(stage)
if not entry:
    print(f"No give_up entry for stage {stage}")
    sys.exit(1)
ts = entry.get("timestamp")
age = 1e9
if ts:
    try:
        iso = ts
        if iso.endswith("Z"):
            iso = iso[:-1] + "+00:00"
        last = datetime.fromisoformat(iso)
        if last.tzinfo is None:
            last = last.replace(tzinfo=timezone.utc)
        age = (datetime.now(timezone.utc) - last).total_seconds()
    except ValueError:
        age = 1e9
if age < 300 and not force:
    print(f"Cannot reset {stage}: give_up recorded {int(age)}s ago. Use --force to override.")
    sys.exit(2)
data.pop(stage, None)
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
print(f"Give-up entry for stage {stage} cleared.")
PY

  return $?
}

run_preflight() {
  local stage="$1"
  local preflight_script="${REPO_ROOT}/${PREFLIGHT_SCRIPT}"
  
  if [ ! -x "$preflight_script" ]; then
    log "[preflight] WARNING: Preflight script not found or not executable: $preflight_script"
    log "[preflight] Continuing without preflight checks (tools may be missing)"
    return 0  # Don't fail if preflight script is missing
  fi

  log "[preflight] Running preflight checks for stage: $stage"
  set +e
  local output
  local path_updates
  local preflight_output
  
  # Use a temp file to capture both stdout and stderr, then separate them
  local tmp_stdout=$(mktemp)
  local tmp_stderr=$(mktemp)
  
  # Run preflight and capture both streams
  "$preflight_script" "$stage" > "$tmp_stdout" 2> "$tmp_stderr"
  local rc=$?
  
  # Read the outputs
  preflight_output="$(cat "$tmp_stdout")"
  output="$(cat "$tmp_stderr")"
  
  # Extract PATH export lines from stdout and apply them
  path_updates="$(printf '%s\n' "$preflight_output" | grep '^export PATH=' || true)"
  if [ -n "$path_updates" ]; then
    while IFS= read -r path_line; do
      if [ -n "$path_line" ]; then
        eval "$path_line"
        log "[preflight] Applied PATH update: $path_line"
      fi
    done <<< "$path_updates"
  fi

  # Log the stderr output (actual preflight messages)
  if [ -n "$output" ]; then
    printf '%s\n' "$output" | while IFS= read -r line; do
      log "[preflight] $line"
    done
  fi
  
  # Cleanup
  rm -f "$tmp_stdout" "$tmp_stderr"
  set -e

  if [ $rc -ne 0 ]; then
    log "[preflight] FAILED (rc=$rc)"
    return $rc
  else
    log "[preflight] PASSED"
    return 0
  fi
}

# v7 P0: Check stage gating claims before marking stage complete
check_stage_gating() {
  local stage="$1"

  log "[gating] Checking gating claims for stage: $stage"

  set +e
  local gating_output
  gating_output="$(python3 ai/drift_engine.py check-gating --stage "$stage" --json 2>/dev/null)"
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    # Extract failing claims for logging
    local failing_claims
    failing_claims="$(echo "$gating_output" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(f['id']+': '+f['evidence']) for f in d.get('failing_claims',[])]" 2>/dev/null || echo "unknown")"
    log "[gating] FAILED - stage '$stage' cannot be marked complete"
    log "[gating] Failing claims:"
    printf '%s\n' "$failing_claims" | while IFS= read -r line; do
      log "[gating]   - $line"
    done
    return 1
  fi

  log "[gating] PASSED - all gating claims satisfied for stage: $stage"
  return 0
}

# v7 P0: Update cluster identity after VMs or k3s stage
update_cluster_identity() {
  local key="$1"
  local value="$2"

  python3 ai/drift_engine.py update-identity --key "$key" --value "$value" 2>/dev/null
}

# v7 P0: Update artifact validity
update_artifact() {
  local artifact="$1"
  local key="$2"
  local value="$3"

  python3 ai/drift_engine.py update-artifact --artifact "$artifact" --key "$key" --value "$value" 2>/dev/null
}

run_k3s_probe() {
  local probe_script="${REPO_ROOT}/ai/reality/probe_k3s.sh"
  if [ ! -x "$probe_script" ]; then
    LAST_STAGE_PROBE_SUMMARY="[probe] k3s: FAIL (probe missing)"
    return 1
  fi

  set +e
  local output
  output="$("$probe_script" 2>&1)"
  local rc=$?
  set -e

  LAST_STAGE_PROBE_SUMMARY="$output"
  return $rc
}

enter_stage_give_up() {
  local stage="$1"
  local custom_next_action="${2:-}"
  local next_action
  if [ -n "$custom_next_action" ]; then
    next_action="$custom_next_action"
  else
    next_action="Review logs and rerun './ai/bootstrap_loop.sh $stage' after fixing the issue."
  fi

  if [ "$stage" = "k3s" ]; then
    LAST_STAGE_PROBE_SUMMARY=""
    if run_k3s_probe; then
      next_action="k3s probe passed unexpectedly; inspect \"$LAST_STAGE_FAILURE_LOG\"."
    else
      local reason
      reason="$(printf '%s\n' "$LAST_STAGE_PROBE_SUMMARY" | awk -F': ' '/^reason:/ {print $2; exit}')"
      if [ -n "$reason" ]; then
        next_action="Verify k3s control plane reachability (probe reason: $reason)"
      else
        next_action="Verify k3s control plane reachability (probe output unavailable)"
      fi
    fi
  fi

  set_stage_status "$stage" "give_up"
  record_give_up_entry "$stage" "${LAST_STAGE_FAILURE_COMMAND:-unknown}" "${LAST_STAGE_FAILURE_LOG:-unknown}" "$next_action" "$LAST_STAGE_PROBE_SUMMARY"
  printf "Stage '%s' halted.\nNEXT ACTION: %s\nLogs: %s\n" "$stage" "$next_action" "${LAST_STAGE_FAILURE_LOG:-unknown}"
}

ensure_give_up_file() {
  if [ ! -f "$GIVE_UP_STATE_FILE" ]; then
    atomic_json_write "$GIVE_UP_STATE_FILE" '{}'
  fi
}

# =============================================================================
# Error Hashing (v5: stage + exit_code + normalized_signature)
# =============================================================================
compute_error_hash() {
  local stage="$1"
  local exit_code="$2"
  local log_file="$3"

  if [ ! -f "$log_file" ]; then
    echo "no_log_file"
    return
  fi

  local signature
  signature="$(extract_error_signature "$log_file" | normalize_log | redact_secrets)"

  # Hash: stage + exit_code + normalized_signature
  # Use md5 on macOS, md5sum on Linux
  local hash
  hash="$(printf '%s\n%s\n%s' "$stage" "$exit_code" "$signature" | md5 2>/dev/null || printf '%s\n%s\n%s' "$stage" "$exit_code" "$signature" | md5sum | awk '{print $1}')"

  # Return first 8 characters
  echo "${hash:0:8}"
}

get_error_attempts() {
  local stage="$1"
  local error_hash="$2"
  local key="${stage}_${error_hash}"
  if [ ! -f "$ERRORS_JSON" ]; then
    echo "0"
    return
  fi
  python3 -c "
import json, sys
try:
    data = json.load(open('$ERRORS_JSON'))
    key = '$key'
    if key in data:
        print(data[key].get('attempts', 0))
    else:
        print(0)
except:
    print(0)
"
}

get_error_last_source() {
  local stage="$1"
  local error_hash="$2"
  local key="${stage}_${error_hash}"
  if [ ! -f "$ERRORS_JSON" ]; then
    echo "none"
    return
  fi
  python3 -c "
import json
try:
    data = json.load(open('$ERRORS_JSON'))
    key = '$key'
    if key in data:
        print(data[key].get('last_source', 'none'))
    else:
        print('none')
except:
    print('none')
"
}

get_api_call_count() {
  local stage="$1"
  local error_hash="$2"
  local key="${stage}_${error_hash}"
  if [ ! -f "$ERRORS_JSON" ]; then
    echo "0"
    return
  fi
  python3 -c "
import json
try:
    data = json.load(open('$ERRORS_JSON'))
    key = '$key'
    if key in data:
        print(data[key].get('api_calls', 0))
    else:
        print(0)
except:
    print(0)
"
}

add_api_outcome() {
  local stage="$1"
  local error_hash="$2"
  local outcome="$3"
  local key="${stage}_${error_hash}"

  local content
  content="$(
python3 - "$ERRORS_JSON" "$key" "$outcome" "$ISSUES_FILE" <<'PY'
import json
import os
import sys

path, key, outcome, issues_path = sys.argv[1:5]

def load_data():
    data = {}
    if os.path.exists(path):
        try:
            with open(path) as f:
                data = json.load(f)
        except json.JSONDecodeError:
            data = {}
        except FileNotFoundError:
            data = {}
    return data

data = load_data()
entry = data.setdefault(key, {
    "attempts": 0,
    "api_calls": 0,
    "last_source": "none",
    "last_transition": "",
    "api_outcomes": [],
    "no_effect_count": 0,
    "no_new_evidence_count": 0,
    "patch_failures": 0,
    "provider_failures": {}
})
entry.setdefault("api_outcomes", [])
entry.setdefault("provider_failures", {})
entry.setdefault("no_effect_count", 0)
if outcome == "no_effect":
    entry["no_effect_count"] = entry.get("no_effect_count", 0) + 1
entry["api_outcomes"].append(outcome)
print(json.dumps(data, indent=2))
PY
  )"

  atomic_json_write "$ERRORS_JSON" "$content"
}

get_error_field_value() {
  local stage="$1"
  local error_hash="$2"
  local field="$3"
  local key="${stage}_${error_hash}"

  if [ ! -f "$ERRORS_JSON" ]; then
    echo "0"
    return
  fi
  python3 - "$ERRORS_JSON" "$key" "$field" <<'PY'
import json
import sys

path, key, field = sys.argv[1:4]
try:
    data = json.load(open(path))
    entry = data.get(key, {})
    value = entry.get(field, 0)
    if isinstance(value, dict):
        print(json.dumps(value))
    else:
        print(value)
except:
    print(0)
PY
}

increment_error_field_value() {
  local stage="$1"
  local error_hash="$2"
  local field="$3"
  local delta="${4:-1}"
  local key="${stage}_${error_hash}"

  local content
  content="$(
python3 - "$ERRORS_JSON" "$key" "$field" "$delta" "$ISSUES_FILE" <<'PY'
import json
import os
import sys

path, key, field, delta, issues_path = sys.argv[1:6]
def load_data():
    if not os.path.exists(path):
        return {}
    try:
        return json.load(open(path))
    except json.JSONDecodeError:
        return {}

data = load_data()
entry = data.setdefault(key, {"attempts": 0, "api_calls": 0, "last_source": "none", "last_transition": "", "api_outcomes": [], "no_effect_count": 0, "no_new_evidence_count": 0, "patch_failures": 0, "provider_failures": {}})
value = entry.get(field, 0) + int(delta)
entry[field] = value
print(json.dumps(data, indent=2))
PY
  )"

  atomic_json_write "$ERRORS_JSON" "$content"
}

set_error_field_value() {
  local stage="$1"
  local error_hash="$2"
  local field="$3"
  local new_value="$4"
  local key="${stage}_${error_hash}"

  local content
  content="$(
python3 - "$ERRORS_JSON" "$key" "$field" "$new_value" "$ISSUES_FILE" <<'PY'
import json
import os
import sys

path, key, field, value, issues_path = sys.argv[1:6]
def load_data():
    if not os.path.exists(path):
        return {}
    try:
        return json.load(open(path))
    except json.JSONDecodeError:
        return {}

data = load_data()
entry = data.setdefault(key, {"attempts": 0, "api_calls": 0, "last_source": "none", "last_transition": "", "api_outcomes": [], "no_effect_count": 0, "no_new_evidence_count": 0, "patch_failures": 0, "provider_failures": {}})
try:
    entry[field] = int(value)
except ValueError:
    entry[field] = value
print(json.dumps(data, indent=2))
PY
  )"

  atomic_json_write "$ERRORS_JSON" "$content"
}

record_provider_failure() {
  local stage="$1"
  local error_hash="$2"
  local provider="$3"
  local key="${stage}_${error_hash}"

  local content
  content="$(
python3 - "$ERRORS_JSON" "$key" "$provider" "$ISSUES_FILE" <<'PY'
import json
import os
import sys

path, key, provider, issues_path = sys.argv[1:5]
def load_data():
    if not os.path.exists(path):
        return {}
    try:
        return json.load(open(path))
    except json.JSONDecodeError:
        return {}

data = load_data()
entry = data.setdefault(key, {"attempts": 0, "api_calls": 0, "last_source": "none", "last_transition": "", "api_outcomes": [], "no_effect_count": 0, "no_new_evidence_count": 0, "patch_failures": 0, "provider_failures": {}})
failures = entry.setdefault("provider_failures", {})
failures[provider] = failures.get(provider, 0) + 1
print(json.dumps(data, indent=2))
PY
  )"

  atomic_json_write "$ERRORS_JSON" "$content"
}

get_api_outcome_count() {
  local stage="$1"
  local error_hash="$2"
  local desired_outcome="$3"
  local key="${stage}_${error_hash}"
  if [ ! -f "$ERRORS_JSON" ]; then
    echo "0"
    return
  fi
  python3 - "$ERRORS_JSON" "$key" "$desired_outcome" <<'PY'
import json
import sys

path, key, desired = sys.argv[1:4]
try:
    data = json.load(open(path))
    entry = data.get(key, {})
    outcomes = entry.get("api_outcomes", [])
    print(outcomes.count(desired))
except:
    print(0)
PY
}

get_latest_api_outcome() {
  local stage="$1"
  local error_hash="$2"
  local key="${stage}_${error_hash}"
  if [ ! -f "$ERRORS_JSON" ]; then
    echo ""
    return
  fi
  python3 - "$ERRORS_JSON" "$key" <<'PY'
import json
import sys

path, key = sys.argv[1:3]
try:
    data = json.load(open(path))
    entry = data.get(key, {})
    outcomes = entry.get("api_outcomes", [])
    if outcomes:
        print(outcomes[-1])
except:
    pass
PY
}

update_error_state() {
  local stage="$1"
  local error_hash="$2"
  local source="$3"  # executor or api
  local increment_api="${4:-false}"
  local increment_attempts="${5:-true}"
  local key="${stage}_${error_hash}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local content
  content="$(
python3 - "$ERRORS_JSON" "$key" "$source" "$ts" "$increment_api" "$increment_attempts" "$ISSUES_FILE" <<'PY'
import json
import os
import sys

path, key, source, ts, increment_api, increment_attempts, issues_path = sys.argv[1:8]

def load_data():
    data = {}
    if os.path.exists(path):
        try:
            with open(path) as f:
                data = json.load(f)
        except json.JSONDecodeError:
            timestamp = datetime.utcnow().strftime("%Y%m%d-%H%M%SZ")
            corrupt_path = f"{path}.corrupted.{timestamp}"
            os.rename(path, corrupt_path)
            msg = f"[{datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}] WARNING: Corrupted JSON moved to {corrupt_path}\n"
            parent = os.path.dirname(issues_path)
            if parent and not os.path.isdir(parent):
                os.makedirs(parent, exist_ok=True)
            with open(issues_path, "a") as fh:
                fh.write(msg)
            data = {}
        except FileNotFoundError:
            data = {}
    return data

data = load_data()
entry = data.setdefault(key, {
    "attempts": 0,
    "api_calls": 0,
    "last_source": "none",
    "last_transition": "",
    "api_outcomes": [],
    "no_effect_count": 0,
    "no_new_evidence_count": 0,
    "patch_failures": 0,
    "provider_failures": {}
})
entry.setdefault("api_outcomes", [])
entry.setdefault("provider_failures", {})
attempts = entry.get("attempts", 0)
if increment_attempts == "true":
    attempts += 1
entry["attempts"] = attempts
entry["last_source"] = source
entry["last_transition"] = ts
if increment_api == "true":
    entry["api_calls"] = entry.get("api_calls", 0) + 1
print(json.dumps(data, indent=2))
PY
  )"

  atomic_json_write "$ERRORS_JSON" "$content"
}

reset_error_state() {
  local stage="$1"
  local error_hash="$2"
  local key="${stage}_${error_hash}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local content
  content="$(
python3 - "$ERRORS_JSON" "$key" "$ts" "$ISSUES_FILE" <<'PY'
import json
import os
import sys
from datetime import datetime

path, key, ts, issues_path = sys.argv[1:5]

def load_data():
    data = {}
    if os.path.exists(path):
        try:
            with open(path) as f:
                data = json.load(f)
        except json.JSONDecodeError:
            timestamp = datetime.utcnow().strftime("%Y%m%d-%H%M%SZ")
            corrupt_path = f"{path}.corrupted.{timestamp}"
            os.rename(path, corrupt_path)
            msg = f"[{datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}] WARNING: Corrupted JSON moved to {corrupt_path}\n"
            parent = os.path.dirname(issues_path)
            if parent and not os.path.isdir(parent):
                os.makedirs(parent, exist_ok=True)
            with open(issues_path, "a") as fh:
                fh.write(msg)
            data = {}
        except FileNotFoundError:
            data = {}
    return data

data = load_data()
entry = data.setdefault(key, {"attempts": 0, "api_calls": 0, "last_source": "none", "last_transition": "", "api_outcomes": []})
entry["attempts"] = 0
entry["api_calls"] = 0
entry["last_source"] = "none"
entry["last_transition"] = ts
entry["no_effect_count"] = 0
entry["no_new_evidence_count"] = 0
entry["patch_failures"] = 0
entry["provider_failures"] = {}
print(json.dumps(data, indent=2))
PY
  )"

  atomic_json_write "$ERRORS_JSON" "$content"
}

# =============================================================================
# Stage Status Management
# =============================================================================
get_stage_status() {
  local stage="$1"
  if [ ! -f "$STAGE_STATUS_JSON" ]; then
    echo "idle"
    return
  fi
  python3 -c "
import json
try:
    data = json.load(open('$STAGE_STATUS_JSON'))
    print(data.get('$stage', 'idle'))
except:
    print('idle')
"
}

set_stage_status() {
  local stage="$1"
  local status="$2"  # idle, running, green, failed, give_up

  local content
  content="$(
python3 - "$STAGE_STATUS_JSON" "$stage" "$status" "$ISSUES_FILE" <<'PY'
import json
import os
import sys
from datetime import datetime

path, stage, status, issues_path = sys.argv[1:5]

def load_data():
    data = {}
    if os.path.exists(path):
        try:
            with open(path) as f:
                data = json.load(f)
        except json.JSONDecodeError:
            timestamp = datetime.utcnow().strftime("%Y%m%d-%H%M%SZ")
            corrupt_path = f"{path}.corrupted.{timestamp}"
            os.rename(path, corrupt_path)
            msg = f"[{datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}] WARNING: Corrupted JSON moved to {corrupt_path}\n"
            parent = os.path.dirname(issues_path)
            if parent and not os.path.isdir(parent):
                os.makedirs(parent, exist_ok=True)
            with open(issues_path, "a") as fh:
                fh.write(msg)
            data = {}
        except FileNotFoundError:
            data = {}
    return data

data = load_data()
data[stage] = status
print(json.dumps(data, indent=2))
PY
  )"

  atomic_json_write "$STAGE_STATUS_JSON" "$content"
}

handle_stage_exit() {
  if [ -z "$CURRENT_STAGE_IN_PROGRESS" ]; then
    return
  fi

  local had_errexit=false
  case "$-" in
    *e*) had_errexit=true ;;
  esac

  set +e
  local stage="$CURRENT_STAGE_IN_PROGRESS"
  local status
  status="$(get_stage_status "$stage")"
  if [ "$status" = "running" ]; then
    log "WARNING: Stage '$stage' exiting while still marked as running. Marking as failed."
    set_stage_status "$stage" "failed"
    printf '[%s] ORCHESTRATOR: Unexpected exit while stage %s was running; trap marked it failed\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stage" >> "$ISSUES_FILE"
  fi

  if [ "$had_errexit" = true ]; then
    set -e
  fi
  CURRENT_STAGE_IN_PROGRESS=""
}

# =============================================================================
# Stage Commands
# =============================================================================
get_stage_command() {
  local stage="$1"
  case "$stage" in
    vms)
      echo "infrastructure/proxmox/provision_vms.sh"
      ;;
    k3s)
      echo "infrastructure/proxmox/cluster_bootstrap.sh k3s"
      ;;
    infra)
      echo "infrastructure/proxmox/cluster_bootstrap.sh infra"
      ;;
    apps)
      echo "infrastructure/proxmox/cluster_bootstrap.sh apps"
      ;;
    ingress)
      echo "infrastructure/proxmox/cluster_bootstrap.sh apps"  # ingress is part of apps via GitOps
      ;;
    obs)
      echo "infrastructure/proxmox/cluster_bootstrap.sh apps"  # obs is part of apps via GitOps
      ;;
    *)
      echo ""
      ;;
  esac
}

# =============================================================================
# Stage Execution
# =============================================================================
run_stage() {
  local stage="$1"
  local attempt="$2"
  local log_file="$3"

  local cmd
  cmd="$(get_stage_command "$stage")"
  if [ -z "$cmd" ]; then
    log "ERROR: Unknown stage '$stage'"
    return 1
  fi

  log "Running stage '$stage' (attempt $attempt)"
  log "Command: $cmd"
  log "Log file: $log_file"
  announce_stage_command "$cmd"

  set_stage_status "$stage" "running"

  LAST_STAGE_FAILURE_COMMAND="$cmd"
  LAST_STAGE_FAILURE_LOG="$log_file"
  LAST_STAGE_PROBE_SUMMARY=""

  # Run preflight checks before probes (ensures tools are available)
  set +e
  if ! run_preflight "$stage"; then
    log "[preflight] Preflight failed for stage: $stage"
    # Continue anyway - the stage command may install missing tools
    # But log the warning
  fi
  set -e

  if [ "$stage" = "k3s" ]; then
    set +e
    if run_k3s_probe; then
      log "[probe] k3s: PASS (pre-stage check)"
    else
      log "[probe] k3s: FAIL (pre-stage check)"
      printf '%s\n' "$LAST_STAGE_PROBE_SUMMARY" | while IFS= read -r line; do
        log "  $line"
      done
    fi
    set -e
  fi

  mkdir -p "$(dirname "$log_file")"

  set +e
  (
    cd "$REPO_ROOT"
    eval "$cmd"
  ) > "$log_file" 2>&1
  local rc=$?
  set -e

  log_to_file "$log_file" "Exit code: $rc"

  set +e
  return $rc
}

# =============================================================================
# Executor Handoff
# =============================================================================
call_executor() {
  local stage="$1"
  local log_file="$2"
  local error_hash="$3"
  local attempt="$4"

  log "Handing off to Executor for local fix attempt"

  if [ ! -x "$EXECUTOR_RUNNER" ]; then
    log "ERROR: Executor runner not found or not executable: $EXECUTOR_RUNNER"
    printf '[executor] Skipped: Executor runner not found (%s)\n' "$EXECUTOR_RUNNER"
    return 1
  fi

  local summary_file="${LOG_DIR}/executor/executor_summary_${stage}_${attempt}_$(date -u +%Y%m%d-%H%M%S).txt"
  local rc

  announce_executor_invocation "$attempt"
  "$EXECUTOR_RUNNER" "$stage" "$log_file" "$error_hash" "$summary_file"
  rc=$?

  local summary_status=""
  local summary_lines=""
  local summary_rc=""
  if [ -f "$summary_file" ]; then
    while IFS='=' read -r key value; do
      case "$key" in
        status) summary_status="$value" ;;
        lines_changed) summary_lines="$value" ;;
        provider_rc) summary_rc="$value" ;;
      esac
    done < "$summary_file"
  fi

  case "$summary_status" in
    patch)
      announce_executor_patch_generated "${summary_lines:-0}"
      ;;
    no_patch)
      announce_executor_no_patch
      ;;
    provider_failure)
      log "[executor] Provider failure detected (rc=${summary_rc:-$rc}) - should trigger failover"
      announce_executor_tooling_failure "${summary_rc:-$rc}"
      ;;
    tooling_failure)
      announce_executor_tooling_failure "${summary_rc:-$rc}"
      ;;
    *)
      if [ "$rc" -eq 0 ]; then
        announce_executor_patch_generated "${summary_lines:-0}"
      else
        announce_executor_tooling_failure "${summary_rc:-$rc}"
      fi
      ;;
  esac

  LAST_EXECUTOR_SUMMARY_STATUS="$summary_status"
  LAST_EXECUTOR_SUMMARY_RC="${summary_rc:-$rc}"

  # Return special exit code for provider_failure (3) so caller can handle as failover
  if [ "$summary_status" = "provider_failure" ]; then
    return 3
  fi

  return $rc
}

# =============================================================================
# API Escalation
# =============================================================================
trigger_api_escalation() {
  local stage="$1"
  local log_file="$2"
  local error_hash="$3"
  local case_version="${4:-1}"
  local diagnostics_dir="${5:-}"
  local error_key="${6:-${stage}_${error_hash}}"

  log "Triggering API escalation (case v${case_version})"

  local timestamp
  timestamp="$(date -u +%Y%m%d-%H%M%S)"
  local case_file="${ESCALATION_DIR}/${stage}_${timestamp}_case_v${case_version}.md"

  # Generate case file
  if [ ! -x "$CASE_FILE_GENERATOR" ]; then
    log "ERROR: Case file generator not found: $CASE_FILE_GENERATOR"
    return 1
  fi

  if [ "$case_version" = "1" ]; then
    "$CASE_FILE_GENERATOR" "$stage" "$log_file" "$case_file" "$error_key"
  else
    "$CASE_FILE_GENERATOR" "$stage" "$log_file" "$case_file" "$error_key" "$diagnostics_dir"
  fi

  local patch_file="${ESCALATION_DIR}/${stage}_${timestamp}_patch.diff"
  local response_file="${ESCALATION_DIR}/${stage}_${timestamp}_response.json"

  if ! router_select_provider "architect" "$error_key"; then
    log "WARNING: Router fallback for architect (mode=${SELECTOR_FALLBACK_MODE:-unknown})"
    if [ "$SELECTOR_FALLBACK_MODE" = "safe_mode" ]; then
      enter_safe_mode "router_no_architect" "$stage" "$error_key"
      return 1
    fi
    echo "failover:router_unavailable"
    return 0
  fi

  if [ "$SELECTED_SERVICE" != "openrouter" ]; then
    log "ERROR: Architect service '$SELECTED_SERVICE' unsupported"
    echo "failover:unsupported_service"
    return 0
  fi

  local provider_output
  provider_output="$("$OPENROUTER_PROVIDER_CMD" call "$case_file" "$response_file" "$SELECTED_TIER" "$error_key" "$SELECTED_MODEL" 2>&1)"
  local provider_rc=$?
  local provider_status
  provider_status="$(printf '%s\n' "$provider_output" | awk -F= '/^status=/ {print $2; exit}' | tr -d '\r')"
  provider_status="${provider_status:-unknown}"

  if [ "$provider_rc" -ne 0 ] || [ "$provider_status" != "ok" ]; then
    log "WARNING: Architect provider '${SELECTED_TIER}' (${SELECTED_MODEL}) unavailable: ${provider_status}"
    router_record_outcome "$SELECTED_PROVIDER" "failure" "$provider_status"
    record_provider_failure "$stage" "$error_hash" "$SELECTED_PROVIDER"
    echo "failover:${provider_status}"
    return 0
  fi

  router_record_outcome "$SELECTED_PROVIDER" "success" "$SELECTED_REASON"

  local response_type="unknown"
  if [ -f "$response_file" ]; then
    response_type="$(python3 -c "import json; print(json.load(open('$response_file')).get('type', 'unknown'))" 2>/dev/null || echo "unknown")"
  fi

  if [ "$response_type" = "patch" ] && [ -f "$patch_file" ]; then
    echo "patch:$patch_file"
    return 0
  elif [ "$response_type" = "diagnostics" ]; then
    echo "diagnostics:$response_file"
    return 0
  elif [ "$response_type" = "invalid_format" ]; then
    echo "invalid_format:$response_file"
    return 1
  fi

  echo "error"
  return 1
}

# =============================================================================
# Diagnostics Execution
# =============================================================================

# Run diagnostics from API response
run_diagnostics() {
  local stage="$1"
  local response_file="$2"

  log "Running diagnostics requested by API"

  if [ ! -x "$DIAGNOSTICS_RUNNER" ]; then
    log "ERROR: Diagnostics runner not found: $DIAGNOSTICS_RUNNER"
    return 1
  fi

  local timestamp
  timestamp="$(date -u +%Y%m%d-%H%M%S)"
  local diag_dir="${LOG_DIR}/diagnostics/${stage}_${timestamp}"

  "$DIAGNOSTICS_RUNNER" "$response_file" "$diag_dir"

  echo "$diag_dir"
}

# =============================================================================
# Patch Gating (v5 requirement - pre-apply validation)
# =============================================================================
validate_patch() {
  local patch_file="$1"
  local timestamp
  timestamp="$(date -u +%Y%m%d-%H%M%S)"
  local reject_log="${LOG_DIR}/provider/patch_rejected_${timestamp}.log"

  if [ ! -f "$patch_file" ]; then
    log "ERROR: Patch file not found: $patch_file"
    return 1
  fi

  # Check for protected files
  for protected in "${PROTECTED_FILES[@]}"; do
    if grep -q "^[+-][+-][+-] [ab]/$protected" "$patch_file" 2>/dev/null; then
      log "REJECT: Patch touches protected file: $protected"
      echo "Rejected: touches protected file $protected" >> "$reject_log"
      return 1
    fi
  done

  # Check for files outside allowlisted paths
  local files_in_patch
  files_in_patch="$(grep -E '^[+-][+-][+-] [ab]/' "$patch_file" 2>/dev/null | sed 's|^[+-][+-][+-] [ab]/||' || true)"
  for file in $files_in_patch; do
    local allowed=false
    for path in "${ALLOWED_PATHS[@]}"; do
      if [[ "$file" == "$path"* ]]; then
        allowed=true
        break
      fi
    done
    if [ "$allowed" = false ]; then
      log "REJECT: Patch modifies file outside allowlisted paths: $file"
      echo "Rejected: modifies file outside allowlisted paths: $file" >> "$reject_log"
      return 1
    fi
  done

  # Check patch size
  local lines_changed
  lines_changed="$(grep -cE '^[+-]' "$patch_file" 2>/dev/null | head -1 || echo "0")"
  if [ "$lines_changed" -gt "$PATCH_SIZE_LIMIT" ]; then
    log "REJECT: Patch exceeds size limit ($lines_changed > $PATCH_SIZE_LIMIT lines)"
    echo "Rejected: exceeds size limit ($lines_changed lines)" >> "$reject_log"
    return 1
  fi

  # Check for directory creation
  if grep -qE '^(mkdir|install -d)' "$patch_file" 2>/dev/null; then
    log "REJECT: Patch contains directory creation commands"
    echo "Rejected: contains directory creation commands" >> "$reject_log"
    return 1
  fi

  log "Patch validation passed"
  return 0
}

# =============================================================================
# Patch Application
# =============================================================================
apply_patch() {
  local patch_file="$1"

  log "Applying patch: $patch_file"

  # Validate patch first (v5 requirement)
  if ! validate_patch "$patch_file"; then
    log "Patch rejected by gating rules"
    return 1
  fi

  # Ensure we're on the AI branch
  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"

  if [ "$current_branch" != "$AI_BRANCH" ]; then
    log "Switching to AI branch: $AI_BRANCH"
    git checkout -B "$AI_BRANCH" 2>/dev/null || git checkout "$AI_BRANCH" 2>/dev/null || {
      log "Creating new AI branch from current HEAD"
      git checkout -b "$AI_BRANCH"
    }
  fi

  # Apply the patch
  if git apply --check "$patch_file" 2>/dev/null; then
    git apply "$patch_file"
    git add -A
    local commit_msg="[orchestrator] Apply patch from API escalation

Source: $patch_file
Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    git commit -m "$commit_msg"
    log "Patch applied and committed"
    return 0
  else
    log "ERROR: Patch does not apply cleanly"
    return 1
  fi
}

# =============================================================================
# Main Orchestration Loop for a Single Stage
# =============================================================================
orchestrate_stage() {
  local stage="$1"

  log "=== Orchestrating stage: $stage ==="
  CURRENT_STAGE_IN_PROGRESS="$stage"

  ensure_directories
  ensure_state_files

  local current_status
  current_status="$(get_stage_status "$stage")"

  if [ "$current_status" = "green" ]; then
    log "Stage '$stage' is already green. Skipping."
    clear_current_stage_progress
    return 0
  fi

  if [ "$current_status" = "give_up" ]; then
    print_stage_give_up_notice "$stage"
    clear_current_stage_progress
    return 1
  fi

  local attempt=1
  local max_total_attempts=20  # Safety limit
  local transient_backoff=0    # v5: track transient failure backoffs

  # Acquire lock for state operations (v5 requirement)
  if ! acquire_lock; then
    log "ERROR: Could not acquire state lock"
    return 1
  fi
  trap 'handle_stage_exit; release_lock' EXIT INT TERM RETURN

  while [ "$attempt" -le "$max_total_attempts" ]; do
    log "--- Attempt $attempt for stage '$stage' ---"
    announce_attempt_brief "$attempt"

    # Run the stage
    local timestamp
    timestamp="$(date -u +%Y%m%d-%H%M%S)"
    local log_file="${LOG_DIR}/stages/${stage}/${stage}_${timestamp}_attempt${attempt}.log"
    mkdir -p "$(dirname "$log_file")"

    set +e
    run_stage "$stage" "$attempt" "$log_file"
    local rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
      log "Stage '$stage' succeeded!"
      set_stage_status "$stage" "green"
      clear_stage_give_up_entry "$stage"
      announce_stage_success "$stage"
      clear_current_stage_progress
      set -e
      return 0
    fi

    log "Stage '$stage' failed (rc=$rc)"
    set_stage_status "$stage" "failed"
    announce_stage_failure "$stage" "$rc"

    local error_hash hash_rc error_key update_rc used_fallback=false
    error_hash="$(compute_error_hash "$stage" "$rc" "$log_file")"
    hash_rc=$?
    if [ "$hash_rc" -ne 0 ] || [ -z "$error_hash" ]; then
      used_fallback=true
      error_hash="unclassified_rc${rc}"
    fi
    error_key="${stage}_${error_hash}"
    if [ "$used_fallback" = true ]; then
      log "WARNING: Failed to compute error hash (rc=$hash_rc). Using fallback key '$error_key'."
    fi
    update_error_state "$stage" "$error_hash" "stage"
    update_rc=$?
    if [ "$update_rc" -ne 0 ]; then
      log "WARNING: Failed to update errors.json for stage failure (rc=$update_rc)."
    fi

    if [ ! -f "$log_file" ]; then
      log "ERROR: Expected log file missing: $log_file"
      printf '[%s] PLUMBING ERROR: Missing log file for %s attempt %s (%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stage" "$attempt" "$log_file" >> "$ISSUES_FILE"
      set -e
      clear_current_stage_progress
      return 1
    fi

    log "Error hash: $error_hash"
    announce_attempt_with_key "$attempt" "$error_key"

    local error_attempts last_source api_calls
    error_attempts="$(get_error_attempts "$stage" "$error_hash")" || error_attempts="0"
    last_source="$(get_error_last_source "$stage" "$error_hash")" || last_source="none"
    api_calls="$(get_api_call_count "$stage" "$error_hash")" || api_calls="0"

    log "Error state: attempts=$error_attempts, last_source=$last_source, api_calls=$api_calls"

    local last_api_outcome
    last_api_outcome="$(get_latest_api_outcome "$stage" "$error_hash")" || last_api_outcome=""
    if [ "$last_api_outcome" = "applied" ]; then
      add_api_outcome "$stage" "$error_hash" "no_effect"
      last_api_outcome="no_effect"
    fi

    if [ "$last_api_outcome" = "no_effect" ]; then
      increment_error_field_value "$stage" "$error_hash" "no_new_evidence_count" "1"
    else
      set_error_field_value "$stage" "$error_hash" "no_new_evidence_count" "0"
    fi

    local repeated_no_evidence patch_failures safe_mode_reason
    repeated_no_evidence="$(get_error_field_value "$stage" "$error_hash" "no_new_evidence_count")"
    patch_failures="$(get_error_field_value "$stage" "$error_hash" "patch_failures")"
    if [ "$(are_all_executor_providers_unhealthy)" = "true" ]; then
      safe_mode_reason="executor_providers_unhealthy"
    elif [ "$patch_failures" -ge "$SAFE_MODE_PATCH_FAILURE_THRESHOLD" ]; then
      safe_mode_reason="patch_failure_threshold"
    elif [ "$repeated_no_evidence" -ge "$SAFE_MODE_NO_EVIDENCE_THRESHOLD" ]; then
      safe_mode_reason="no_new_evidence_loop"
    fi
    if [ -n "$safe_mode_reason" ]; then
      enter_safe_mode "$safe_mode_reason" "$stage" "$error_key"
      set -e
      return 1
    fi

    if is_transient_failure "$log_file"; then
      transient_backoff=$((transient_backoff + 1))
      if handle_transient_failure "$stage" "$transient_backoff"; then
        update_error_state "$stage" "$error_hash" "executor" "false" "false" || log "WARNING: Failed to update errors.json for transient failure (rc=$?)"
        log "Retrying after transient backoff..."
        set -e
        continue
      fi
    else
      transient_backoff=0
    fi

    if [ "$error_attempts" -lt "$EXECUTOR_RETRY_THRESHOLD" ]; then
      log "Error is new/recent (attempts < $EXECUTOR_RETRY_THRESHOLD). Executor will attempt fix."

      if [ "$error_attempts" -eq 1 ]; then
        run_stage_diagnostics "$stage" "$attempt"
      fi

      if ! router_select_provider "executor" "$error_key"; then
        log "Router fallback for executor: $SELECTOR_FALLBACK_MODE"
        if [ "$SELECTOR_FALLBACK_MODE" = "safe_mode" ]; then
          enter_safe_mode "router_no_executor" "$stage" "$error_key"
          set -e
          return 1
        fi
        log "No executor provider available; will retry after backoff"
        continue
      fi

      # Map provider names (router returns ollama_executor, executor expects ollama)
      local mapped_provider="$SELECTED_PROVIDER"
      if [ "$mapped_provider" = "ollama_executor" ]; then
        mapped_provider="ollama"
      fi
      export EXECUTOR_PROVIDER="$mapped_provider"
      export EXECUTOR_PROVIDER_MODEL="$SELECTED_MODEL"
      log "Router decision: role=EXECUTOR provider=$SELECTED_PROVIDER model=$SELECTED_MODEL reason=$SELECTED_REASON tier=$SELECTED_TIER health_reason=${SELECTED_HEALTH_REASON:-healthy} cooldown_remaining=${SELECTED_COOLDOWN_REMAINING:-0s}"

      update_error_state "$stage" "$error_hash" "executor" "false" "true"
      local update_rc=$?
      if [ "$update_rc" -ne 0 ]; then
        log "WARNING: Failed to update errors.json for executor path (rc=$update_rc)."
      fi

      set +e
      call_executor "$stage" "$log_file" "$error_hash" "$attempt"
      local executor_rc=$?
      set -e

      local executor_status="${LAST_EXECUTOR_SUMMARY_STATUS:-}"
      local executor_summary_rc="${LAST_EXECUTOR_SUMMARY_RC:-$executor_rc}"
      case "$executor_status" in
        no_patch)
          router_record_outcome "$EXECUTOR_PROVIDER" "success" "no_patch"
          ;;
        provider_failure)
          log "Executor provider $EXECUTOR_PROVIDER provider failure (rc=$executor_summary_rc) - should trigger failover"
          router_record_outcome "$EXECUTOR_PROVIDER" "failure" "provider_failure"
          record_provider_failure "$stage" "$error_hash" "$EXECUTOR_PROVIDER"
          continue  # Retry with next provider (failover, don't burn attempt)
          ;;
        tooling_failure)
          log "Executor provider $EXECUTOR_PROVIDER unavailable (rc=$executor_summary_rc)"
          router_record_outcome "$EXECUTOR_PROVIDER" "failure" "tooling"
          record_provider_failure "$stage" "$error_hash" "$EXECUTOR_PROVIDER"
          continue
          ;;
        misconfigured_model)
          log "Executor provider $EXECUTOR_PROVIDER misconfigured (invalid model string). Marking unhealthy."
          router_record_outcome "$EXECUTOR_PROVIDER" "failure" "misconfigured_model"
          record_provider_failure "$stage" "$error_hash" "$EXECUTOR_PROVIDER"
          continue
          ;;
        patch)
          router_record_outcome "$EXECUTOR_PROVIDER" "success" "$SELECTED_REASON"
          ;;
        *)
          if [ "$executor_rc" -eq 0 ]; then
            router_record_outcome "$EXECUTOR_PROVIDER" "success" "$SELECTED_REASON"
          elif [ "$executor_rc" -eq 3 ]; then
            # Provider failure - failover event
            router_record_outcome "$EXECUTOR_PROVIDER" "failure" "provider_failure"
            record_provider_failure "$stage" "$error_hash" "$EXECUTOR_PROVIDER"
            continue
          else
            router_record_outcome "$EXECUTOR_PROVIDER" "failure" "$SELECTED_REASON"
            record_provider_failure "$stage" "$error_hash" "$EXECUTOR_PROVIDER"
            log "Executor did not produce a fix (rc=$executor_rc)"
          fi
          ;;
      esac

    else
      local no_effects
      no_effects="$(get_api_outcome_count "$stage" "$error_hash" "no_effect")"
      no_effects="${no_effects:-0}"
      if [ "$no_effects" -ge 2 ]; then
        log "API no_effect limit reached ($no_effects >= 2). Marking as give_up."
        enter_stage_give_up "$stage" "API returned no_effect twice; review ${log_file} and rerun './ai/bootstrap_loop.sh $stage'."
        announce_give_up "$stage" "$attempt"
        set -e
        clear_current_stage_progress
        return 1
      fi

      if [ "$api_calls" -ge "$API_CALL_BUDGET" ]; then
        log "API call budget exhausted ($api_calls >= $API_CALL_BUDGET). Marking as give_up."
        enter_stage_give_up "$stage" "API call budget exhausted; inspect ${log_file} before rerunning './ai/bootstrap_loop.sh $stage'."
        announce_give_up "$stage" "$attempt"
        set -e
        clear_current_stage_progress
        return 1
      fi

      log "Error is repeated (attempts >= $EXECUTOR_RETRY_THRESHOLD). Escalating to API."
      update_error_state "$stage" "$error_hash" "api" "true" "false"
      update_rc=$?
      if [ "$update_rc" -ne 0 ]; then
        log "WARNING: Failed to update errors.json for API escalation (rc=$update_rc)."
      fi

      local api_response
      set +e
      api_response="$(trigger_api_escalation "$stage" "$log_file" "$error_hash" "1" "" "$error_key")"
      set -e

      local response_type="${api_response%%:*}"
      local response_data="${api_response#*:}"

      if [ "$response_type" = "failover" ]; then
        log "Architect provider failover: $response_data"
        set -e
        continue
      fi

      if [ "$response_type" = "patch" ]; then
        set +e
        apply_patch "$response_data"
        local patch_rc=$?
        set -e

        if [ "$patch_rc" -eq 0 ]; then
          add_api_outcome "$stage" "$error_hash" "applied"
          reset_error_state "$stage" "$error_hash"
          log "Patch applied. Re-running stage."
        else
          add_api_outcome "$stage" "$error_hash" "apply_failed"
          log "Failed to apply patch"
        fi

      elif [ "$response_type" = "diagnostics" ]; then
        add_api_outcome "$stage" "$error_hash" "no_patch"
        local diag_dir
        diag_dir="$(run_diagnostics "$stage" "$response_data")"

        api_calls="$(get_api_call_count "$stage" "$error_hash")"
        if [ "$api_calls" -ge "$API_CALL_BUDGET" ]; then
          log "API call budget exhausted after diagnostics. Marking as give_up."
          enter_stage_give_up "$stage" "API call budget exhausted after diagnostics; inspect ${log_file} before rerunning './ai/bootstrap_loop.sh $stage'."
          announce_give_up "$stage" "$attempt"
          set -e
          clear_current_stage_progress
          return 1
        fi

        update_error_state "$stage" "$error_hash" "api" "true" "false"
        update_rc=$?
        if [ "$update_rc" -ne 0 ]; then
          log "WARNING: Failed to update errors.json for API diagnostics (rc=$update_rc)."
        fi

        set +e
        api_response="$(trigger_api_escalation "$stage" "$log_file" "$error_hash" "2" "$diag_dir" "$error_key")"
        set -e

        response_type="${api_response%%:*}"
        response_data="${api_response#*:}"

        if [ "$response_type" = "patch" ]; then
          set +e
          apply_patch "$response_data"
          patch_rc=$?
          set -e

          if [ "$patch_rc" -eq 0 ]; then
            add_api_outcome "$stage" "$error_hash" "applied"
            reset_error_state "$stage" "$error_hash"
            log "Patch applied after diagnostics. Re-running stage."
          else
            add_api_outcome "$stage" "$error_hash" "apply_failed"
            log "Failed to apply patch after diagnostics"
          fi
        elif [ "$response_type" = "invalid_format" ]; then
          add_api_outcome "$stage" "$error_hash" "invalid_format"
          log "API response invalid_format after diagnostics"
        else
          add_api_outcome "$stage" "$error_hash" "no_patch"
          log "API response type '$response_type' after diagnostics produced no patch"
        fi
      elif [ "$response_type" = "invalid_format" ]; then
        add_api_outcome "$stage" "$error_hash" "invalid_format"
        log "API response invalid_format"
      else
        add_api_outcome "$stage" "$error_hash" "no_patch"
        log "API response type '$response_type' produced no patch"
      fi
    fi

    set -e
    attempt=$((attempt + 1))
  done

  local attempts_completed=$((attempt - 1))
  log "Maximum attempts reached for stage '$stage'. Marking as give_up."
  enter_stage_give_up "$stage" "Maximum attempts reached; inspect ${log_file} before rerunning './ai/bootstrap_loop.sh $stage'."
  announce_give_up "$stage" "$attempts_completed"
  clear_current_stage_progress
  return 1
}

# =============================================================================
# v7 Convergence Loop
# =============================================================================

# Measure drift using the Drift Engine
measure_drift() {
  if [ ! -f "$DRIFT_ENGINE" ]; then
    log "ERROR: Drift engine not found: $DRIFT_ENGINE"
    return 1
  fi

  python3 "$DRIFT_ENGINE" measure --memo "$ARCHITECTURE_MEMO" --repo-root "$REPO_ROOT" --json
}

# Select next claim from drift engine
select_next_claim() {
  if [ ! -f "$DRIFT_ENGINE" ]; then
    log "ERROR: Drift engine not found: $DRIFT_ENGINE"
    return 1
  fi

  python3 "$DRIFT_ENGINE" select --repo-root "$REPO_ROOT" --json 2>/dev/null
}

# Get drift status
get_drift_status() {
  if [ ! -f "$DRIFT_ENGINE" ]; then
    log "ERROR: Drift engine not found: $DRIFT_ENGINE"
    return 1
  fi

  python3 "$DRIFT_ENGINE" status --repo-root "$REPO_ROOT" --json 2>/dev/null
}

# Mark claim as blocked
block_claim() {
  local claim_id="$1"
  python3 "$DRIFT_ENGINE" block --claim-id "$claim_id" --repo-root "$REPO_ROOT" 2>/dev/null
}

# Increment claim attempts
increment_claim_attempts() {
  local claim_id="$1"
  python3 "$DRIFT_ENGINE" increment --claim-id "$claim_id" --repo-root "$REPO_ROOT" 2>/dev/null
}

# v7: Defer claim due to infrastructure issues (distinct from BLOCKED)
# Returns defer_until timestamp
: "${INFRA_DEFER_MINUTES:=60}"
defer_claim() {
  local claim_id="$1"
  local reason="${2:-architect_unavailable}"
  local minutes="${3:-$INFRA_DEFER_MINUTES}"
  python3 "$DRIFT_ENGINE" defer --claim-id "$claim_id" --reason "$reason" --minutes "$minutes" --repo-root "$REPO_ROOT" --json 2>/dev/null
}

# Clear claim deferral
clear_claim_deferral() {
  local claim_id="$1"
  python3 "$DRIFT_ENGINE" clear-defer --claim-id "$claim_id" --repo-root "$REPO_ROOT" 2>/dev/null
}

# Check if all fail claims are blocked or deferred
# Returns: 0 if all blocked/deferred (no actionable claims), 1 otherwise
# Also sets: BLOCKED_COUNT, DEFERRED_COUNT
all_claims_blocked_or_deferred() {
  local status
  status="$(get_drift_status)"
  if [ -z "$status" ]; then
    return 1
  fi

  # Parse using inline Python for reliability
  local result
  result="$(python3 - "$status" <<'PY'
import json
import sys
from datetime import datetime, timezone

data = json.loads(sys.argv[1])
claims = data.get("claims", [])
now = datetime.now(timezone.utc)

fail_claims = [c for c in claims if c.get("status") == "FAIL"]
if not fail_claims:
    print("0:0:0")  # all_blocked_or_deferred=true, blocked=0, deferred=0
    sys.exit(0)

blocked = 0
deferred = 0
for claim in fail_claims:
    if claim.get("status") == "BLOCKED":
        blocked += 1
        continue
    defer_until = claim.get("defer_until")
    if defer_until:
        try:
            defer_dt = datetime.fromisoformat(defer_until)
            if defer_dt > now:
                deferred += 1
                continue
        except ValueError:
            pass

actionable = len(fail_claims) - blocked - deferred
if actionable == 0:
    print(f"0:{blocked}:{deferred}")
else:
    print(f"1:{blocked}:{deferred}")
PY
)"

  local rc blocked deferred
  rc="${result%%:*}"
  local rest="${result#*:}"
  blocked="${rest%%:*}"
  deferred="${rest#*:}"

  export BLOCKED_COUNT="${blocked:-0}"
  export DEFERRED_COUNT="${deferred:-0}"

  [ "$rc" = "0" ]
}

# Legacy compatibility wrapper
all_claims_blocked() {
  all_claims_blocked_or_deferred
}

# Extract claim target from JSON
get_claim_target() {
  local claim_json="$1"
  echo "$claim_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('evaluation',{}).get('target',''))" 2>/dev/null
}

# Extract claim ID from JSON
get_claim_id() {
  local claim_json="$1"
  echo "$claim_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null
}

# Extract claim text from JSON
get_claim_text() {
  local claim_json="$1"
  echo "$claim_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('text',''))" 2>/dev/null
}

# Extract claim evaluation method
get_claim_method() {
  local claim_json="$1"
  echo "$claim_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('evaluation',{}).get('method',''))" 2>/dev/null
}

# Determine the most appropriate stage for a claim target path
determine_claim_stage() {
  local target="$1"
  if [ -z "$target" ] || [ ! -f "$CONTEXT_MAP" ]; then
    echo ""
    return
  fi
  python3 - "$CONTEXT_MAP" "$target" <<'PY'
import os
import re
import sys

cfg_path = sys.argv[1]
raw_target = sys.argv[2]
try:
    lines = open(cfg_path).read().splitlines()
except Exception:
    sys.exit(0)

inside = False
current_stage = None
collect_files = False
stages = {}

for line in lines:
    if not inside:
        if re.match(r'^\s*stages:\s*$', line):
            inside = True
        continue
    if re.match(r'^\s{2}[^\s:]+:\s*$', line) and not line.startswith('    '):
        match = re.match(r'^\s{2}([^\s:]+):', line)
        if match:
            current_stage = match.group(1)
            stages[current_stage] = []
            collect_files = False
        continue
    if current_stage:
        if re.match(r'^\s{4}files:\s*$', line):
            collect_files = True
            continue
        if collect_files:
            file_match = re.match(r'^\s{6}-\s+(.+)$', line)
            if file_match:
                entry = file_match.group(1).strip()
                if entry:
                    stages[current_stage].append(entry)
                continue
            if not line.startswith('      '):
                collect_files = False
        if re.match(r'^\s{2}[^\s:]+:\s*$', line) and not line.startswith('    '):
            collect_files = False

target_norm = os.path.normpath(raw_target)
if target_norm == '.':
    target_norm = raw_target.strip()
target_norm = target_norm.rstrip(os.sep)

best_stage = ""
best_score = -1
for stage_name, entries in stages.items():
    for entry in entries:
        entry_norm = os.path.normpath(entry)
        entry_norm = entry_norm.rstrip(os.sep)
        if not entry_norm:
            continue
        if target_norm == entry_norm or target_norm.startswith(entry_norm + os.sep):
            score = len(entry_norm)
            if score > best_score:
                best_score = score
                best_stage = stage_name

print(best_stage)
PY
}

# Generate error key from claim
claim_to_error_key() {
  local claim_id="$1"
  echo "claim_${claim_id}"
}

# Call executor for a specific claim
call_executor_for_claim() {
  local claim_json="$1"
  local claim_id="$2"
  local attempt="$3"

  local claim_target claim_text
  claim_target="$(get_claim_target "$claim_json")"
  claim_text="$(get_claim_text "$claim_json")"
  local error_key
  error_key="$(claim_to_error_key "$claim_id")"
  local claim_method
  claim_method="$(get_claim_method "$claim_json")"
  local claim_stage
  claim_stage="$(determine_claim_stage "$claim_target")"
  if [ -z "$claim_stage" ]; then
    claim_stage="converge"
  fi

  log "[converge] Working on claim: $claim_id"
  log "[converge]   Target: $claim_target"
  log "[converge]   Text: $claim_text"
  log "[converge]   Attempt: $attempt"
  log "[converge] Claim mapped to stage: $claim_stage"

  # Select executor provider
  if ! router_select_provider "executor" "$error_key"; then
    log "[converge] No executor provider available"
    if [ "$SELECTOR_FALLBACK_MODE" = "safe_mode" ]; then
      return 2
    fi
    return 1
  fi

  # Map provider names (router returns ollama_executor, executor expects ollama)
  local mapped_provider="$SELECTED_PROVIDER"
  if [ "$mapped_provider" = "ollama_executor" ]; then
    mapped_provider="ollama"
  fi
  export EXECUTOR_PROVIDER="$mapped_provider"
  export EXECUTOR_PROVIDER_MODEL="$SELECTED_MODEL"
  log "Router decision: role=EXECUTOR provider=$SELECTED_PROVIDER model=$SELECTED_MODEL reason=$SELECTED_REASON tier=$SELECTED_TIER health_reason=${SELECTED_HEALTH_REASON:-healthy}"

  # Create context for executor
  local context_file
  context_file="${STATE_DIR}/claim_context.json"
  cat > "$context_file" <<EOF
{
  "claim_id": "$claim_id",
  "claim_target": "$claim_target",
  "claim_text": "$claim_text",
  "attempt": $attempt,
  "method": "$claim_method",
  "mode": "converge"
}
EOF

  export CLAIM_CONTEXT_FILE="$context_file"
  export CLAIM_TARGET_PATH="$claim_target"
  export CLAIM_EVALUATION_METHOD="$claim_method"

  # Run executor (simplified - maps to stage for compatibility)
  local stage="$claim_stage"
  local log_file="${LOG_DIR}/runs/converge_${claim_id}_$(date -u +%Y%m%d_%H%M%S).log"
  local error_hash
  error_hash="$(echo -n "$claim_id" | sha256sum | cut -c1-16)"

  set +e
  call_executor "$stage" "$log_file" "$error_hash" "$attempt"
  local executor_rc=$?
  set -e
  if [ "$executor_rc" -eq 4 ]; then
    log "[converge] Executor provider $EXECUTOR_PROVIDER misconfigured (invalid model string). Marking unhealthy."
    router_record_outcome "$EXECUTOR_PROVIDER" "failure" "misconfigured_model"
    record_provider_failure "$stage" "$error_hash" "$EXECUTOR_PROVIDER"
    return 3
  fi
  unset CLAIM_CONTEXT_FILE CLAIM_TARGET_PATH CLAIM_EVALUATION_METHOD

  if [ "$executor_rc" -eq 0 ]; then
    router_record_outcome "$EXECUTOR_PROVIDER" "success" "claim_fix"
    log "[converge] Executor succeeded for claim $claim_id"
    return 0
  elif [ "$executor_rc" -eq 3 ]; then
    # Provider failure - record as failure for circuit breaker, but return special code for failover
    # This should NOT burn an attempt (v7 guarantee: provider failures are failover events)
    router_record_outcome "$EXECUTOR_PROVIDER" "failure" "provider_failure"
    log "[converge] Provider failure - should failover to next provider (rc=$executor_rc)"
    return 3  # Special code for provider failure / failover
  elif [ "$executor_rc" -eq 127 ]; then
    router_record_outcome "$EXECUTOR_PROVIDER" "failure" "tooling"
    log "[converge] Executor provider unavailable"
    return 1
  else
    router_record_outcome "$EXECUTOR_PROVIDER" "failure" "no_fix"
    log "[converge] Executor did not fix claim (rc=$executor_rc)"
    return 1
  fi
}

# Extract provider status from router output lines or JSON
extract_provider_status_from_output() {
  local output="$1"
  local status
  status="$(printf '%s\n' "$output" | awk -F= '/^status=/ {print $2; exit}' | tr -d '\r')"
  if [ -n "$status" ]; then
    printf '%s' "$status"
    return
  fi
  status="$(python3 - <<'PY' <<< "$output"
import json, sys
text = sys.stdin.read()
try:
    data = json.loads(text.strip())
    print(data.get("status", ""))
except Exception:
    pass
PY
)"
  if [ -n "$status" ]; then
    printf '%s' "$status"
    return
  fi
  printf 'unknown'
}

# Extract architect response type or diff payload
# v7 contract: MUST always print a deterministic value, never empty
extract_architect_type() {
  local response_file="$1"
  if [ ! -f "$response_file" ]; then
    printf 'missing_file'
    return
  fi
  local result
  result="$(python3 - "$response_file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        text = f.read().strip()
except (FileNotFoundError, UnicodeDecodeError) as e:
    print("file_error")
    sys.exit(0)

if not text:
    print("empty_response")
    sys.exit(0)

# Handle multi-line JSON (JSONL) - take first line
if '\n' in text:
    text = text.split('\n')[0].strip()

try:
    data = json.loads(text)
except json.JSONDecodeError:
    print("invalid_json")
    sys.exit(0)

if not isinstance(data, dict):
    print("invalid_type")
    sys.exit(0)

response_type = data.get("type", "")
if response_type:
    print(response_type)
else:
    print("unknown")
PY
)"
  # Ensure we never output empty string
  if [ -z "$result" ]; then
    printf 'extraction_failed'
  else
    printf '%s' "$result"
  fi
}

extract_architect_diff() {
  local response_file="$1"
  if [ ! -f "$response_file" ]; then
    return
  fi
  python3 - <<'PY' "$response_file"
import json, sys
def normalize(value):
    if isinstance(value, list):
        return "\\n".join(str(v) for v in value)
    if value is None:
        return ""
    return str(value)
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for key in ("diff", "patch", "plan"):
    candidate = normalize(data.get(key))
    if candidate and candidate.strip():
        print(candidate)
        sys.exit(0)
PY
}

# Validate architect output before accepting it
# v7 contract: type=error is a provider failure, not valid output
validate_architect_output_contract() {
  local response_file="$1"
  python3 - "$response_file" <<'PY'
import json
import sys
import os

path = sys.argv[1]
if not os.path.isfile(path):
    print("missing_response")
    sys.exit(1)
try:
    text = open(path, encoding="utf-8").read()
except UnicodeDecodeError:
    print("invalid_utf8")
    sys.exit(2)
except FileNotFoundError:
    print("missing_response")
    sys.exit(1)

if not text.strip():
    print("empty_output")
    sys.exit(3)

# Handle multi-line JSON (JSONL) - take first line
text = text.strip()
if '\n' in text:
    text = text.split('\n')[0].strip()

try:
    payload = json.loads(text)
except json.JSONDecodeError:
    print("invalid_json")
    sys.exit(4)

if not isinstance(payload, dict):
    print("invalid_payload_type")
    sys.exit(5)

# v7 contract: type=error is a provider failure (triggers failover)
response_type = payload.get("type", "")
if response_type == "error":
    reason = payload.get("reason", "unknown")
    print(f"provider_error:{reason}")
    sys.exit(7)

# Check for actionable payload keys
valid_keys = ("patch_plan", "diff", "patch", "plan", "diagnostic_request")
for key in valid_keys:
    value = payload.get(key)
    if value:
        if isinstance(value, str) and not value.strip():
            continue
        print("valid_output")
        sys.exit(0)

# type=no_patch is valid (claim made no progress, but provider worked)
if response_type == "no_patch":
    print("no_patch")
    sys.exit(0)

print("missing_contract_payload")
sys.exit(6)
PY
}

# Escalate claim to architect
escalate_claim_to_architect() {
  local claim_json="$1"
  local claim_id="$2"

  local claim_target claim_text
  claim_target="$(get_claim_target "$claim_json")"
  claim_text="$(get_claim_text "$claim_json")"
  local error_key
  error_key="$(claim_to_error_key "$claim_id")"
  local claim_error_hash
  claim_error_hash="$(echo -n "$claim_id" | sha256sum | cut -c1-16)"

  log "[converge] Escalating to architect for claim: $claim_id"

  # Build case file for architect
  # Note: claim_id already has 'claim_' prefix from drift_engine
  local case_file="${ESCALATION_DIR}/${claim_id}_case.md"
  cat > "$case_file" <<EOF
# Claim Analysis Request

## Claim ID
$claim_id

## Target
$claim_target

## Description
$claim_text

## Context
The orchestrator has attempted to fix this claim $CLAIM_ATTEMPT_THRESHOLD times without success.
Please analyze the issue and provide a patch plan.

## Constraints
- Patches MUST NOT modify protected files
- Patches MUST stay within allowed paths
- Patches MUST be minimal and focused
EOF

  local response_file="${ESCALATION_DIR}/${claim_id}_response.json"
  local patch_file="${ESCALATION_DIR}/${claim_id}.patch"

  local provider_failures=0
  local last_provider_status="unknown"

  while [ "$provider_failures" -lt "$MAX_ARCHITECT_PROVIDER_FAILOVERS" ]; do
    if ! router_select_provider "architect" "$error_key"; then
      log "[converge] No architect provider available (router fallback_mode=${SELECTOR_FALLBACK_MODE:-unknown})"
      log "[converge] This is an infrastructure failure - check env vars and provider config"
      if [ "$SELECTOR_FALLBACK_MODE" = "safe_mode" ]; then
        # Write to issues.yaml
        local timestamp
        timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '\n- timestamp: %s\n  type: infra_failure\n  message: "No architect providers available (router fallback)"\n  claim_id: %s\n  fallback_mode: %s\n' \
          "$timestamp" "$claim_id" "${SELECTOR_FALLBACK_MODE:-unknown}" >> "$ISSUES_FILE"
        return 2
      fi
      return 1
    fi

    log "Router decision: role=ARCHITECT provider=$SELECTED_PROVIDER model=$SELECTED_MODEL reason=$SELECTED_REASON tier=$SELECTED_TIER health_reason=${SELECTED_HEALTH_REASON:-healthy}"

    : > "$response_file"

    set +e
    local provider_output provider_rc
    if [ "$SELECTED_PROVIDER" = "ollama_architect" ]; then
      provider_output="$(ai/providers/ollama.sh call "$case_file" "$response_file" "$SELECTED_MODEL" "$error_key" 2>&1)"
      provider_rc=$?
    else
      provider_output="$("$OPENROUTER_PROVIDER_CMD" call "$case_file" "$response_file" "$SELECTED_TIER" "$error_key" "$SELECTED_MODEL" 2>&1)"
      provider_rc=$?
    fi
    set -e

    local provider_status
    provider_status="$(extract_provider_status_from_output "$provider_output")"
    last_provider_status="$provider_status"

    if [ "$provider_rc" -ne 0 ]; then
      log "[converge] Architect provider $SELECTED_PROVIDER failed (status=$provider_status, rc=$provider_rc)"
      router_record_outcome "$SELECTED_PROVIDER" "failure" "provider_failure"
      record_provider_failure "converge" "$claim_error_hash" "$SELECTED_PROVIDER"
      provider_failures=$((provider_failures + 1))
      if [ "$provider_failures" -ge "$MAX_ARCHITECT_PROVIDER_FAILOVERS" ]; then
        log "[converge] All architect providers exhausted after $provider_failures failures"
        return 3
      fi
      log "[converge] Failing over to next architect provider (failure #$provider_failures)"
      continue
    fi

    local validation_reason validation_rc
    set +e
    validation_reason="$(validate_architect_output_contract "$response_file")"
    validation_rc=$?
    set -e
    validation_reason="${validation_reason//$'\n'/}"
    if [ "$validation_rc" -ne 0 ]; then
      log "[converge] Architect provider $SELECTED_PROVIDER returned invalid output (reason=${validation_reason:-unknown})"
      last_provider_status="invalid_output:${validation_reason:-unknown}"
      router_record_outcome "$SELECTED_PROVIDER" "failure" "invalid_output"
      record_provider_failure "converge" "$claim_error_hash" "$SELECTED_PROVIDER"
      break_router_sticky_route "architect" "$error_key"
      log "[converge] Sticky routing broken for claim $claim_id due to invalid architect output"
      provider_failures=$((provider_failures + 1))
      if [ "$provider_failures" -ge "$MAX_ARCHITECT_PROVIDER_FAILOVERS" ]; then
        log "[converge] All architect providers exhausted after $provider_failures failures"
        return 3
      fi
      log "[converge] Failing over to next architect provider (failure #$provider_failures)"
      continue
    fi

    router_record_outcome "$SELECTED_PROVIDER" "success" "architect_response"

    local response_type
    response_type="$(extract_architect_type "$response_file")"
    response_type="${response_type:-unknown}"
    log "[converge] Architect response type: $response_type"

    local diff_content
    diff_content="$(extract_architect_diff "$response_file")"
    if [ -n "$diff_content" ]; then
      printf '%s\n' "$diff_content" > "$patch_file"
      log "[converge] Architect returned a diff; applying patch"

      set +e
      apply_patch "$patch_file"
      local patch_rc=$?
      set -e

      if [ "$patch_rc" -eq 0 ]; then
        log "[converge] Architect patch applied successfully"
        return 0
      fi

      log "[converge] Architect patch failed to apply"
      return 1
    fi

    log "[converge] Architect did not provide a diff (type=$response_type)"
    return 1
  done

  # v7 terminal condition: All architect providers exhausted
  log "[converge] No healthy architect providers available (infra/output/config failure)"
  log "[converge] Last provider status: ${last_provider_status:-unknown}"
  log "[converge] Provider failures in this escalation: $provider_failures"

  # Write entry to issues.yaml
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '\n- timestamp: %s\n  type: infra_failure\n  message: "No healthy architect providers available (infra/output/config failure)"\n  claim_id: %s\n  provider_failures: %s\n  last_status: %s\n' \
    "$timestamp" "$claim_id" "$claim_id" "$provider_failures" "${last_provider_status:-unknown}" >> "$ISSUES_FILE"

  return 3
}

# Main v7 convergence loop
converge_loop() {
  log "=== Starting v7 Convergence Loop ==="
  log "Memo: $ARCHITECTURE_MEMO"

  ensure_directories
  ensure_state_files

  # Acquire lock
  if ! acquire_lock; then
    log "ERROR: Could not acquire state lock"
    return 1
  fi
  trap 'release_lock' EXIT INT TERM

  # Initial drift measurement
  log "[converge] Measuring initial drift..."
  local drift_output
  set +e
  drift_output="$(measure_drift 2>/dev/null)"
  local drift_rc=$?
  set -e

  if [ "$drift_rc" -ne 0 ] || [ -z "$drift_output" ]; then
    log "ERROR: Failed to measure drift"
    return 1
  fi

  local drift_score episode
  drift_score="$(echo "$drift_output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('drift_score',1.0))" 2>/dev/null)"
  episode="$(echo "$drift_output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('episode',''))" 2>/dev/null)"

  log "[converge] Episode: $episode"
  log "[converge] Initial drift score: $drift_score"

  if [ "$(echo "$drift_score == 0" | bc -l 2>/dev/null || echo "0")" = "1" ]; then
    set +e
    if run_k3s_probe; then
      log "[converge] Drift is zero and k3s reality probe passed. System is converged!"
      set -e
      return 0
    fi
    set -e
    log "[converge] Repo is converged but reality is unknown or failing — intervention required."
    if [ -n "$LAST_STAGE_PROBE_SUMMARY" ]; then
      printf '%s\n' "$LAST_STAGE_PROBE_SUMMARY" | while IFS= read -r line; do
        log "Probe: $line"
      done
    fi
    return 1
  fi

  local cycle=0
  local start_time
  start_time="$(date +%s)"
  local max_duration=$((SAFE_MODE_MAX_DURATION_MINUTES * 60))

  while [ "$cycle" -lt "$MAX_CONVERGE_CYCLES" ]; do
    cycle=$((cycle + 1))
    log "[converge] === Cycle $cycle ==="

    # Check duration limit
    local elapsed
    elapsed="$(($(date +%s) - start_time))"
    if [ "$elapsed" -ge "$max_duration" ]; then
      log "[converge] Duration limit reached (${elapsed}s >= ${max_duration}s). Entering safe mode."
      enter_safe_mode "duration_limit" "converge" "cycle_$cycle"
      return 1
    fi

    # Select next claim
    local claim_json claim_id
    set +e
    claim_json="$(select_next_claim)"
    set -e

    if [ -z "$claim_json" ] || [ "$claim_json" = "null" ]; then
      # Check if all claims are blocked or deferred
      if all_claims_blocked_or_deferred; then
        if [ "${DEFERRED_COUNT:-0}" -gt 0 ] && [ "${BLOCKED_COUNT:-0}" -eq 0 ]; then
          # All claims deferred (infra issue) but none permanently blocked
          log "[converge] All FAIL claims are deferred ($DEFERRED_COUNT). Infra issue - entering safe mode."
          enter_safe_mode "all_claims_deferred" "converge" "cycle_$cycle"
          return 1
        elif [ "${DEFERRED_COUNT:-0}" -gt 0 ]; then
          # Some blocked, some deferred
          log "[converge] Claims blocked ($BLOCKED_COUNT) + deferred ($DEFERRED_COUNT). No actionable claims."
          enter_safe_mode "all_claims_blocked_or_deferred" "converge" "cycle_$cycle"
          return 1
        else
          # All blocked (no deferred)
          log "[converge] All FAIL claims are blocked. Entering safe mode."
          enter_safe_mode "all_claims_blocked" "converge" "cycle_$cycle"
          return 1
        fi
      fi

      # Re-measure drift
      set +e
      drift_output="$(measure_drift 2>/dev/null)"
      set -e
      drift_score="$(echo "$drift_output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('drift_score',0))" 2>/dev/null)"

      if [ "$(echo "$drift_score == 0" | bc -l 2>/dev/null || echo "0")" = "1" ]; then
        log "[converge] Convergence achieved! Drift score: 0"
        return 0
      fi

      log "[converge] No safe claim available. Waiting for next cycle."
      sleep 5
      continue
    fi

    claim_id="$(get_claim_id "$claim_json")"
    log "[converge] Selected claim: $claim_id"

    # Get current attempt count for this claim
    local claim_attempts
    claim_attempts="$(echo "$claim_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('attempts',0))" 2>/dev/null)"
    claim_attempts="${claim_attempts:-0}"

    # Attempt 1-2: Executor only
    if [ "$claim_attempts" -lt 2 ]; then
      local attempt=$((claim_attempts + 1))
      local provider_retries=0
      local max_provider_retries=3  # Try up to 3 providers (Codex, Ollama, etc.)
      
      local exec_rc=0
      log "[converge] Starting provider retry loop (max_retries=$max_provider_retries)"
      while [ "$provider_retries" -lt "$max_provider_retries" ]; do
        log "[converge] Provider retry loop iteration $((provider_retries + 1))/$max_provider_retries"
        # Use subshell to safely capture return code without causing script exit
        set +e
        exec_rc=0
        call_executor_for_claim "$claim_json" "$claim_id" "$attempt" || exec_rc=$?
        set +e  # Keep set +e to prevent exit on non-zero return codes
        
        log "[converge] call_executor_for_claim returned: $exec_rc (provider_retries=$provider_retries)"

        if [ "$exec_rc" -eq 3 ]; then
          # Provider failure - failover event, don't burn attempt (v7 guarantee)
          provider_retries=$((provider_retries + 1))
          log "[converge] Provider failure - retrying with next provider (retry $provider_retries/$max_provider_retries, attempt not incremented)"
          if [ "$provider_retries" -ge "$max_provider_retries" ]; then
            log "[converge] Max provider retries exhausted - all providers had provider failures, skipping this claim for now"
            exec_rc=3  # Signal that all providers failed
            break
          fi
          sleep 1  # Brief pause before retry
          continue  # Retry with next provider
        else
          # Not a provider failure - break out of provider retry loop
          break
        fi
      done
      set +e  # Keep set +e since we need to check exec_rc

      # Only increment attempt if not a provider failure (all providers exhausted)
      # Provider failures don't burn attempts per v7 spec
      if [ "$exec_rc" -ne 3 ]; then
        increment_claim_attempts "$claim_id"
      fi

      if [ "$exec_rc" -eq 0 ]; then
        # Re-measure drift after successful fix
        set +e
        drift_output="$(measure_drift 2>/dev/null)"
        drift_score="$(echo "$drift_output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('drift_score',0))" 2>/dev/null)"
        set -e
        log "[converge] Drift score after fix: $drift_score"
        continue
      elif [ "$exec_rc" -eq 2 ]; then
        # Safe mode triggered
        enter_safe_mode "no_executor" "converge" "$claim_id"
        set -e
        return 1
      elif [ "$exec_rc" -eq 3 ]; then
        # All providers exhausted due to provider failures - skip this claim, try next
        log "[converge] All executor providers had provider failures - skipping claim for now, will retry later"
        set -e
        continue  # Move to next claim
      else
        # Other failure - move to next claim  
        log "[converge] Executor failed with code $exec_rc - moving to next claim"
        set -e
        continue
      fi
    fi

    # Attempt 3: Architect escalation
    if [ "$claim_attempts" -eq 2 ]; then
      log "[converge] Claim $claim_id reached attempt 3 - escalating to architect"
      set +e
      escalate_claim_to_architect "$claim_json" "$claim_id"
      local arch_rc=$?
      set -e

      if [ "$arch_rc" -ne 3 ]; then
        increment_claim_attempts "$claim_id"
      else
        log "[converge] Architect provider failure preserved attempt budget (attempt still 3)"
      fi

      if [ "$arch_rc" -eq 0 ]; then
        # Re-measure drift
        set +e
        drift_output="$(measure_drift 2>/dev/null)"
        set -e
        drift_score="$(echo "$drift_output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('drift_score',0))" 2>/dev/null)"
        log "[converge] Drift score after architect fix: $drift_score"
        continue
      elif [ "$arch_rc" -eq 1 ]; then
        # v7 contract: arch_rc=1 = architect responded but no progress (no diff)
        # This is NOT a provider failure - the provider worked but couldn't help
        # Defer the claim to prevent infinite escalation loops
        log "[converge] Architect returned no actionable output; deferring claim $claim_id"
        local defer_result
        defer_result="$(defer_claim "$claim_id" "architect_no_progress" "${INFRA_DEFER_MINUTES:-30}")"
        if [ -n "$defer_result" ]; then
          log "[converge] Claim $claim_id deferred until $defer_result"
        fi
        if all_claims_blocked_or_deferred; then
          log "[converge] All FAIL claims are now blocked ($BLOCKED_COUNT) or deferred ($DEFERRED_COUNT)"
          log "[converge] No actionable claims remaining; entering safe mode."
          enter_safe_mode "all_claims_deferred_no_progress" "converge" "$claim_id"
          return 1
        fi
        continue
      elif [ "$arch_rc" -eq 2 ]; then
        enter_safe_mode "no_architect" "converge" "$claim_id"
        return 1
      elif [ "$arch_rc" -eq 3 ]; then
        # v7 contract: arch_rc=3 = provider infrastructure failure
        # Defer with longer cooldown since it's an infra issue
        log "[converge] All architect providers exhausted (infra/output/config failure); deferring claim $claim_id"
        local defer_result
        defer_result="$(defer_claim "$claim_id" "architect_providers_exhausted" "${INFRA_DEFER_MINUTES:-60}")"
        if [ -n "$defer_result" ]; then
          log "[converge] Claim $claim_id deferred until $defer_result"
        fi
        if all_claims_blocked_or_deferred; then
          log "[converge] All FAIL claims are now blocked ($BLOCKED_COUNT) or deferred ($DEFERRED_COUNT)"
          log "[converge] Infrastructure failure: entering safe mode."
          enter_safe_mode "all_claims_blocked_or_deferred" "converge" "$claim_id"
          return 1
        fi
        continue
      fi
      continue
    fi

    # Attempt 4+: Block the claim
    if [ "$claim_attempts" -ge 3 ]; then
      log "[converge] Claim $claim_id reached max attempts. Marking as BLOCKED."
      block_claim "$claim_id"
      continue
    fi
  done

  log "[converge] Max cycles reached ($MAX_CONVERGE_CYCLES). Entering safe mode."
  enter_safe_mode "max_cycles" "converge" "cycle_$cycle"
  return 1
}

# =============================================================================
# Main Entry Point
# =============================================================================
main() {
  if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  converge - v7 memo-driven convergence mode (recommended)"
    echo "  drift    - Show current drift status"
    echo ""
    echo "Legacy Stages:"
    echo "  vms      - Proxmox VM creation/config"
    echo "  k3s      - k3s bootstrap"
    echo "  infra    - Flux + core platform components"
    echo "  apps     - Homelab applications"
    echo "  ingress  - Ingress, Cloudflare, DNS"
    echo "  obs      - Observability stack"
    echo "  all      - Run all stages in order"
    echo "  status   - Show current stage status"
    echo ""
    echo "Options:"
    echo "  --reset  - Reset error state for the stage"
    echo "  --memo <path> - Override architecture memo (converge mode)"
    exit 1
  fi

  local command="$1"
  shift || true
  local reset_mode="${1:-}"

  ensure_directories
  ensure_state_files

  # v7 Converge command
  if [ "$command" = "converge" ]; then
    # Parse optional --memo flag
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --memo)
          shift
          ARCHITECTURE_MEMO="${1:-$ARCHITECTURE_MEMO}"
          shift || true
          ;;
        *)
          shift
          ;;
      esac
    done
    converge_loop
    exit $?
  fi

  if [ "$command" = "reset" ]; then
    local stage_to_reset=""
    local force="false"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --force)
          force="true"
          shift
          ;;
        *)
          if [ -z "$stage_to_reset" ]; then
            stage_to_reset="$1"
          fi
          shift
          ;;
      esac
    done
    if [ -z "$stage_to_reset" ]; then
      echo "Usage: $0 reset <stage> [--force]"
      exit 1
    fi
  set +e
  reset_give_up_stage "$stage_to_reset" "$force"
  local reset_rc=$?
  set -e
  if [ "$reset_rc" -eq 0 ]; then
    set_stage_status "$stage_to_reset" "idle"
    exit 0
  fi
  if [ "$reset_rc" -eq 1 ]; then
    log "No give_up entry for stage $stage_to_reset; forcing stage status to idle."
    set_stage_status "$stage_to_reset" "idle"
    exit 0
  fi
  exit "$reset_rc"
  fi

  # Drift status command
  if [ "$command" = "drift" ]; then
    if [ -f "$DRIFT_STATE_FILE" ]; then
      echo "Current drift state:"
      cat "$DRIFT_STATE_FILE"
    else
      echo "No drift state found. Run 'converge' to measure drift."
      exit 1
    fi
    exit 0
  fi

  # Legacy stage-based commands
  local stage="$command"

  if [ "$stage" = "status" ]; then
    echo "Current stage status:"
    cat "$STAGE_STATUS_JSON"
    echo ""
    echo "Error state:"
    cat "$ERRORS_JSON"
    echo ""
    if [ -f "$DRIFT_STATE_FILE" ]; then
      echo "Drift state:"
      python3 -c "import json; d=json.load(open('$DRIFT_STATE_FILE')); print(f\"  Episode: {d.get('episode','N/A')}\"); print(f\"  Drift: {d.get('drift_score',0):.3f}\"); print(f\"  Structural: {d.get('structural_drift',{}).get('score',0):.3f}\"); print(f\"  Operational: {d.get('operational_drift',{}).get('score',0):.3f}\")" 2>/dev/null || echo "  (unable to parse)"
    fi
    exit 0
  fi

  if [ "$reset_mode" = "--reset" ]; then
    log "Resetting stage '$stage' to idle"
    set_stage_status "$stage" "idle"
    # Clear all error states for this stage
    local reset_content
    reset_content="$(
python3 - "$ERRORS_JSON" "$stage" "$ISSUES_FILE" <<'PY'
import json
import os
import sys
from datetime import datetime

path, stage, issues_path = sys.argv[1:4]

def load_data():
    data = {}
    if os.path.exists(path):
        try:
            with open(path) as f:
                data = json.load(f)
        except json.JSONDecodeError:
            timestamp = datetime.utcnow().strftime("%Y%m%d-%H%M%SZ")
            corrupt_path = f"{path}.corrupted.{timestamp}"
            os.rename(path, corrupt_path)
            msg = f"[{datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}] WARNING: Corrupted JSON moved to {corrupt_path}\n"
            parent = os.path.dirname(issues_path)
            if parent and not os.path.isdir(parent):
                os.makedirs(parent, exist_ok=True)
            with open(issues_path, "a") as fh:
                fh.write(msg)
            data = {}
        except FileNotFoundError:
            data = {}
    return data

data = load_data()
keys_to_remove = [k for k in data if k.startswith(stage + "_")]
for k in keys_to_remove:
    del data[k]
print(json.dumps(data, indent=2))
PY
    )"
    atomic_json_write "$ERRORS_JSON" "$reset_content"
    log "Reset complete"
    exit 0
  fi

  if [ "$stage" = "all" ]; then
    local stages=("vms" "k3s" "infra" "apps" "ingress" "obs")
    for s in "${stages[@]}"; do
      if ! orchestrate_stage "$s"; then
        log "Stage '$s' failed. Stopping."
        exit 1
      fi
    done
    log "All stages completed successfully!"
    exit 0
  fi

  # Validate stage name
  case "$stage" in
    vms|k3s|infra|apps|ingress|obs)
      orchestrate_stage "$stage"
      ;;
    *)
      echo "ERROR: Unknown stage '$stage'"
      exit 1
      ;;
  esac
}

main "$@"
