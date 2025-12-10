#!/usr/bin/env bash
# Orchestrator v2 - Case File Generator
#
# Generates structured case files for API escalation. Case files contain:
#   - Stage metadata
#   - Architecture excerpts (relevant sections)
#   - Backlog context
#   - Relevant files (full or excerpts)
#   - Log tail
#   - Optional diagnostic outputs (for v2 case files)
#
# Usage:
#   ./ai/case_file_generator.sh <stage> <log_file> <output_file> [diagnostics_dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# =============================================================================
# Configuration
# =============================================================================
: "${CONTEXT_MAP:=ai/context_map.yaml}"
: "${MASTER_MEMO:=ai/master_memo.md}"
: "${BACKLOG:=ai/backlog.md}"
: "${ISSUES:=ai/issues.txt}"
: "${LOG_TAIL_LINES:=100}"
: "${MAX_FILE_LINES:=500}"

# =============================================================================
# Helpers
# =============================================================================
log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[case-gen] [%s] %s\n' "$ts" "$*" >&2
}

# =============================================================================
# Context Extraction from context_map.yaml
# =============================================================================
get_stage_info() {
  local stage="$1"
  local field="$2"

  if [ ! -f "$CONTEXT_MAP" ]; then
    return
  fi

  # Try Python with yaml module first, fall back to simple grep-based parsing
  python3 - "$CONTEXT_MAP" "$stage" "$field" <<'PY' 2>/dev/null || _get_stage_info_fallback "$stage" "$field"
import sys

path, stage, field = sys.argv[1:4]
try:
    # Try importing yaml
    try:
        import yaml
        with open(path, 'r') as f:
            data = yaml.safe_load(f)
    except ImportError:
        # Fallback: simple regex-based parsing for basic cases
        import re
        with open(path, 'r') as f:
            content = f.read()

        # Find the stage section
        stage_pattern = rf'^\s*{re.escape(stage)}:\s*$'
        stage_match = re.search(stage_pattern, content, re.MULTILINE)
        if not stage_match:
            sys.exit(0)

        # Find the field within the stage section
        stage_start = stage_match.end()
        # Find next top-level key or end
        next_section = re.search(r'^\s*\w+:\s*$', content[stage_start:], re.MULTILINE)
        if next_section:
            stage_content = content[stage_start:stage_start + next_section.start()]
        else:
            stage_content = content[stage_start:]

        # Look for the field
        field_pattern = rf'^\s*{re.escape(field)}:\s*(.*)$'
        field_match = re.search(field_pattern, stage_content, re.MULTILINE)

        if field_match:
            value = field_match.group(1).strip()
            if value:
                print(value)
            else:
                # It's a list, look for items
                field_start = field_match.end()
                list_pattern = r'^\s*-\s*(.+)$'
                for m in re.finditer(list_pattern, stage_content[field_start:], re.MULTILINE):
                    item = m.group(1).strip()
                    # Check if this is still in our field (not a new field)
                    if re.match(r'^\s*\w+:', stage_content[field_start:field_start + m.start()], re.MULTILINE):
                        break
                    print(item)
        sys.exit(0)

    stages = data.get('stages', {})
    if stage in stages:
        value = stages[stage].get(field)
        if isinstance(value, list):
            for v in value:
                print(v)
        elif value:
            print(value)
except Exception as e:
    pass
PY
}

# Fallback YAML parser using grep/sed for simple cases
_get_stage_info_fallback() {
  local stage="$1"
  local field="$2"

  # Very simple parsing - look for stage section and then field
  # This works for simple list values under a stage
  awk -v stage="$stage" -v field="$field" '
    BEGIN { in_stage=0; in_field=0; indent=0 }
    /^[a-z]+:/ { in_stage=0; in_field=0 }
    $0 ~ "^  " stage ":" { in_stage=1; next }
    in_stage && $0 ~ "^    " field ":" {
      in_field=1
      # Check for inline value
      sub("^    " field ": *", "")
      if ($0 != "") print $0
      next
    }
    in_stage && in_field && /^      - / {
      sub("^      - *", "")
      print
    }
    in_stage && in_field && /^    [a-z]/ { in_field=0 }
  ' "$CONTEXT_MAP" 2>/dev/null
}

get_stage_files() {
  local stage="$1"
  get_stage_info "$stage" "files"
}

get_architecture_sections() {
  local stage="$1"
  get_stage_info "$stage" "architecture_sections"
}

get_stage_description() {
  local stage="$1"
  get_stage_info "$stage" "description"
}

get_success_criteria() {
  local stage="$1"
  get_stage_info "$stage" "success_criteria"
}

# =============================================================================
# File Reading
# =============================================================================
read_file_excerpt() {
  local file="$1"
  local max_lines="$2"

  if [ ! -f "$file" ]; then
    echo "# File not found: $file"
    return
  fi

  local total_lines
  total_lines="$(wc -l < "$file")"

  if [ "$total_lines" -le "$max_lines" ]; then
    cat "$file"
  else
    echo "# (Showing first $max_lines of $total_lines lines)"
    head -n "$max_lines" "$file"
    echo ""
    echo "# ... (truncated)"
  fi
}

# =============================================================================
# Architecture Section Extraction
# =============================================================================
extract_architecture_section() {
  local memo_file="$1"
  local section="$2"

  if [ ! -f "$memo_file" ]; then
    return
  fi

  # Extract section based on markdown headers
  # This is a simplified extraction - looks for ## Section Name
  python3 - "$memo_file" "$section" <<'PY'
import sys
import re

path, section = sys.argv[1:3]

try:
    with open(path, 'r') as f:
        content = f.read()

    # Look for markdown section headers
    section_lower = section.lower()

    # Pattern: ## Section or ### Section (case insensitive)
    pattern = rf'^(##+ .*{re.escape(section)}.*?)(?=^##+ |\Z)'
    match = re.search(pattern, content, re.MULTILINE | re.DOTALL | re.IGNORECASE)

    if match:
        print(match.group(1).strip())
    else:
        # Try to find any paragraph mentioning the section
        lines = content.split('\n')
        in_section = False
        output = []
        for line in lines:
            if section_lower in line.lower():
                in_section = True
            if in_section:
                output.append(line)
                if line.startswith('##') and section_lower not in line.lower():
                    break
        if output:
            print('\n'.join(output[:50]))  # Limit output
except Exception:
    pass
PY
}

# =============================================================================
# Case File Generation
# =============================================================================
generate_case_file() {
  local stage="$1"
  local log_file="$2"
  local output_file="$3"
  local diagnostics_dir="${4:-}"

  local case_version="1"
  if [ -n "$diagnostics_dir" ] && [ -d "$diagnostics_dir" ]; then
    case_version="2"
  fi

  log "Generating Case File v${case_version} for stage: $stage"

  {
    # Header
    echo "# Case File v${case_version}"
    echo ""
    echo "## Metadata"
    echo ""
    echo "- **Stage:** $stage"
    echo "- **Generated:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- **Log File:** $log_file"
    echo "- **Case Version:** $case_version"
    echo ""

    # Stage description
    local description
    description="$(get_stage_description "$stage")"
    if [ -n "$description" ]; then
      echo "## Stage Description"
      echo ""
      echo "$description"
      echo ""
    fi

    # Success criteria
    echo "## Success Criteria"
    echo ""
    while IFS= read -r criteria; do
      [ -z "$criteria" ] && continue
      echo "- $criteria"
    done < <(get_success_criteria "$stage")
    echo ""

    # Architecture context
    echo "## Architecture Context"
    echo ""
    echo "Relevant sections from the master architecture memo:"
    echo ""

    while IFS= read -r section; do
      [ -z "$section" ] && continue
      echo "### $section"
      echo ""
      local excerpt
      excerpt="$(extract_architecture_section "$MASTER_MEMO" "$section")"
      if [ -n "$excerpt" ]; then
        echo "$excerpt"
      else
        echo "(No specific section found for: $section)"
      fi
      echo ""
    done < <(get_architecture_sections "$stage")

    # Backlog context
    if [ -f "$BACKLOG" ]; then
      echo "## Current Backlog"
      echo ""
      echo '```'
      head -n 50 "$BACKLOG"
      echo '```'
      echo ""
    fi

    # Issues context
    if [ -f "$ISSUES" ] && [ -s "$ISSUES" ]; then
      echo "## Known Issues"
      echo ""
      echo '```'
      cat "$ISSUES"
      echo '```'
      echo ""
    fi

    # Relevant files
    echo "## Relevant Files"
    echo ""

    while IFS= read -r file; do
      [ -z "$file" ] && continue
      if [ ! -f "$file" ]; then
        echo "### $file"
        echo ""
        echo "(File not found)"
        echo ""
        continue
      fi

      echo "### $file"
      echo ""
      echo '```'
      read_file_excerpt "$file" "$MAX_FILE_LINES"
      echo '```'
      echo ""
    done < <(get_stage_files "$stage")

    # Log tail
    echo "## Log Tail"
    echo ""
    echo "Last $LOG_TAIL_LINES lines from: $log_file"
    echo ""
    echo '```'
    if [ -f "$log_file" ]; then
      tail -n "$LOG_TAIL_LINES" "$log_file"
    else
      echo "(Log file not found)"
    fi
    echo '```'
    echo ""

    # Diagnostic outputs (for v2)
    if [ "$case_version" = "2" ] && [ -d "$diagnostics_dir" ]; then
      echo "## Diagnostic Outputs"
      echo ""
      echo "Diagnostics collected from: $diagnostics_dir"
      echo ""

      for diag_file in "$diagnostics_dir"/*; do
        [ -f "$diag_file" ] || continue
        local filename
        filename="$(basename "$diag_file")"
        echo "### $filename"
        echo ""
        echo '```'
        read_file_excerpt "$diag_file" 200
        echo '```'
        echo ""
      done
    fi

    # Instructions for API
    echo "## Instructions"
    echo ""
    echo "You are the escalation tier for the Funoffshore Homelab Orchestrator."
    echo "This case file contains all relevant context for a stage failure."
    echo ""
    echo "Your task:"
    echo "1. Analyze the log output and error"
    echo "2. Review the relevant files and architecture context"
    echo "3. Determine the root cause"
    echo "4. Produce a fix"
    echo ""
    echo "You may respond with ONE of the following:"
    echo ""
    echo "### Option A: Patch Response"
    echo ""
    echo "If you can identify a fix, respond with:"
    echo '```json'
    echo '{'
    echo '  "type": "patch",'
    echo '  "description": "Brief description of the fix",'
    echo '  "files_modified": ["file1.sh", "file2.yaml"]'
    echo '}'
    echo '```'
    echo ""
    echo "Followed by a unified diff:"
    echo '```diff'
    echo "--- a/path/to/file"
    echo "+++ b/path/to/file"
    echo "@@ -line,count +line,count @@"
    echo " context"
    echo "-removed line"
    echo "+added line"
    echo '```'
    echo ""
    echo "### Option B: Diagnostics Request"
    echo ""
    echo "If you need more information, respond with:"
    echo '```json'
    echo '{'
    echo '  "type": "diagnostics",'
    echo '  "reason": "Why you need diagnostics",'
    echo '  "commands": ['
    echo '    "command1",'
    echo '    "command2"'
    echo '  ]'
    echo '}'
    echo '```'
    echo ""
    echo "## Constraints"
    echo ""
    echo "- You may NOT modify protected files (ai/master_memo.md, ai/context_map.yaml, etc.)"
    echo "- Keep patches minimal and focused"
    echo "- Do not introduce new dependencies without justification"
    echo "- All changes must be reversible"
    echo ""

  } > "$output_file"

  log "Case file written to: $output_file"
}

# =============================================================================
# Main
# =============================================================================
main() {
  if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <stage> <log_file> <output_file> [diagnostics_dir]"
    echo ""
    echo "Generates a Case File for API escalation."
    echo ""
    echo "Arguments:"
    echo "  stage          - The stage that failed (vms, talos, infra, etc.)"
    echo "  log_file       - Path to the stage execution log"
    echo "  output_file    - Where to write the case file"
    echo "  diagnostics_dir - (Optional) Directory with diagnostic outputs for v2"
    exit 1
  fi

  local stage="$1"
  local log_file="$2"
  local output_file="$3"
  local diagnostics_dir="${4:-}"

  generate_case_file "$stage" "$log_file" "$output_file" "$diagnostics_dir"
}

main "$@"
