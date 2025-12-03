#!/usr/bin/env bash
set -euo pipefail

persona_executor_handle(){
  local tid="$1" type="$2" target="$3" desc="$4" ts="$5" log_file="$6" stage="${7:-0}"

  # Load executor config
  local allowed forbidden max_retries
  allowed=$(yaml_get_persona_config executor allowed_paths "[]")
  forbidden=$(yaml_get_persona_config executor forbidden_paths "[]")
  max_retries=3

  # Path validation helper
  path_allowed(){
    local path="$1"
    local ok=1
    for p in $(echo "$allowed" | jq -r '.[]'); do
      [[ "$path" == "$p"* ]] && ok=0 && break
    done
    if [ "$ok" -ne 0 ]; then return 1; fi
    for f in $(echo "$forbidden" | jq -r '.[]'); do
      [[ "$path" == "$f"* ]] && return 1
    done
    return 0
  }

  executor_log_event(){
    local status="$1" failure_count="${2:-0}" note="$3"
    log_task_event "$log_file" "$tid" "executor" "${target:-<none>}" "$status" "$failure_count" "$note"
  }

  # Validate task is in a valid starting state
  local current_status
  current_status="$(get_task_status "$tid" 2>/dev/null || echo "")"
  if [ -z "$current_status" ]; then
    executor_log_event "failed" "0" "task not found in backlog"
    update_current_task "$tid" "executor" "failed" "$desc"
    append_last_run "[$ts] ${tid} failed (task not found)"
    return 1
  fi
  if [ "$current_status" != "pending" ] && [ "$current_status" != "waiting_retry" ]; then
    executor_log_event "failed" "0" "task in invalid state: $current_status"
    update_current_task "$tid" "executor" "failed" "$desc"
    append_last_run "[$ts] ${tid} failed (invalid state: $current_status)"
    return 1
  fi

  # Always transition to running first (required by state machine)
  set +e
  set_task_status "$tid" "running" "executor running"
  local transition_rc=$?
  set -e
  if [ "$transition_rc" -ne 0 ]; then
    executor_log_event "failed" "0" "failed to transition to running (rc=$transition_rc)"
    update_current_task "$tid" "executor" "failed" "$desc"
    append_last_run "[$ts] ${tid} failed (state transition error)"
    return 1
  fi
  executor_log_event "running" "0" "$desc"
  update_current_task "$tid" "executor" "running" "$desc"

  # Validate target before proceeding
  if [ -n "$target" ] && ! path_allowed "$target"; then
    set +e
    set_task_status "$tid" "failed" "executor: target not allowed"
    set -e
    executor_log_event "failed" "0" "target not allowed"
    update_current_task "$tid" "executor" "failed" "$desc"
    append_last_run "[$ts] ${tid} failed (target not allowed)"
    return 1
  fi

  if [ "$type" = "run" ] && [ -z "$target" ]; then
    set +e
    set_task_status "$tid" "failed" "executor: missing run target"
    set -e
    executor_log_event "failed" "0" "missing run target"
    update_current_task "$tid" "executor" "failed" "$desc"
    append_last_run "[$ts] ${tid} failed (no run target)"
    return 1
  fi

  if [ "$type" = "run" ] && [ -n "$target" ] && [ ! -f "$target" ]; then
    set +e
    set_task_status "$tid" "failed" "executor: target missing file"
    set -e
    executor_log_event "failed" "0" "missing target file"
    update_current_task "$tid" "executor" "failed" "$desc"
    append_last_run "[$ts] ${tid} failed (target missing)"
    return 1
  fi

  handle_failure(){
    local tail="$1" classification="$2" hash="$3" note="$4"
    local count total next_retry
    count=$(increment_failure_count "$tid" "$hash")
    total=$(total_failure_count "$tid")
    if [ "$total" -lt 3 ]; then
      next_retry=$(( $(date +%s) + 60 * ( total < 10 ? total : 10 ) ))
      set_task_status "$tid" "waiting_retry" "executor retry scheduled" "$next_retry"
      executor_log_event "waiting_retry" "$total" "executor retry scheduled"
      append_last_run "[$ts] ${tid} waiting_retry (count=${total})"
      update_current_task "$tid" "executor" "waiting_retry" "$desc"
    else
      set_task_status "$tid" "escalated" "escalated after failures"
      executor_log_event "escalated" "$total" "escalated after failures"
      append_engineer_task "$tid" "$target" "$tail" "$stage"
      append_last_run "[$ts] ${tid} escalated after ${total} failures"
      update_current_task "$tid" "executor" "escalated" "$desc"
    fi
    record_last_error "$tid" "executor" "$target" "$tail" "$classification" "$count" "$hash"
    return 1
  }

  # Note: Task is already in "running" state from validation above
  case "$type" in
    apply_patch)
      if [ ! -s "$target" ]; then
        set +e
        set_task_status "$tid" "failed" "patch missing or empty"
        set -e
        executor_log_event "failed" "0" "patch missing or empty"
        update_current_task "$tid" "executor" "failed" "$desc"
        append_last_run "[$ts] ${tid} failed (missing patch)"
        return 1
      fi
      while read -r line; do
        [[ "$line" =~ ^\*\*\*\ Update\ File:\  ]] || continue
        file="${line#*** Update File: }"
        if ! path_allowed "$file"; then
          set +e
          set_task_status "$tid" "failed" "patch touches forbidden path"
          set -e
          executor_log_event "failed" "0" "patch touches forbidden path"
          update_current_task "$tid" "executor" "failed" "$desc"
          append_last_run "[$ts] ${tid} failed (forbidden path in patch)"
          return 1
        fi
      done < "$target"
      if apply_patch_file "$target" "$log_file"; then
        set +e
        set_task_status "$tid" "completed" "patch applied"
        set -e
        executor_log_event "completed" "0" "patch applied"
        append_last_run "[$ts] ${tid} applied patch"
        update_current_task "$tid" "executor" "completed" "$desc"
        return 0
      fi
      local tail hash class
      tail="$(tail -n 40 "$log_file" 2>/dev/null | tr '\n' ' ' | cut -c1-500)"
      classify_error "$tail"
      hash="$ERROR_HASH"; class="$ERROR_TYPE"
      handle_failure "$tail" "$class" "$hash" "apply patch failed"
      ;;
    *)
      set +e
      TASK_ID="$tid" TASK_TYPE="$type" TASK_TARGET="$target" TASK_DESC="$desc" LOG_FILE="$log_file" "${REPO_ROOT}/ai/scripts/ai_harness.sh" >> "$log_file" 2>&1
      local rc=$?
      set -e
      if [ "$rc" -eq 0 ]; then
        set +e
        set_task_status "$tid" "completed" "completed by executor"
        set -e
        executor_log_event "completed" "0" "completed by executor"
        append_last_run "[$ts] ${tid} completed"
        update_current_task "$tid" "executor" "completed" "$desc"
        return 0
      fi
      local tail hash class
      tail="$(tail -n 60 "$log_file" 2>/dev/null | tr '\n' ' ' | cut -c1-500)"
      classify_error "$tail"
      hash="$ERROR_HASH"; class="$ERROR_TYPE"
      handle_failure "$tail" "$class" "$hash" "executor command failed"
      ;;
  esac
}
