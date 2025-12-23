#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$REPO_ROOT"

: "${MODEL_ROUTER_CONFIG:=ai/config/model_router.yaml}"
: "${OPENROUTER_LOG_DIR:=logs/provider/openrouter}"
: "${OPENROUTER_SECRETS_FILE:=config/secrets/openrouter.env}"
: "${OPENROUTER_MODEL_DISCOVERY_TIMEOUT:=8}"

mkdir -p "$OPENROUTER_LOG_DIR"
LOG_FILE="${OPENROUTER_LOG_DIR}/openrouter.log"

if [ -f "$OPENROUTER_SECRETS_FILE" ]; then
  # shellcheck disable=SC1090
  source "$OPENROUTER_SECRETS_FILE"
fi

: "${OPENROUTER_API_KEY:=}"

log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[%s] %s\n' "$ts" "$*" >> "$LOG_FILE"
}

fetch_openrouter_settings() {
  python3 - "$MODEL_ROUTER_CONFIG" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as fh:
    cfg = json.load(fh)
openrouter = cfg.get('openrouter', {})
print(openrouter.get('api_url', 'https://openrouter.ai/api/v1/chat/completions'))
print(openrouter.get('models_url', 'https://openrouter.ai/api/v1/models'))
PY
}

# Read settings line-by-line (portable: avoids mapfile which requires bash 4+)
__cfg_api_url=""
__cfg_models_url=""
{
  IFS= read -r __cfg_api_url || true
  IFS= read -r __cfg_models_url || true
} < <(fetch_openrouter_settings)
: "${OPENROUTER_API_URL:=${__cfg_api_url:-https://openrouter.ai/api/v1/chat/completions}}"
: "${OPENROUTER_MODELS_URL:=${__cfg_models_url:-https://openrouter.ai/api/v1/models}}"

get_tier_config() {
  local tier="${1:-}"
  python3 - "$MODEL_ROUTER_CONFIG" "$tier" <<'PY'
import json
import sys

path = sys.argv[1]
tier = sys.argv[2]
with open(path) as fh:
    cfg = json.load(fh)
entry = cfg.get('provider_tiers', {}).get(tier, {})
print(entry.get('timeout', 120))
print(entry.get('capacity', 'paid'))
print(json.dumps(entry.get('preferred_models', [])))
PY
}

select_free_model() {
  if [ -z "${OPENROUTER_MODELS_URL:-}" ]; then
    return 1
  fi
  local url="${OPENROUTER_MODELS_URL%/}"
  set +e
  local resp
  resp="$(curl -s -H "Authorization: Bearer $OPENROUTER_API_KEY" --max-time "$OPENROUTER_MODEL_DISCOVERY_TIMEOUT" "$url")"
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ] || [ -z "$resp" ]; then
    return 1
  fi
  local model
  model="$(python3 - "$resp" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
candidates = []
for entry in data.get('models', []) or data.get('data', []):
    name = entry.get('name')
    if not name:
        continue
    caps = entry.get('capabilities', [])
    if not isinstance(caps, list):
        caps = []
    if any(tag in caps for tag in ('code', 'reasoning', 'instruct', 'chat')):
        score = entry.get('context_length', 0)
        candidates.append((score, name))
if not candidates:
    sys.exit(1)
candidates.sort(key=lambda item: (-item[0], item[1]))
print(candidates[0][1])
PY
)"
  if [ -z "$model" ]; then
    return 1
  fi
  printf '%s' "$model"
}

build_payload() {
  local model="$1"
  local case_file="$2"
  python3 - "$model" "$case_file" <<'PY'
import json
import sys

model = sys.argv[1]
case_path = sys.argv[2]
with open(case_path) as fh:
    case_content = fh.read()

payload = {
    "model": model,
    "messages": [
        {
            "role": "system",
            "content": "You are the planner persona for an Ubuntu Server + k3s homelab running on Proxmox. Analyze the case file and respond with exactly one JSON object describing backlog tasks to execute (reconcile, delete/reset, apply, validate). No prose, no markdown fences, and no surrounding explanation. The object must follow this schema: {\\\"tasks\\\":[{\\\"id\\\":\\\"S1-RECOVER-001\\\",\\\"persona\\\":\\\"executor\\\",\\\"summary\\\":\\\"...\\\",\\\"detail\\\":\\\"...\\\",\\\"target\\\":\\\"path/to/script.sh\\\",\\\"depends_on\\\":[\\\"PARENT\\\"]}]}."
        },
        {
            "role": "user",
            "content": case_content
        }
    ],
    "temperature": 0.3,
    "max_tokens": 4096
}
print(json.dumps(payload))
PY
}

call_openrouter() {
  local case_file="$1"
  local response_file="$2"
  local tier="$3"
  local error_key="$4"
  local override_model="${5:-}"

  if [ -z "$tier" ]; then
    tier="openrouter_paid"
  fi

  if [ -z "$case_file" ] || [ -z "$response_file" ]; then
    log "Missing arguments for openrouter call"
    return 1
  fi

  if [ ! -f "$case_file" ]; then
    log "Case file missing: $case_file"
    return 1
  fi

  if [ -z "${OPENROUTER_API_KEY:-}" ]; then
    log "OpenRouter API key unavailable"
    return 2
  fi

  # Read tier config line-by-line (portable: avoids mapfile)
  local tier_timeout tier_capacity tier_models_json
  {
    IFS= read -r tier_timeout || true
    IFS= read -r tier_capacity || true
    IFS= read -r tier_models_json || true
  } < <(get_tier_config "$tier" 2>/dev/null || printf '120\npaid\n[]\n')
  tier_timeout="${tier_timeout:-120}"
  tier_capacity="${tier_capacity:-paid}"
  tier_models_json="${tier_models_json:-[]}"
  local tier_models=()
  if [ -n "$tier_models_json" ]; then
    while IFS= read -r __m; do
      [ -n "$__m" ] && tier_models+=("$__m")
    done < <(python3 - "$tier_models_json" <<'PY'
import json
import sys
models = json.loads(sys.argv[1])
for model in models:
    print(model)
PY
) || true
  fi

  local selected_model="$override_model"
  if [ -z "$selected_model" ]; then
    if [ "$tier_capacity" = "free" ]; then
      selected_model="$(select_free_model || true)"
      if [ -z "$selected_model" ]; then
        log "OpenRouter free tier: no healthy model available"
        printf 'status=provider_unavailable\n'
        return 2
      fi
    else
      if [ -n "${OPENROUTER_MODEL:-}" ]; then
        selected_model="$OPENROUTER_MODEL"
      elif [ "${#tier_models[@]}" -gt 0 ]; then
        selected_model="${tier_models[0]}"
      else
        selected_model="openai/gpt-4-turbo"
      fi
    fi
  fi

  local payload
  payload="$(build_payload "$selected_model" "$case_file")"

  local timestamp
  timestamp="$(date -u +%Y%m%d-%H%M%S)"
  local request_log="${OPENROUTER_LOG_DIR}/request_${timestamp}.json"
  local response_log="${OPENROUTER_LOG_DIR}/response_${timestamp}.json"
  echo "$payload" > "$request_log"

  log "OpenRouter tier=$tier model=$selected_model error_key=$error_key request logged"

  local header_file
  header_file="$(mktemp)"
  local body_file
  body_file="$(mktemp)"

  set +e
  local http_code
  http_code="$(curl -s -D "$header_file" -o "$body_file" -w "%{http_code}" --max-time "$tier_timeout" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H "HTTP-Referer: https://github.com/funoffshore/homelab" \
    -H "X-Title: Funoffshore Orchestrator" \
    -X POST "$OPENROUTER_API_URL" \
    -d "$payload")"
  local curl_rc=$?
  set -e

  local raw_body
  raw_body="$(cat "$body_file")"
  echo "$raw_body" > "$response_log"
  log "OpenRouter response logged (http=$http_code rc=$curl_rc)"

  local rate_limit
  rate_limit="$(grep -i '^x-ratelimit-remaining:' "$header_file" 2>/dev/null | tail -n1 | cut -d':' -f2- | tr -d '[:space:]' || true)"

  rm -f "$header_file" "$body_file"

  if [ "$curl_rc" -ne 0 ] || [ "$http_code" != "200" ]; then
    log "OpenRouter request failed tier=$tier http=$http_code rc=$curl_rc"
    printf 'status=provider_unavailable\n'
    printf 'tier=%s\n' "$tier"
    printf 'model=%s\n' "$selected_model"
    printf 'http_code=%s\n' "$http_code"
    if [ -n "$rate_limit" ]; then
      printf 'rate_limit_remaining=%s\n' "$rate_limit"
    fi
    return 2
  fi

  local content
  content="$(python3 - "$raw_body" <<'PY'
import json
import sys

text = sys.argv[1] if len(sys.argv) > 1 else ''
if not text:
    sys.exit(1)

candidates = [text.strip()]
if '{' in text:
    idx = text.index('{')
    candidates.append(text[idx:])
if '[' in text:
    idx = text.index('[')
    candidates.append(text[idx:])

data = None
for candidate in candidates:
    if not candidate:
        continue
    try:
        data = json.loads(candidate)
        break
    except json.JSONDecodeError:
        continue

if data is None:
    sys.exit(1)

choices = data.get('choices', [])
if choices:
    message = choices[0].get('message', {})
    content = message.get('content', '')
    if content:
        print(content)
        sys.exit(0)
sys.exit(1)
PY
)"

  if [ -z "$content" ]; then
    log "OpenRouter response parsing failed"
    printf 'status=provider_unavailable\n'
    printf 'tier=%s\n' "$tier"
    printf 'model=%s\n' "$selected_model"
    printf 'http_code=%s\n' "$http_code"
    if [ -n "$rate_limit" ]; then
      printf 'rate_limit_remaining=%s\n' "$rate_limit"
    fi
    return 2
  fi

  printf '%s\n' "$content" > "$response_file"
  log "OpenRouter response content written to $response_file"

  printf 'status=ok\n'
  printf 'tier=%s\n' "$tier"
  printf 'model=%s\n' "$selected_model"
  printf 'http_code=%s\n' "$http_code"
  if [ -n "$rate_limit" ]; then
    printf 'rate_limit_remaining=%s\n' "$rate_limit"
  fi
  return 0
}

usage() {
  cat <<'HELP'
Usage: $0 call <case_file> <response_file> <tier> <error_key> [model_override]
HELP
  exit 1
}

case "${1:-}" in
  call)
    if [ "$#" -lt 5 ]; then
      usage
    fi
    call_openrouter "$2" "$3" "$4" "$5" "${6:-}"
    ;;
  *)
    usage
    ;;
esac
