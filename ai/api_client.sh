#!/usr/bin/env bash
# Orchestrator v2 - API Client
#
# Sends case file payloads to the OpenAI API and handles responses.
# The API may return:
#   - A patch (diff to apply)
#   - A diagnostics request (commands to run for more info)
#
# Usage: ./ai/api_client.sh <case_file> <patch_output> <response_output>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# =============================================================================
# Configuration
# =============================================================================
: "${OPENAI_API_KEY:=}"
: "${OPENAI_MODEL:=gpt-4-turbo-preview}"
: "${OPENAI_API_URL:=https://api.openai.com/v1/chat/completions}"
: "${API_TIMEOUT:=120}"
: "${LOG_DIR:=ai/logs}"

# =============================================================================
# Helpers
# =============================================================================
log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[api-client] [%s] %s\n' "$ts" "$*" >&2
}

ensure_directories() {
  mkdir -p "$LOG_DIR/api"
}

# =============================================================================
# API Call
# =============================================================================
call_openai_api() {
  local case_file="$1"
  local response_file="$2"

  if [ -z "$OPENAI_API_KEY" ]; then
    log "ERROR: OPENAI_API_KEY environment variable not set"
    return 1
  fi

  if [ ! -f "$case_file" ]; then
    log "ERROR: Case file not found: $case_file"
    return 1
  fi

  local case_content
  case_content="$(cat "$case_file")"

  # Escape the content for JSON
  local escaped_content
  escaped_content="$(printf '%s' "$case_content" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')"

  # Build the request payload
  local payload
  payload="$(cat <<EOF
{
  "model": "$OPENAI_MODEL",
  "messages": [
    {
      "role": "system",
      "content": "You are a senior infrastructure engineer helping to fix issues in a Talos Kubernetes homelab. You analyze case files and provide either patches (unified diffs) or request additional diagnostics. Always respond with valid JSON followed by any patches in diff format."
    },
    {
      "role": "user",
      "content": $escaped_content
    }
  ],
  "max_tokens": 4096,
  "temperature": 0.3
}
EOF
)"

  local timestamp
  timestamp="$(date -u +%Y%m%d-%H%M%S)"
  local request_log="${LOG_DIR}/api/request_${timestamp}.json"
  local response_log="${LOG_DIR}/api/response_${timestamp}.json"

  # Save request for debugging
  echo "$payload" > "$request_log"
  log "Request saved to: $request_log"

  # Make the API call
  log "Calling OpenAI API..."

  set +e
  local http_response
  http_response="$(curl -s -w "\n%{http_code}" \
    --max-time "$API_TIMEOUT" \
    -X POST "$OPENAI_API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -d "$payload")"
  local curl_rc=$?
  set -e

  if [ "$curl_rc" -ne 0 ]; then
    log "ERROR: curl failed with exit code $curl_rc"
    return 1
  fi

  # Extract HTTP status code (last line)
  local http_code
  http_code="$(echo "$http_response" | tail -n1)"
  local body
  body="$(echo "$http_response" | sed '$d')"

  # Save response for debugging
  echo "$body" > "$response_log"
  log "Response saved to: $response_log"

  if [ "$http_code" != "200" ]; then
    log "ERROR: API returned HTTP $http_code"
    log "Response: $body"
    return 1
  fi

  # Extract the assistant's message content
  local content
  content="$(echo "$body" | python3 -c "
import sys
import json

try:
    data = json.load(sys.stdin)
    choices = data.get('choices', [])
    if choices:
        message = choices[0].get('message', {})
        print(message.get('content', ''))
except Exception as e:
    print(f'Error parsing response: {e}', file=sys.stderr)
" 2>/dev/null)"

  if [ -z "$content" ]; then
    log "ERROR: Could not extract content from API response"
    return 1
  fi

  echo "$content" > "$response_file"
  log "API response content saved to: $response_file"
  return 0
}

# =============================================================================
# Response Parsing
# =============================================================================
parse_api_response() {
  local response_file="$1"
  local patch_output="$2"
  local parsed_output="$3"

  if [ ! -f "$response_file" ]; then
    log "ERROR: Response file not found: $response_file"
    return 1
  fi

  local content
  content="$(cat "$response_file")"

  # Parse the response using Python
  python3 - "$response_file" "$patch_output" "$parsed_output" <<'PY'
import sys
import json
import re

response_file, patch_output, parsed_output = sys.argv[1:4]

with open(response_file, 'r') as f:
    content = f.read()

# Try to find JSON block
json_match = re.search(r'```json\s*(.*?)\s*```', content, re.DOTALL)
if not json_match:
    # Try to find raw JSON
    json_match = re.search(r'(\{[^{}]*"type"[^{}]*\})', content, re.DOTALL)

response_data = {"type": "unknown"}

if json_match:
    try:
        response_data = json.loads(json_match.group(1))
    except json.JSONDecodeError:
        pass

# Save parsed response
with open(parsed_output, 'w') as f:
    json.dump(response_data, f, indent=2)

# If it's a patch response, extract the diff
if response_data.get("type") == "patch":
    # Look for diff block
    diff_match = re.search(r'```diff\s*(.*?)\s*```', content, re.DOTALL)
    if diff_match:
        with open(patch_output, 'w') as f:
            f.write(diff_match.group(1))
        print("patch")
        sys.exit(0)

    # Look for raw unified diff
    diff_pattern = r'(---\s+\S+.*?\n\+\+\+\s+\S+.*?\n(?:@@.*?\n(?:[-+ ].*?\n)*)+)'
    diff_match = re.search(diff_pattern, content, re.MULTILINE | re.DOTALL)
    if diff_match:
        with open(patch_output, 'w') as f:
            f.write(diff_match.group(1))
        print("patch")
        sys.exit(0)

    print("patch_no_diff")
    sys.exit(0)

elif response_data.get("type") == "diagnostics":
    print("diagnostics")
    sys.exit(0)

print("unknown")
sys.exit(0)
PY
}

# =============================================================================
# Main
# =============================================================================
main() {
  if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <case_file> <patch_output> <response_output>"
    echo ""
    echo "Sends a case file to the OpenAI API and parses the response."
    echo ""
    echo "Arguments:"
    echo "  case_file      - Path to the case file to send"
    echo "  patch_output   - Where to write any patch returned"
    echo "  response_output - Where to write the parsed response JSON"
    echo ""
    echo "Environment:"
    echo "  OPENAI_API_KEY - Required. Your OpenAI API key."
    echo "  OPENAI_MODEL   - Optional. Model to use (default: gpt-4-turbo-preview)"
    exit 1
  fi

  local case_file="$1"
  local patch_output="$2"
  local response_output="$3"

  ensure_directories

  # Temporary file for raw API response
  local raw_response
  raw_response="$(mktemp)"
  trap "rm -f '$raw_response'" EXIT

  # Call the API
  if ! call_openai_api "$case_file" "$raw_response"; then
    log "API call failed"
    # Write error response
    echo '{"type": "error", "error": "API call failed"}' > "$response_output"
    return 1
  fi

  # Parse the response
  local response_type
  response_type="$(parse_api_response "$raw_response" "$patch_output" "$response_output")"

  log "Response type: $response_type"

  case "$response_type" in
    patch)
      if [ -f "$patch_output" ] && [ -s "$patch_output" ]; then
        log "Patch extracted successfully"
        return 0
      else
        log "Patch response but no diff extracted"
        return 1
      fi
      ;;
    diagnostics)
      log "Diagnostics request received"
      return 0
      ;;
    *)
      log "Unknown or error response type: $response_type"
      return 1
      ;;
  esac
}

main "$@"
