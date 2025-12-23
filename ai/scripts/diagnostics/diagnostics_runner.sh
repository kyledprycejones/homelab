#!/usr/bin/env bash
# Orchestrator v5 - Diagnostics Runner
#
# Executes diagnostic commands requested by the API and saves their output.
# These diagnostics are used to build Case File v2 for follow-up API calls.
#
# v5 Requirements:
#   - CRITICAL: All command output MUST be passed through redact_secrets()
#   - Blocked commands list is enforced before execution
#   - Output is normalized before being included in case files
#
# See docs/orchestrator_v5.txt for the authoritative specification.
#
# Usage: ./ai/scripts/diagnostics/diagnostics_runner.sh <response_file> <output_dir>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "$REPO_ROOT"

# =============================================================================
# Configuration
# =============================================================================
: "${COMMAND_TIMEOUT:=60}"
: "${LOG_DIR:=logs}"

# Commands that are NOT allowed (safety)
BLOCKED_COMMANDS=(
  "rm -rf"
  "mkfs"
  "dd if="
  "shutdown"
  "reboot"
  "init 0"
  "init 6"
  "halt"
  "poweroff"
  "> /dev"
  "wipe"
)

# =============================================================================
# Helpers
# =============================================================================
log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[diagnostics] [%s] %s\n' "$ts" "$*" >&2
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
  '
}

# =============================================================================
# Safety Checks
# =============================================================================
is_command_safe() {
  local cmd="$1"
  local lower_cmd
  lower_cmd="$(echo "$cmd" | tr '[:upper:]' '[:lower:]')"

  for blocked in "${BLOCKED_COMMANDS[@]}"; do
    if [[ "$lower_cmd" == *"$blocked"* ]]; then
      return 1
    fi
  done

  return 0
}

# =============================================================================
# Command Execution
# =============================================================================
run_diagnostic_command() {
  local cmd="$1"
  local output_file="$2"

  log "Running: $cmd"

  # Safety check
  if ! is_command_safe "$cmd"; then
    log "BLOCKED: Command contains unsafe pattern: $cmd"
    echo "BLOCKED: Command contains unsafe pattern" > "$output_file"
    return 1
  fi

  # Run the command with timeout
  # v5 CRITICAL: All output is passed through redact_secrets
  {
    echo "# Command: $cmd"
    echo "# Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "## Output"
    echo ""

    set +e
    timeout "$COMMAND_TIMEOUT" bash -c "$cmd" 2>&1 | redact_secrets
    local rc=${PIPESTATUS[0]}
    set -e

    echo ""
    echo "## Exit Code: $rc"
  } > "$output_file"

  return 0
}

# =============================================================================
# Parse Diagnostics Request
# =============================================================================
extract_commands() {
  local response_file="$1"

  if [ ! -f "$response_file" ]; then
    log "ERROR: Response file not found: $response_file"
    return
  fi

  python3 - "$response_file" <<'PY'
import sys
import json
import re

response_file = sys.argv[1]

# Try to read as JSON first
try:
    with open(response_file, 'r') as f:
        data = json.load(f)

    if isinstance(data, dict):
        commands = data.get('commands', [])
        if commands:
            for cmd in commands:
                print(cmd)
            sys.exit(0)
except json.JSONDecodeError:
    pass

# Try to parse from text content
try:
    with open(response_file, 'r') as f:
        content = f.read()

    # Look for JSON block
    json_match = re.search(r'```json\s*(.*?)\s*```', content, re.DOTALL)
    if json_match:
        data = json.loads(json_match.group(1))
        commands = data.get('commands', [])
        for cmd in commands:
            print(cmd)
        sys.exit(0)

    # Look for commands array in raw text
    commands_match = re.search(r'"commands"\s*:\s*\[(.*?)\]', content, re.DOTALL)
    if commands_match:
        # Extract quoted strings
        cmd_strings = re.findall(r'"([^"]+)"', commands_match.group(1))
        for cmd in cmd_strings:
            print(cmd)
        sys.exit(0)

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)

sys.exit(1)
PY
}

# =============================================================================
# Main
# =============================================================================
main() {
  if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <response_file> <output_dir>"
    echo ""
    echo "Executes diagnostic commands from an API response."
    echo ""
    echo "Arguments:"
    echo "  response_file - Path to the API response JSON containing commands"
    echo "  output_dir    - Directory to save diagnostic outputs"
    exit 1
  fi

  local response_file="$1"
  local output_dir="$2"

  log "=== Diagnostics Runner ==="
  log "Response file: $response_file"
  log "Output dir: $output_dir"

  mkdir -p "$output_dir"

  # Extract commands from response
  local commands=()
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    commands+=("$cmd")
  done < <(extract_commands "$response_file")

  if [ "${#commands[@]}" -eq 0 ]; then
    log "No diagnostic commands found in response"
    return 1
  fi

  log "Found ${#commands[@]} diagnostic command(s)"

  # Run each command
  local index=0
  for cmd in "${commands[@]}"; do
    index=$((index + 1))
    local safe_name
    # Create a safe filename from the command
    safe_name="$(echo "$cmd" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-50)"
    local output_file="${output_dir}/diag_${index}_${safe_name}.txt"

    run_diagnostic_command "$cmd" "$output_file"
  done

  # Create a summary file
  {
    echo "# Diagnostics Summary"
    echo ""
    echo "- Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- Commands executed: ${#commands[@]}"
    echo ""
    echo "## Commands"
    echo ""
    for cmd in "${commands[@]}"; do
      echo "- \`$cmd\`"
    done
    echo ""
    echo "## Output Files"
    echo ""
    for f in "$output_dir"/diag_*.txt; do
      [ -f "$f" ] || continue
      echo "- $(basename "$f")"
    done
  } > "${output_dir}/summary.md"

  log "Diagnostics complete. Summary: ${output_dir}/summary.md"
  return 0
}

main "$@"
