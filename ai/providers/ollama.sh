#!/usr/bin/env bash
# Ollama Provider Client
#
# v7 directive: Ollama is the only local execution backend for executor-tier work.
# v6 contract: JSON-only stdout for machine parsing; logs go to files/stderr.
#
# Usage:
#   ./ai/providers/ollama.sh call <context_file> <output_file> <model> <error_key>
#   ./ai/providers/ollama.sh health
#   ./ai/providers/ollama.sh list-models
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$REPO_ROOT"

: "${OLLAMA_ENDPOINT:=http://localhost:11434}"
: "${OLLAMA_LOG_DIR:=logs/provider/ollama}"
: "${OLLAMA_TIMEOUT:=120}"
: "${OLLAMA_PRIMARY_MODEL:=qwen-2.5:7b-coder}"
: "${OLLAMA_FALLBACK_MODEL:=qwen-2.5:7b-coder}"

mkdir -p "$OLLAMA_LOG_DIR"
LOG_FILE="${OLLAMA_LOG_DIR}/ollama.log"

log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[%s] %s\n' "$ts" "$*" >> "$LOG_FILE"
}

# Check if Ollama is reachable and has models loaded
health_check() {
  local endpoint="${OLLAMA_ENDPOINT%/}"
  
  set +e
  local resp
  resp="$(curl -s --max-time 5 "${endpoint}/api/tags" 2>/dev/null)"
  local rc=$?
  set -e
  
  if [ "$rc" -ne 0 ] || [ -z "$resp" ]; then
    log "Health check failed: Ollama endpoint unreachable at $endpoint"
    printf '{"status":"unhealthy","reason":"endpoint_unreachable","endpoint":"%s"}\n' "$endpoint"
    return 1
  fi
  
  # Parse response to check for models
  local model_count
  model_count="$(python3 - "$resp" <<'PY' 2>/dev/null || echo "0"
import json
import sys
try:
    data = json.loads(sys.argv[1])
    models = data.get('models', [])
    print(len(models))
except Exception:
    print(0)
PY
)"
  
  if [ "$model_count" -eq 0 ]; then
    log "Health check warning: No models loaded in Ollama"
    printf '{"status":"degraded","reason":"no_models_loaded","endpoint":"%s"}\n' "$endpoint"
    return 0
  fi
  
  log "Health check passed: $model_count models available"
  printf '{"status":"healthy","models_available":%d,"endpoint":"%s"}\n' "$model_count" "$endpoint"
  return 0
}

# List available models
list_models() {
  local endpoint="${OLLAMA_ENDPOINT%/}"
  
  set +e
  local resp
  resp="$(curl -s --max-time 10 "${endpoint}/api/tags" 2>/dev/null)"
  local rc=$?
  set -e
  
  if [ "$rc" -ne 0 ] || [ -z "$resp" ]; then
    log "List models failed: endpoint unreachable"
    printf '{"error":"endpoint_unreachable"}\n'
    return 1
  fi
  
  # Output JSON-only list of model names
  python3 - "$resp" <<'PY'
import json
import sys
try:
    data = json.loads(sys.argv[1])
    models = data.get('models', [])
    names = [m.get('name', '') for m in models if m.get('name')]
    print(json.dumps({"models": names}))
except Exception as e:
    print(json.dumps({"error": str(e)}))
PY
}

# v7 readiness check: Verify model exists and is pulled
# Returns 0 if model exists, 1 if not found, 2 if endpoint unreachable
check_model_exists() {
  local model="$1"
  local endpoint="${OLLAMA_ENDPOINT%/}"

  if [ -z "$model" ]; then
    log "Model check: no model specified"
    return 1
  fi

  set +e
  local resp
  resp="$(curl -s --max-time 5 "${endpoint}/api/tags" 2>/dev/null)"
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ] || [ -z "$resp" ]; then
    log "Model check: endpoint unreachable"
    return 2
  fi

  local exists
  exists="$(python3 - "$resp" "$model" <<'PY'
import json
import sys
try:
    data = json.loads(sys.argv[1])
    target = sys.argv[2]
    models = data.get('models', [])
    available = {m.get('name', ''): m for m in models if m.get('name')}
    if target in available:
        print("yes")
    else:
        print("no")
except Exception:
    print("error")
PY
)"

  if [ "$exists" = "yes" ]; then
    log "Model check: $model exists"
    return 0
  elif [ "$exists" = "no" ]; then
    log "Model check: $model NOT FOUND in Ollama"
    return 1
  else
    log "Model check: parse error"
    return 2
  fi
}

# Select best available model based on capability
select_model() {
  local capability="${1:-code}"
  local endpoint="${OLLAMA_ENDPOINT%/}"

  set +e
  local resp
  resp="$(curl -s --max-time 5 "${endpoint}/api/tags" 2>/dev/null)"
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ] || [ -z "$resp" ]; then
    log "Model selection failed: endpoint unreachable"
    return 1
  fi
  
  # Select model based on capability and availability
  local selected
  selected="$(python3 - "$resp" "$capability" "$OLLAMA_PRIMARY_MODEL" "$OLLAMA_FALLBACK_MODEL" <<'PY'
import json
import sys

try:
    data = json.loads(sys.argv[1])
    capability = sys.argv[2]
    primary = sys.argv[3]
    fallback = sys.argv[4]
    
    models = data.get('models', [])
    available = {m.get('name', ''): m for m in models if m.get('name')}
    
    # Capability-based preference
    if capability == "code":
        # Prefer coder models
        preferred = [primary, fallback]
    elif capability == "reasoning":
        # Prefer instruct/reasoning models
        preferred = [fallback, primary]
    else:
        preferred = [primary, fallback]
    
    # Return first available preferred model
    for model in preferred:
        if model in available:
            print(model)
            sys.exit(0)
    
    # Fallback: return any available model
    if available:
        print(next(iter(available.keys())))
        sys.exit(0)
    
    sys.exit(1)
except Exception:
    sys.exit(1)
PY
)"
  
  if [ -z "$selected" ]; then
    log "Model selection failed: no suitable model found"
    return 1
  fi
  
  printf '%s' "$selected"
}

# Build the Ollama API payload
build_payload() {
  local model="$1"
  local context_file="$2"
  
  python3 - "$model" "$context_file" <<'PY'
import json
import sys

model = sys.argv[1]
context_path = sys.argv[2]

with open(context_path) as fh:
    context_content = fh.read()

# System prompt for planner tasks - JSON-only output
system_prompt = """You are the planner persona for an Ubuntu Server + k3s homelab running on Proxmox.

CRITICAL: You MUST respond with EXACTLY ONE JSON object describing backlog tasks to execute (reconcile, delete/reset, apply, validate). No prose, no markdown fences, no explanation before or after.

The JSON must follow this schema:
{
  "tasks": [
    {
      "id": "S1-RECOVER-001",
      "persona": "executor",
      "summary": "One-line task summary",
      "detail": "Detailed instructions for the executor script",
      "target": "path/to/script.sh",
      "depends_on": ["PARENT_TASK_ID"],
      "stage": 1
    }
  ]
}

If no new tasks are required, respond with:
{"tasks": []}

Do NOT include any text outside the JSON object."""

payload = {
    "model": model,
    "messages": [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": context_content}
    ],
    "stream": False,
    "options": {
        "temperature": 0.3,
        "num_predict": 4096
    }
}

print(json.dumps(payload))
PY
}

# Extract JSON from response (handle potential markdown fencing)
# v7 contract: MUST return exactly one valid JSON object or canonical error
extract_json_from_response() {
  local content="$1"
  local provider="${2:-ollama}"

  python3 - "$content" "$provider" <<'PY'
import json
import re
import sys

content = sys.argv[1]
provider = sys.argv[2] if len(sys.argv) > 2 else "ollama"

def make_error(reason, details=None):
    """Create canonical error object."""
    err = {"type": "error", "reason": reason, "provider": provider}
    if details:
        err["details"] = details[:200]  # Truncate for safety
    return err

# Check for empty/whitespace-only content
if not content or not content.strip():
    print(json.dumps(make_error("empty_response")))
    sys.exit(1)

# Check for binary/garbage data (non-printable characters)
printable_ratio = sum(1 for c in content[:500] if c.isprintable() or c in '\n\r\t') / min(len(content), 500)
if printable_ratio < 0.8:
    print(json.dumps(make_error("binary_or_garbage_output", f"printable_ratio={printable_ratio:.2f}")))
    sys.exit(1)

# Try to parse as-is first
try:
    data = json.loads(content)
    if isinstance(data, dict):
        print(json.dumps(data))
        sys.exit(0)
    else:
        print(json.dumps(make_error("invalid_json_type", f"expected dict, got {type(data).__name__}")))
        sys.exit(1)
except json.JSONDecodeError:
    pass

# Try to extract from markdown code fence
patterns = [
    r'```json\s*\n(.*?)\n```',
    r'```\s*\n(.*?)\n```',
]

for pattern in patterns:
    match = re.search(pattern, content, re.DOTALL)
    if match:
        try:
            candidate = match.group(1)
            data = json.loads(candidate)
            if isinstance(data, dict):
                print(json.dumps(data))
                sys.exit(0)
        except (json.JSONDecodeError, IndexError):
            continue

# Try to find a JSON object with required keys
json_pattern = r'\{[^{}]*"type"\s*:\s*"[^"]+?"[^{}]*\}'
json_match = re.search(json_pattern, content, re.DOTALL)
if json_match:
    try:
        data = json.loads(json_match.group(0))
        if isinstance(data, dict):
            print(json.dumps(data))
            sys.exit(0)
    except json.JSONDecodeError:
        pass

# Last resort: find any JSON object (greedy)
json_match = re.search(r'\{.*\}', content, re.DOTALL)
if json_match:
    try:
        data = json.loads(json_match.group(0))
        if isinstance(data, dict):
            print(json.dumps(data))
            sys.exit(0)
    except json.JSONDecodeError:
        pass

# Failed to extract JSON - return canonical error
print(json.dumps(make_error("failed_to_extract_json", content[:200])))
sys.exit(1)
PY
}

# Main call function - invoke Ollama for executor tasks
call_ollama() {
  local context_file="$1"
  local output_file="$2"
  local model="${3:-}"
  local error_key="${4:-unknown}"
  
  if [ -z "$context_file" ] || [ -z "$output_file" ]; then
    log "Missing arguments for ollama call"
    printf '{"status":"error","reason":"missing_arguments"}\n'
    return 1
  fi
  
  if [ ! -f "$context_file" ]; then
    log "Context file missing: $context_file"
    printf '{"status":"error","reason":"context_file_missing"}\n'
    return 1
  fi
  
  local endpoint="${OLLAMA_ENDPOINT%/}"

  # Select model if not specified
  if [ -z "$model" ]; then
    model="$(select_model "code" 2>/dev/null || echo "$OLLAMA_PRIMARY_MODEL")"
  fi

  log "Ollama call: model=$model error_key=$error_key"

  # v7 readiness check: Verify model exists before attempting call
  set +e
  check_model_exists "$model"
  local model_check_rc=$?
  set -e

  if [ "$model_check_rc" -eq 2 ]; then
    log "Ollama endpoint unreachable - provider unavailable"
    printf '{"status":"provider_unavailable","reason":"endpoint_unreachable","model":"%s"}\n' "$model"
    return 2
  elif [ "$model_check_rc" -eq 1 ]; then
    log "Model $model not found in Ollama - provider misconfigured"
    printf '{"status":"provider_misconfigured","reason":"model_not_found","model":"%s"}\n' "$model"
    return 2
  fi
  
  # Build payload
  local payload
  payload="$(build_payload "$model" "$context_file")"
  
  # Log request
  local timestamp
  timestamp="$(date -u +%Y%m%d-%H%M%S)"
  local request_log="${OLLAMA_LOG_DIR}/request_${timestamp}.json"
  local response_log="${OLLAMA_LOG_DIR}/response_${timestamp}.json"
  echo "$payload" > "$request_log"
  
  # Make API call
  set +e
  local raw_response
  raw_response="$(curl -s --max-time "$OLLAMA_TIMEOUT" \
    -H "Content-Type: application/json" \
    -X POST "${endpoint}/api/chat" \
    -d "$payload" 2>/dev/null)"
  local curl_rc=$?
  set -e
  
  echo "$raw_response" > "$response_log"
  log "Ollama response logged (rc=$curl_rc)"
  
  if [ "$curl_rc" -ne 0 ] || [ -z "$raw_response" ]; then
    log "Ollama request failed: rc=$curl_rc"
    printf '{"status":"provider_unavailable","reason":"request_failed","model":"%s"}\n' "$model"
    return 2
  fi
  
  # Extract content from response
  local content
  content="$(python3 - "$raw_response" <<'PY' 2>/dev/null || echo ""
import json
import sys
try:
    data = json.loads(sys.argv[1])
    message = data.get('message', {})
    print(message.get('content', ''))
except Exception:
    pass
PY
)"
  
  if [ -z "$content" ]; then
    log "Ollama response parsing failed"
    printf '{"status":"provider_unavailable","reason":"parse_failed","model":"%s"}\n' "$model"
    return 2
  fi
  
  # Extract and validate JSON from content
  local extracted_json
  set +e
  extracted_json="$(extract_json_from_response "$content" "ollama")"
  local extract_rc=$?
  set -e

  # If extraction failed, create canonical error
  if [ "$extract_rc" -ne 0 ] || [ -z "$extracted_json" ]; then
    extracted_json='{"type":"error","reason":"extraction_failed","provider":"ollama"}'
    log "JSON extraction failed, using canonical error"
  fi

  # Validate that we have exactly one JSON object (no multi-line)
  local line_count
  line_count="$(printf '%s' "$extracted_json" | wc -l)"
  if [ "$line_count" -gt 1 ]; then
    # Multi-line output detected - take first line if valid JSON, else error
    local first_line
    first_line="$(printf '%s' "$extracted_json" | head -1)"
    if python3 -c "import json; json.loads('$first_line')" 2>/dev/null; then
      extracted_json="$first_line"
      log "Multi-line output detected, using first valid JSON line"
    else
      extracted_json='{"type":"error","reason":"multiline_invalid_json","provider":"ollama"}'
      log "Multi-line output with invalid JSON, using canonical error"
    fi
  fi

  # Atomic write: write to temp file, validate, then move
  local temp_file="${output_file}.tmp.$$"
  printf '%s\n' "$extracted_json" > "$temp_file"

  # Validate temp file contains valid JSON
  if ! python3 -c "import json; json.load(open('$temp_file'))" 2>/dev/null; then
    log "CRITICAL: Temp file contains invalid JSON, this should never happen"
    printf '{"type":"error","reason":"internal_validation_failed","provider":"ollama"}\n' > "$temp_file"
  fi

  # Atomic move into place
  mv "$temp_file" "$output_file"
  log "Ollama output written atomically to $output_file"

  # Check if the extracted JSON is an error type
  local output_type
  output_type="$(python3 -c "import json; print(json.load(open('$output_file')).get('type',''))" 2>/dev/null || echo "")"

  if [ "$output_type" = "error" ]; then
    log "Provider returned error-type response"
    printf '{"status":"provider_error","model":"%s","output_file":"%s","output_type":"error"}\n' "$model" "$output_file"
    return 2
  fi

  # Output status to stdout (for router/orchestrator consumption)
  printf '{"status":"ok","model":"%s","output_file":"%s"}\n' "$model" "$output_file"
  return 0
}

usage() {
  cat <<'HELP'
Ollama Provider Client (v7)

Usage:
  ollama.sh call <context_file> <output_file> [model] [error_key]
      Call Ollama to generate a patch for the given context.
      Output is JSON-only to stdout; logs go to files.

  ollama.sh health
      Check Ollama endpoint health. Returns JSON status.

  ollama.sh check-model <model>
      Check if a specific model exists in Ollama.
      Returns 0 if found, 1 if not found, 2 if endpoint unreachable.

  ollama.sh list-models
      List available models. Returns JSON array.

  ollama.sh select-model [capability]
      Select best model for capability (code|reasoning).
      Returns model name.

Environment:
  OLLAMA_ENDPOINT       Ollama API endpoint (default: http://localhost:11434)
  OLLAMA_TIMEOUT        Request timeout in seconds (default: 120)
  OLLAMA_PRIMARY_MODEL  Primary model for code tasks (default: qwen-2.5:7b-coder)
  OLLAMA_FALLBACK_MODEL Fallback model (default: qwen-2.5:7b-coder)

Models (locked):
  - qwen-2.5:7b-coder       Primary model (executor)
  - qwen2.5:7b-instruct     Architect model (planner reasoning)

Verify models exist: ollama list
HELP
  exit 1
}

case "${1:-}" in
  call)
    if [ "$#" -lt 3 ]; then
      usage
    fi
    call_ollama "$2" "$3" "${4:-}" "${5:-unknown}"
    ;;
  health)
    health_check
    ;;
  check-model)
    if [ -z "${2:-}" ]; then
      echo "Usage: $0 check-model <model>" >&2
      exit 1
    fi
    check_model_exists "$2"
    ;;
  list-models)
    list_models
    ;;
  select-model)
    select_model "${2:-code}"
    ;;
  *)
    usage
    ;;
esac
