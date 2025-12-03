#!/usr/bin/env bash
set -euo pipefail

persona_planner_handle(){
  local tid="$1" type="$2" target="$3" desc="$4" ts="$5" log_file="$6" stage="${7:-0}"
  local stage_num="${stage//[!0-9]/}"
  stage_num="${stage_num:-0}"

  planner_log_event(){
    local status="$1" note="$2"
    log_task_event "$log_file" "$tid" "planner" "${target:-<none>}" "$status" "0" "$note"
  }

  planner_block_failure(){
    local reason="$1"
    local note="planner failure; human review required: ${reason}"
    set_task_status "$tid" "blocked" "$note"
    planner_log_event "blocked" "$note"
    append_last_run "[$ts] ${tid} blocked (${reason})"
    update_current_task "$tid" "planner" "blocked" "$desc"
    return 1
  }

  # Validate task is in a valid starting state
  local current_status
  current_status="$(get_task_status "$tid" 2>/dev/null || echo "")"
  if [ -z "$current_status" ]; then
    planner_log_event "failed" "task not found in backlog"
    update_current_task "$tid" "planner" "failed" "$desc"
    append_last_run "[$ts] ${tid} failed (task not found)"
    return 1
  fi
  if [ "$current_status" != "pending" ] && [ "$current_status" != "waiting_retry" ]; then
    planner_log_event "failed" "task in invalid state: $current_status"
    update_current_task "$tid" "planner" "failed" "$desc"
    append_last_run "[$ts] ${tid} failed (invalid state: $current_status)"
    return 1
  fi

  planner_log_event "running" "consulted README + ai/inspiration for context"
  set +e
  set_task_status "$tid" "running" "planner running"
  local transition_rc=$?
  set -e
  if [ "$transition_rc" -ne 0 ]; then
    planner_log_event "failed" "failed to transition to running (rc=$transition_rc)"
    update_current_task "$tid" "planner" "failed" "$desc"
    append_last_run "[$ts] ${tid} failed (state transition error)"
    return 1
  fi
  update_current_task "$tid" "planner" "running" "$desc"

  if [ ! -s "$target" ]; then
    planner_block_failure "missing patch"
    return 1
  fi

  local mission inspiration
  mission="$(cat README.md 2>/dev/null || true)"
  inspiration="$(cat ai/vision/inspiration.md 2>/dev/null || true)"
  if ! printf '%s' "$mission" | grep -qi "Stage 0" >/dev/null 2>&1; then
    planner_block_failure "missing Stage 0 focus in README"
    return 1
  fi
  # Ensure patch sticks within allowed planner scope
  planner_allowed(){
    local path="$1"
    case "$path" in
      ai/backlog.yaml|ai/mission.md|ai/inspiration.md|ai/state/*) return 0 ;;
      *) return 1 ;;
    esac
  }

  local patch_lines
  patch_lines=$(wc -l < "$target" | tr -d ' ')
  if [ "$patch_lines" -gt 400 ]; then
    planner_block_failure "planner patch too large ($patch_lines lines)"
    return 1
  fi

  local touched_ok=0
  while read -r line; do
    [[ "$line" =~ ^\*\*\*\ (Update|Delete|Add)\ File:\  ]] && file="${line#*** Update File: }" && file="${file#*** Delete File: }" && file="${file#*** Add File: }"
    [[ -z "${file:-}" ]] && continue
    if ! planner_allowed "$file"; then
      planner_block_failure "planner touched forbidden path $file"
      return 1
    fi
    if [[ "$file" == ai/backlog.yaml ]]; then
      local stage_line
      stage_line="$(printf '%s\n' "$line" | sed -n 's/.*stage:[[:space:]]*\\([0-9]\\+\\).*/\\1/p')"
      if [ -n "$stage_line" ] && [ "$stage_line" -ne "$stage_num" ]; then
        planner_block_failure "patch stage $stage_line conflicts with orchestrator stage $stage_num"
        return 1
      fi
    fi
    if [[ "$line" =~ stage:[[:space:]]*([0-9]+) ]]; then
      local stage_line="${BASH_REMATCH[1]}"
      if [ "$stage_line" -ne "$stage_num" ]; then
        planner_block_failure "patch stage $stage_line conflicts with orchestrator stage $stage_num"
        return 1
      fi
    fi
    touched_ok=1
  done < "$target"

  if [ "$touched_ok" -eq 0 ]; then
    planner_block_failure "planner patch touched no allowed files"
    return 1
  fi

  if [ "${#inspiration}" -eq 0 ]; then
    planner_block_failure "ai/inspiration.md is empty"
    return 1
  fi

  planner_log_event "completed" "approved patch; syncing backlog with README + ai/inspiration"
  set +e
  set_task_status "$tid" "completed" "approved by planner"
  set -e
  append_apply_task "$tid" "$target" "$stage"
  append_last_run "[$ts] ${tid} approved"
  update_current_task "$tid" "planner" "completed" "$desc"
}
