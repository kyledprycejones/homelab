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
: "${MASTER_MEMO:=ai/master_memo.md}"
: "${BACKLOG:=ai/backlog.md}"
: "${ISSUES:=ai/issues.txt}"
: "${LOG_DIR:=ai/logs}"
: "${PATCHES_DIR:=ai/patches}"
: "${AI_BRANCH:=ai/orchestrator-stage1}"

# Codex CLI configuration
: "${CODEX_CLI:=codex}"
: "${CODEX_MODEL:=cursor}"  # Local model
: "${CODEX_TIMEOUT:=120}"

# =============================================================================
# Helpers
# =============================================================================
log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[executor] [%s] %s\n' "$ts" "$*"
}

ensure_directories() {
  mkdir -p "$PATCHES_DIR" "$LOG_DIR/executor"
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

  } > "$bundle_file"
}

# =============================================================================
# Codex Invocation
# =============================================================================
invoke_codex() {
  local context_file="$1"
  local output_file="$2"

  log "Invoking Codex CLI for local fix..."

  # Check if codex CLI is available
  if ! command -v "$CODEX_CLI" >/dev/null 2>&1; then
    log "WARN: Codex CLI not found: $CODEX_CLI"
    log "Falling back to direct prompt mode (requires manual review)"

    # Create a prompt file for manual execution
    cp "$context_file" "${output_file}.prompt"
    log "Prompt saved to: ${output_file}.prompt"
    return 1
  fi

  # Invoke Codex
  local codex_log="${LOG_DIR}/executor/codex_$(date -u +%Y%m%d-%H%M%S).log"

  set +e
  timeout "$CODEX_TIMEOUT" "$CODEX_CLI" \
    --model "$CODEX_MODEL" \
    --input "$context_file" \
    --output "$output_file" \
    > "$codex_log" 2>&1
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    log "Codex invocation failed (rc=$rc). See: $codex_log"
    return 1
  fi

  if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
    log "Codex produced no output"
    return 1
  fi

  log "Codex output saved to: $output_file"
  return 0
}

# =============================================================================
# Patch Extraction and Application
# =============================================================================
extract_diff_from_output() {
  local output_file="$1"
  local diff_file="$2"

  # Try to extract unified diff from the output
  # Look for diff markers
  python3 - "$output_file" "$diff_file" <<'PY'
import sys
import re

input_path, output_path = sys.argv[1:3]

with open(input_path, 'r') as f:
    content = f.read()

# Try to find diff block in markdown code fence
diff_pattern = r'```(?:diff)?\n((?:---|\+\+\+|@@|[-+ ].*\n)+)```'
match = re.search(diff_pattern, content, re.MULTILINE)

if match:
    with open(output_path, 'w') as f:
        f.write(match.group(1))
    sys.exit(0)

# Try to find raw diff (starts with ---)
raw_diff_pattern = r'(---\s+\S+.*?\n\+\+\+\s+\S+.*?\n(?:@@.*?\n(?:[-+ ].*?\n)*)+)'
match = re.search(raw_diff_pattern, content, re.MULTILINE | re.DOTALL)

if match:
    with open(output_path, 'w') as f:
        f.write(match.group(1))
    sys.exit(0)

# No diff found
sys.exit(1)
PY
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
    echo "Usage: $0 <stage> <log_file> <error_hash>"
    exit 1
  fi

  local stage="$1"
  local log_file="$2"
  local error_hash="$3"

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

  # Invoke Codex
  if ! invoke_codex "$context_file" "$output_file"; then
    log "Codex invocation failed. Manual intervention may be required."
    return 1
  fi

  # Extract diff from output
  if ! extract_diff_from_output "$output_file" "$diff_file"; then
    log "Could not extract diff from Codex output"
    log "Review output manually: $output_file"
    return 1
  fi

  # Apply the patch
  if ! apply_executor_patch "$diff_file"; then
    log "Failed to apply patch"
    return 1
  fi

  log "Executor completed successfully"
  return 0
}

main "$@"
