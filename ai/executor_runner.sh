#!/usr/bin/env bash
# Orchestrator v2 - Executor Runner
#
# This script is the interface between the bootstrap_loop (plumbing) and the
# Executor (Codex/local LLM). It:
#   - Parses logs to understand the error
#   - Selects relevant files via context_map.yaml
#   - Invokes Codex CLI to attempt a local fix
#   - Applies any patches produced
#
# The Executor handles "new" errors - those seen fewer than N times.
#
# Usage: ./ai/executor_runner.sh <stage> <log_file> <error_hash>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# =============================================================================
# Configuration
# =============================================================================
: "${CONTEXT_MAP:=ai/context_map.yaml}"
: "${EXECUTOR_INSTRUCTIONS:=ai/executor_instructions.md}"
: "${MASTER_MEMO:=docs/master_memo.txt}"
: "${BACKLOG:=ai/backlog.md}"
: "${ISSUES:=ai/issues.txt}"
: "${LOG_DIR:=logs}"
: "${PATCHES_DIR:=ai/patches}"
: "${AI_BRANCH:=ai/orchestrator-stage1}"
: "${EXECUTOR_OLLAMA_CMD:=ai/providers/ollama.sh}"

# Codex CLI configuration
: "${CODEX_CLI:=codex}"
: "${CODEX_MODEL:=}"
: "${CODEX_INVALID_MODEL:=cursor}"
: "${CODEX_TIMEOUT:=120}"

# =============================================================================
# Helpers
# =============================================================================
log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[executor] [%s] %s\n' "$ts" "$*"
}

timeout_cmd() {
  local duration="$1"
  shift
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$duration" "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$duration" "$@"
  else
    "$@"
  fi
}

ensure_directories() {
  mkdir -p "$PATCHES_DIR" "$LOG_DIR/executor"
}

write_summary() {
  local summary_file="$1"
  local status="$2"
  local provider="$3"
  local model="$4"
  local rc="$5"
  local log_path="$6"
  shift 6
  if [ -z "$summary_file" ]; then
    return
  fi
  {
    echo "status=$status"
    echo "provider=$provider"
    if [ -n "$model" ]; then
      echo "provider_model=$model"
    fi
    echo "provider_rc=$rc"
    if [ -n "$log_path" ]; then
      echo "provider_log=$log_path"
    fi
    printf '%s\n' "$@"
  } > "$summary_file"
}

# =============================================================================
# Context Extraction
# =============================================================================

# Generic YAML field extractor with fallback for missing PyYAML
_get_yaml_list() {
  local yaml_file="$1"
  local stage="$2"
  local field="$3"

  python3 - "$yaml_file" "$stage" "$field" <<'PY' 2>/dev/null || _get_yaml_list_fallback "$yaml_file" "$stage" "$field"
import sys
import re

path, stage, field = sys.argv[1:4]
try:
    # Try yaml first
    try:
        import yaml
        with open(path, 'r') as f:
            data = yaml.safe_load(f)
        stages = data.get('stages', {})
        if stage in stages:
            items = stages[stage].get(field, [])
            if isinstance(items, list):
                for item in items:
                    print(item)
            elif items:
                print(items)
    except ImportError:
        # Regex-based fallback
        with open(path, 'r') as f:
            content = f.read()

        # Find stage section
        stage_pattern = rf'^\s*{re.escape(stage)}:\s*$'
        stage_match = re.search(stage_pattern, content, re.MULTILINE)
        if not stage_match:
            sys.exit(0)

        stage_start = stage_match.end()
        next_section = re.search(r'^  \w+:\s*$', content[stage_start:], re.MULTILINE)
        if next_section:
            stage_content = content[stage_start:stage_start + next_section.start()]
        else:
            stage_content = content[stage_start:]

        # Find field and extract list items
        field_pattern = rf'^\s*{re.escape(field)}:\s*$'
        field_match = re.search(field_pattern, stage_content, re.MULTILINE)
        if field_match:
            field_start = field_match.end()
            for m in re.finditer(r'^\s*-\s*(.+)$', stage_content[field_start:], re.MULTILINE):
                # Stop at next field
                check_area = stage_content[field_start:field_start + m.start()]
                if re.search(r'^\s*\w+:', check_area, re.MULTILINE):
                    break
                print(m.group(1).strip())
except Exception:
    pass
PY
}

# Pure bash/awk fallback for YAML parsing
_get_yaml_list_fallback() {
  local yaml_file="$1"
  local stage="$2"
  local field="$3"

  awk -v stage="$stage" -v field="$field" '
    BEGIN { in_stage=0; in_field=0 }
    /^  [a-z]+:/ {
      if ($0 ~ "^  " stage ":") { in_stage=1 } else { in_stage=0 }
      in_field=0
      next
    }
    in_stage && $0 ~ "^    " field ":" {
      in_field=1
      next
    }
    in_stage && in_field && /^      - / {
      sub("^      - *", "")
      print
    }
    in_stage && in_field && /^    [a-z]/ { in_field=0 }
  ' "$yaml_file" 2>/dev/null
}

get_stage_files() {
  local stage="$1"
  if [ ! -f "$CONTEXT_MAP" ]; then
    log "WARN: Context map not found: $CONTEXT_MAP"
    return
  fi
  _get_yaml_list "$CONTEXT_MAP" "$stage" "files"
}

get_architecture_sections() {
  local stage="$1"
  if [ ! -f "$CONTEXT_MAP" ]; then
    return
  fi
  _get_yaml_list "$CONTEXT_MAP" "$stage" "architecture_sections"
}

extract_log_tail() {
  local log_file="$1"
  local lines="${2:-100}"

  if [ ! -f "$log_file" ]; then
    echo "# Log file not found: $log_file"
    return
  fi

  tail -n "$lines" "$log_file"
}

# =============================================================================
# File Content Assembly
# =============================================================================
read_file_if_exists() {
  local file="$1"
  if [ -f "$file" ]; then
    echo "=== FILE: $file ==="
    cat "$file"
    echo ""
    echo "=== END: $file ==="
    echo ""
  fi
}

# Normalized path helpers ensure diff validation works even for non-existent files.
normalize_repo_path() {
  local path="$1"
  if [ -z "$path" ]; then
    echo ""
    return
  fi
  python3 - "$path" <<'PY'
import os, sys
raw = sys.argv[1]
repo = os.getcwd()
try:
    normalized = os.path.normpath(os.path.relpath(raw, repo))
except Exception:
    normalized = raw
print(normalized)
PY
}

declare -a ALLOWED_PATHS
declare -a ALLOWED_PREFIXES

collect_stage_allowed_paths() {
  local stage="$1"
  ALLOWED_PATHS=()
  ALLOWED_PREFIXES=()
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    local normalized="$entry"
    local is_dir=false
    if [[ "$entry" == */ ]]; then
      normalized="${entry%/}"
      is_dir=true
    fi
    normalized="$(normalize_repo_path "$normalized")"
    [ -z "$normalized" ] && continue
    if [[ "$normalized" == ".."* ]]; then
      continue
    fi
    if [ "$is_dir" = true ]; then
      ALLOWED_PREFIXES+=("${normalized}/")
    else
      ALLOWED_PATHS+=("$normalized")
      if [ -d "$normalized" ]; then
        ALLOWED_PREFIXES+=("${normalized}/")
      fi
    fi
  done < <(get_stage_files "$stage")
  add_claim_target_allowed_path
}

is_claim_target_directory() {
  local method="${CLAIM_EVALUATION_METHOD:-}"
  if [ "$method" = "dir_exists" ]; then
    return 0
  fi
  if [ -n "$CLAIM_TARGET_PATH" ] && [[ "$CLAIM_TARGET_PATH" == */ ]]; then
    return 0
  fi
  if [ -n "$CLAIM_TARGET_PATH" ] && [ -d "$CLAIM_TARGET_PATH" ]; then
    return 0
  fi
  return 1
}

add_claim_target_allowed_path() {
  if [ -z "$CLAIM_TARGET_PATH" ]; then
    return
  fi
  local normalized
  normalized="$(normalize_repo_path "$CLAIM_TARGET_PATH")"
  [ -z "$normalized" ] && return
  if [[ "$normalized" == ".."* ]]; then
    return
  fi
  ALLOWED_PATHS+=("$normalized")
  if is_claim_target_directory; then
    ALLOWED_PREFIXES+=("${normalized%/}/")
  fi
}

path_is_allowed() {
  local candidate="$1"
  if [ -z "$candidate" ]; then
    return 1
  fi
  if [ "${#ALLOWED_PATHS[@]}" -eq 0 ] && [ "${#ALLOWED_PREFIXES[@]}" -eq 0 ]; then
    return 0
  fi
  local normalized
  normalized="$(normalize_repo_path "$candidate")"
  [ -z "$normalized" ] && return 1
  if [[ "$normalized" == ".."* ]]; then
    return 1
  fi
  for allowed in "${ALLOWED_PATHS[@]}"; do
    if [ "$normalized" = "$allowed" ]; then
      return 0
    fi
  done
  for prefix in "${ALLOWED_PREFIXES[@]}"; do
    if [[ "$normalized" == "${prefix}"* ]]; then
      return 0
    fi
  done
  return 1
}

normalize_diff_path() {
  local raw="$1"
  raw="${raw//$'\r'/}"
  if [[ "$raw" =~ ^[ab]/(.*)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$raw"
  fi
}

validate_path_pair() {
  local old_path="$1" new_path="$2"
  local target="$new_path"
  local action="modify"
  if [ "$new_path" = "/dev/null" ]; then
    target="$old_path"
    action="delete"
  elif [ "$old_path" = "/dev/null" ]; then
    target="$new_path"
    action="add"
  fi
  if [ -z "$target" ]; then
    return 0
  fi
  if ! path_is_allowed "$target"; then
    log "Invalid patch target (not in converge context): $target"
    return 1
  fi
  if [ "$action" = "modify" ] || [ "$action" = "delete" ]; then
    if [ ! -e "$target" ]; then
      log "Invalid patch target (path missing): $target"
      return 1
    fi
  fi
  return 0
}

validate_diff_targets() {
  local diff_file="$1"
  local last_old=""
  local last_new=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^---\ (.+)$ ]]; then
      last_old="$(normalize_diff_path "${BASH_REMATCH[1]}")"
      continue
    fi
    if [[ "$line" =~ ^\+\+\+\ (.+)$ ]]; then
      last_new="$(normalize_diff_path "${BASH_REMATCH[1]}")"
      if ! validate_path_pair "$last_old" "$last_new"; then
        return 1
      fi
    fi
  done < "$diff_file"
  return 0
}

build_context_bundle() {
  local stage="$1"
  local log_file="$2"
  local bundle_file="$3"

  {
    echo "# Executor Context Bundle"
    echo "# Stage: $stage"
    echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""

    # Include executor instructions
    if [ -f "$EXECUTOR_INSTRUCTIONS" ]; then
      echo "## Executor Instructions"
      echo ""
      cat "$EXECUTOR_INSTRUCTIONS"
      echo ""
    fi

    # Include relevant architecture sections from master memo
    if [ -f "$MASTER_MEMO" ]; then
      echo "## Architecture Context (from master_memo.md)"
      echo ""
      # For now, include the whole memo - could be filtered by section
      cat "$MASTER_MEMO"
      echo ""
    fi

    # Include backlog if exists
    if [ -f "$BACKLOG" ]; then
      echo "## Current Backlog"
      echo ""
      cat "$BACKLOG"
      echo ""
    fi

    # Include issues if exists
    if [ -f "$ISSUES" ]; then
      echo "## Known Issues"
      echo ""
      cat "$ISSUES"
      echo ""
    fi

    # Include relevant files for this stage
    echo "## Relevant Files for Stage '$stage'"
    echo ""

    while IFS= read -r file; do
      [ -z "$file" ] && continue
      read_file_if_exists "$file"
    done < <(get_stage_files "$stage")

    if [ -n "$CLAIM_TARGET_PATH" ]; then
      echo "## Claim Target Context"
      echo ""
      echo "Path: $CLAIM_TARGET_PATH"
      if [ -n "$CLAIM_EVALUATION_METHOD" ]; then
        echo "Evaluation method: $CLAIM_EVALUATION_METHOD"
      fi
      echo ""
      if [ -f "$CLAIM_TARGET_PATH" ]; then
        read_file_if_exists "$CLAIM_TARGET_PATH"
      elif [ -d "$CLAIM_TARGET_PATH" ]; then
        echo "Directory listing (top level):"
        ls -1 "$CLAIM_TARGET_PATH" 2>/dev/null | sed -e 's/^/  /'
        echo ""
      else
        echo "Path not present in repository (claim target missing)."
        echo ""
      fi
    fi

    if [ -n "$CLAIM_CONTEXT_FILE" ] && [ -f "$CLAIM_CONTEXT_FILE" ]; then
      echo "## Claim Context Metadata"
      echo ""
      cat "$CLAIM_CONTEXT_FILE"
      echo ""
    fi

    # Include log tail
    echo "## Log Tail (last 100 lines)"
    echo ""
    echo '```'
    extract_log_tail "$log_file" 100
    echo '```'
    echo ""

    echo "## Task"
    echo ""
    echo "Analyze the log output above and the relevant files."
    echo "Identify the root cause of the failure."
    echo "Produce a minimal, focused fix."
    echo ""
    echo "Output your fix as a unified diff that can be applied with 'git apply'."
    echo "Keep changes minimal - only modify what's necessary to fix the error."
    echo "Do not refactor or improve unrelated code."
    echo ""
    if [ -n "$CLAIM_EVALUATION_METHOD" ] && [ "$CLAIM_EVALUATION_METHOD" = "dir_exists" ] && [ -n "$CLAIM_TARGET_PATH" ]; then
      echo "IMPORTANT: The claim requires the directory '$CLAIM_TARGET_PATH' to exist."
      echo "If this directory is missing, create it by adding a file inside it using a unified diff."
      echo "Example: To create directory 'infrastructure/synology/setup', create a file like 'infrastructure/synology/setup/.gitkeep'"
      echo "or 'infrastructure/synology/setup/README.md' in your diff."
      echo "You may create new directories/files if they are within allowed paths (infrastructure/, cluster/, config/)."
      echo ""
      echo "CRITICAL: Even though the sandbox may be read-only, you MUST produce a unified diff."
      echo "The diff is a proposed change that will be applied by the executor using 'git apply'."
      echo "The read-only sandbox does not prevent you from outputting the diff text."
      echo ""
      echo "PRODUCE A UNIFIED DIFF NOW. Do not just explain what you would do - output the actual diff."
    elif [ -n "$CLAIM_EVALUATION_METHOD" ] && [ "$CLAIM_EVALUATION_METHOD" = "file_exists" ] && [ -n "$CLAIM_TARGET_PATH" ]; then
      echo "IMPORTANT: The claim requires the file '$CLAIM_TARGET_PATH' to exist."
      echo "If this file is missing, create it using a diff."
      echo "You may create new files if they are within allowed paths (infrastructure/, cluster/, config/)."
    else
      echo "Only edit files listed above (relevant stage files and the claim target)."
      echo "References to placeholder paths or files outside allowed paths will be rejected."
    fi
    echo ""

  } > "$bundle_file"
}

# =============================================================================
# Codex Invocation
# =============================================================================
codex_model_display() {
  local model="${CODEX_MODEL:-}"
  if [ -z "$model" ]; then
    printf '%s' "(default)"
    return
  fi
  printf '%s' "$model"
}

codex_model_is_invalid() {
  local model="${1:-}"
  if [ -z "$model" ]; then
    return 1
  fi
  local normalized
  normalized="$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')"
  case "$normalized" in
    "$CODEX_INVALID_MODEL") return 0 ;;
    *) return 1 ;;
  esac
}

provider_model_display() {
  local model="$1"
  if [ -z "$model" ]; then
    printf '%s' "(default)"
  else
    printf '%s' "$model"
  fi
}

# Detect if a failure is a provider failure (should trigger failover, not burn attempt)
is_provider_failure() {
  local log_file="$1"
  
  if [ ! -f "$log_file" ]; then
    return 1
  fi
  
  # Check for provider failure patterns: timeouts, connection errors, config errors, 5xx
  if grep -qiE '(timeout|connection.*refused|connection.*timed out|connection.*reset|name resolution failed|context deadline exceeded|i/o timeout|no route to host|network unreachable|model.*not supported|model.*not found|400 Bad Request|401 Unauthorized|403 Forbidden|500|502|503|504)' "$log_file" 2>/dev/null; then
    return 0  # is provider failure
  fi
  
  return 1  # not a provider failure
}

invoke_codex() {
  local context_file="$1"
  local output_file="$2"
  local codex_log="$3"

  local model_label
  model_label="$(codex_model_display)"

  # v7 spec: invoke as `codex --model <MODEL> "<prompt>"` (no unsupported flags like --input)
  if [ -n "$CODEX_MODEL" ]; then
    log "Runner invoking: provider=codex model=$CODEX_MODEL"
  else
    log "Runner invoking: provider=codex model=(default)"
  fi
  log "Codex timeout=${CODEX_TIMEOUT}s"

  if ! command -v "$CODEX_CLI" >/dev/null 2>&1; then
    log "WARN: Codex CLI not found: $CODEX_CLI"
    log "Falling back to direct prompt mode (requires manual review)"

    cp "$context_file" "${output_file}.prompt"
    log "Prompt saved to: ${output_file}.prompt"
    return 2
  fi

  # Check if model is invalid before attempting invocation
  if [ -n "$CODEX_MODEL" ] && codex_model_is_invalid "$CODEX_MODEL"; then
    log "Codex misconfigured: invalid model string ('$CODEX_MODEL') passed to CLI"
    echo "ERROR: Codex misconfigured: invalid model string ('$CODEX_MODEL') passed to CLI" > "$codex_log"
    return 4  # misconfigured_model
  fi

  # Read prompt from file for passing to Codex
  local prompt_content
  prompt_content="$(cat "$context_file")"

  set +e
  # v7 spec: invoke as `codex --model <MODEL> "<prompt>"` with prompt as argument
  # Pass context as the prompt argument, not via stdin with unsupported flags
  if [ -n "$CODEX_MODEL" ]; then
    timeout_cmd "$CODEX_TIMEOUT" "$CODEX_CLI" --model "$CODEX_MODEL" "$prompt_content" > "$output_file" 2> "$codex_log"
  else
    timeout_cmd "$CODEX_TIMEOUT" "$CODEX_CLI" "$prompt_content" > "$output_file" 2> "$codex_log"
  fi
  local rc=$?
  set -e

  if [ -f "$output_file" ]; then
    cat "$output_file" >> "$codex_log"
  fi

  # Check for CLI usage errors (e.g., unexpected argument '--input')
  if grep -qiE "(unexpected argument|error:|usage:)" "$codex_log" 2>/dev/null; then
    log "Codex CLI usage error detected - classifying as provider_failure"
    return 3  # provider_failure triggers failover without burning attempt
  fi

  if [ "$rc" -ne 0 ]; then
    log "Codex invocation failed (rc=$rc). See: $codex_log"
    if is_provider_failure "$codex_log"; then
      return 3
    fi
    return 1
  fi

  if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
    log "Codex produced no output"
    if is_provider_failure "$codex_log"; then
      return 3
    fi
    return 1
  fi

  if is_provider_failure "$codex_log"; then
    log "Provider failure detected in log despite exit code 0"
    return 3
  fi

  log "Codex output saved to: $output_file"
  return 0
}

invoke_ollama() {
  local context_file="$1"
  local output_file="$2"
  local provider_log="$3"
  local error_key="${4:-unknown}"

  local model="${EXECUTOR_PROVIDER_MODEL:-}"
  local model_label
  model_label="$(provider_model_display "$model")"

  log "Runner invoking: provider=ollama model=$model_label"
  log "Ollama executor: error_key=$error_key"

  if [ ! -x "$EXECUTOR_OLLAMA_CMD" ]; then
    log "ERROR: Ollama provider script missing or not executable: $EXECUTOR_OLLAMA_CMD"
    return 2
  fi

  set +e
  local call_output
  call_output="$("$EXECUTOR_OLLAMA_CMD" call "$context_file" "$output_file" "$model" "$error_key" 2>>"$provider_log")"
  local rc=$?
  set -e

  if [ -n "$call_output" ]; then
    printf '%s\n' "$call_output" >> "$provider_log"
  fi

  if [ "$rc" -ne 0 ]; then
    log "Ollama invocation failed (rc=$rc). See: $provider_log"
    if [ -s "$output_file" ]; then
      log "Ollama produced output despite failure: $output_file"
    fi
    return 3
  fi

  log "Ollama output saved to: $output_file"
  return 0
}

# =============================================================================
# Patch Extraction and Application
# =============================================================================
extract_diff_from_output() {
  local output_file="$1"
  local diff_file="$2"
  local claim_target="${3:-}"

  PROVIDER_OUTPUT_TYPE=""
  PROVIDER_OUTPUT_REASON=""

  if [ ! -f "$output_file" ]; then
    return 1
  fi

  log "Extracting diff from output file: $output_file (claim_target=${claim_target:-none})"

  local json_reason
  json_reason="$(
python3 - "$output_file" "$diff_file" <<'PYJSON'
import json
import sys

input_path, output_path = sys.argv[1:3]

with open(input_path, 'r') as f:
    content = f.read()

try:
    payload = json.loads(content)
except json.JSONDecodeError:
    sys.exit(1)

diff = payload.get("diff", "")
if isinstance(diff, str) and diff.strip():
    with open(output_path, "w") as o:
        o.write(diff)
    sys.exit(0)

output_type = (payload.get("type") or "").lower()
if output_type == "no_patch":
    reason = payload.get("reason") or payload.get("description") or ""
    print(reason.strip())
    sys.exit(2)

sys.exit(1)
PYJSON
  )"
  local json_exit=$?
  if [ "$json_exit" -eq 0 ]; then
    PROVIDER_OUTPUT_TYPE="patch"
    return 0
  fi
  if [ "$json_exit" -eq 2 ]; then
    PROVIDER_OUTPUT_TYPE="no_patch"
    PROVIDER_OUTPUT_REASON="$(printf '%s' "$json_reason" | tr -d '\r' | tr '\n' ' ')"
    PROVIDER_OUTPUT_REASON="${PROVIDER_OUTPUT_REASON#"${PROVIDER_OUTPUT_REASON%%[![:space:]]*}"}"
    PROVIDER_OUTPUT_REASON="${PROVIDER_OUTPUT_REASON%"${PROVIDER_OUTPUT_REASON##*[![:space:]]}"}"
    log "JSON parsing returned no_patch (reason: ${PROVIDER_OUTPUT_REASON})"
    return 2
  fi

  # Fallback to pattern matching (diff fences/raw diff)
  # Find ALL diffs and prefer the last one (most recent), or one matching claim target
  log "JSON parsing failed (rc=$json_exit), trying pattern matching..."
  log "Running Python diff extraction script with claim_target='${claim_target:-none}'..."
  if python3 - "$output_file" "$diff_file" "$claim_target" <<'PY' 2>>"${output_file}.extract.log"; then
import sys
import re

input_path, output_path, claim_target = sys.argv[1:4] if len(sys.argv) > 3 else (sys.argv[1], sys.argv[2], "")

with open(input_path, 'r') as f:
    content = f.read()

# Find all diff blocks in markdown code fences
diff_pattern = r'```(?:diff)?\s*\n((?:---|\+\+\+|@@|[-+ ].*\n)+)```'
all_matches = list(re.finditer(diff_pattern, content, re.MULTILINE))

# Also find all raw diffs
raw_diff_pattern = r'(---\s+\S+.*?\n\+\+\+\s+\S+.*?\n(?:@@.*?\n(?:[-+ ].*?\n)*)+)'
all_matches.extend(re.finditer(raw_diff_pattern, content, re.MULTILINE | re.DOTALL))

if not all_matches:
    sys.exit(1)

# Prefer diff that matches claim target, otherwise use the last one
best_match = None
for match in all_matches:
    diff_text = match.group(1)
    # If we have a claim target and this diff mentions it, prefer this one
    if claim_target and claim_target in diff_text:
        best_match = diff_text
        break

# Otherwise use the last (most recent) diff
if best_match is None:
    best_match = all_matches[-1].group(1)

with open(output_path, 'w') as f:
    f.write(best_match)
sys.exit(0)
PY
    log "Pattern matching succeeded, diff written to: $diff_file"
    PROVIDER_OUTPUT_TYPE="patch"
    return 0
  else
    local pattern_rc=$?
    log "Pattern matching failed (rc=$pattern_rc)"
    if [ -f "${output_file}.extract.log" ]; then
      log "Pattern matching error log: $(head -20 "${output_file}.extract.log" | tr '\n' '; ')"
    fi
    return 1
  fi
}

apply_executor_patch() {
  local diff_file="$1"

  log "Attempting to apply patch: $diff_file"

  # Validate the patch
  if ! git apply --check "$diff_file" 2>/dev/null; then
    log "Patch does not apply cleanly"
    return 1
  fi

  # Ensure we're on the AI branch
  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"

  if [ "$current_branch" != "$AI_BRANCH" ]; then
    log "Switching to AI branch: $AI_BRANCH"
    git checkout -B "$AI_BRANCH" 2>/dev/null || git checkout "$AI_BRANCH" 2>/dev/null || {
      git checkout -b "$AI_BRANCH"
    }
  fi

  # Apply the patch
  git apply "$diff_file"
  git add -A

  local commit_msg="[executor] Apply local fix

Source: Codex/local LLM
Patch: $diff_file
Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  git commit -m "$commit_msg"

  log "Patch applied and committed"
  return 0
}

# =============================================================================
# Main
# =============================================================================
main() {
  if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <stage> <log_file> <error_hash> [summary_file]"
    exit 1
  fi

  local stage="$1"
  local log_file="$2"
  local error_hash="$3"
  local summary_file="${4:-}"
  collect_stage_allowed_paths "$stage"

  log "=== Executor Runner ==="
  log "Stage: $stage"
  log "Log file: $log_file"
  log "Error hash: $error_hash"

  ensure_directories

  local timestamp
  timestamp="$(date -u +%Y%m%d-%H%M%S)"
  local context_file="${PATCHES_DIR}/executor_context_${stage}_${timestamp}.md"
  local output_file="${PATCHES_DIR}/executor_output_${stage}_${timestamp}.md"
  local diff_file="${PATCHES_DIR}/executor_patch_${stage}_${timestamp}.diff"

  # Build context bundle
  log "Building context bundle..."
  build_context_bundle "$stage" "$log_file" "$context_file"
  log "Context bundle: $context_file"

  local provider="${EXECUTOR_PROVIDER:-codex}"
  local provider_model="${EXECUTOR_PROVIDER_MODEL:-${CODEX_MODEL:-}}"
  local provider_model_label
  provider_model_label="$(provider_model_display "$provider_model")"
  local provider_log="${LOG_DIR}/executor/${provider}_${timestamp}.log"

  log "Executor invocation settings: provider=$provider stage=$stage model=$provider_model_label log=$provider_log"

  local provider_rc=0
  case "$provider" in
    codex)
      if codex_model_is_invalid "$CODEX_MODEL"; then
        log "Codex misconfigured: invalid model string '$CODEX_MODEL'. Update CODEX_MODEL to a supported model before retrying."
        write_summary "$summary_file" "misconfigured_model" "$provider" "$provider_model" "4" "$provider_log" "reason=invalid_model"
        return 4
      fi
      invoke_codex "$context_file" "$output_file" "$provider_log"
      provider_rc=$?
      ;;
    ollama)
      invoke_ollama "$context_file" "$output_file" "$provider_log" "$error_hash"
      provider_rc=$?
      ;;
    *)
      log "ERROR: Unsupported executor provider: $provider"
      write_summary "$summary_file" "tooling_failure" "$provider" "$provider_model" "1" "$provider_log" "reason=unsupported_provider"
      return 1
      ;;
  esac

  if [ "$provider_rc" -eq 3 ]; then
    log "Provider failure detected - this should trigger failover"
    write_summary "$summary_file" "provider_failure" "$provider" "$provider_model" "$provider_rc" "$provider_log" "reason=provider_failure"
    return 3
  fi

  if [ "$provider_rc" -eq 2 ]; then
    log "Executor provider tooling failure (rc=$provider_rc)"
    write_summary "$summary_file" "tooling_failure" "$provider" "$provider_model" "$provider_rc" "$provider_log" "reason=tooling_failure"
    return 2
  fi

  if [ "$provider_rc" -ne 0 ]; then
    log "Executor provider returned unexpected rc=$provider_rc"
    write_summary "$summary_file" "tooling_failure" "$provider" "$provider_model" "$provider_rc" "$provider_log" "reason=provider_error"
    return 1
  fi

  extract_diff_from_output "$output_file" "$diff_file" "${CLAIM_TARGET_PATH:-}"
  local extract_rc=$?
  if [ "$extract_rc" -eq 2 ]; then
    log "Provider reported no patch${PROVIDER_OUTPUT_REASON:+ (reason=$PROVIDER_OUTPUT_REASON)}"
    write_summary "$summary_file" "no_patch" "$provider" "$provider_model" "$provider_rc" "$provider_log" "reason=${PROVIDER_OUTPUT_REASON:-no_fix_provided}"
    return 1
  fi

  if [ "$extract_rc" -ne 0 ]; then
    log "Could not extract diff from executor output (rc=$extract_rc)"
    if [ -f "${output_file}.extract.log" ]; then
      log "Extraction log: $(cat "${output_file}.extract.log")"
    fi
    write_summary "$summary_file" "no_patch" "$provider" "$provider_model" "$provider_rc" "$provider_log" "reason=no_diff_extracted"
    return 1
  fi
  
  if [ ! -f "$diff_file" ] || [ ! -s "$diff_file" ]; then
    log "Diff file not created or empty: $diff_file"
    write_summary "$summary_file" "no_patch" "$provider" "$provider_model" "$provider_rc" "$provider_log" "reason=diff_file_empty"
    return 1
  fi
  
  log "Successfully extracted diff to: $diff_file ($(wc -l < "$diff_file") lines)"

  if ! validate_diff_targets "$diff_file"; then
    log "Diff references paths outside the converge context"
    write_summary "$summary_file" "tooling_failure" "$provider" "$provider_model" "4" "$provider_log" "reason=invalid_patch_target"
    return 2
  fi

  local lines_changed=0
  if [ -f "$diff_file" ]; then
    lines_changed="$(grep -cE '^[+-]' "$diff_file" 2>/dev/null || echo "0")"
  fi

  if ! apply_executor_patch "$diff_file"; then
    log "Failed to apply patch"
    write_summary "$summary_file" "no_patch" "$provider" "$provider_model" "0" "$provider_log" "reason=patch_apply_failed" "lines_changed=$lines_changed"
    return 1
  fi

  log "Executor completed successfully"
  write_summary "$summary_file" "patch" "$provider" "$provider_model" "0" "$provider_log" "lines_changed=$lines_changed"
  return 0
}

main "$@"
