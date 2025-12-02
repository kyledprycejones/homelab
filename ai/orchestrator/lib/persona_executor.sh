#!/usr/bin/env bash
set -euo pipefail

persona_executor_handle(){
  local tid="$1" type="$2" target="$3" desc="$4" ts="$5" log_file="$6"

  # Load executor config
  local allowed forbidden max_retries
  allowed=$(yaml_get_persona_config executor allowed_paths "[]")
  forbidden=$(yaml_get_persona_config executor forbidden_paths "[]")
  max_retries=$(yaml_get_persona_config executor max_retries 3 | jq -r '.')

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

  if [ -n "$target" ] && ! path_allowed "$target"; then
    set_task_status "$tid" "failed" "executor: target not allowed"
    update_current_task "$tid" "executor" "failed" "$desc"
    append_last_run "[$ts] ${tid} failed (target not allowed)"
    return 1
  fi

  case "$type" in
    apply_patch)
      if [ ! -s "$target" ]; then
        set_task_status "$tid" "failed" "patch missing or empty"
        update_current_task "$tid" "executor" "failed" "$desc"
        append_last_run "[$ts] ${tid} failed (missing patch)"
        return 1
      fi
      # Optional: ensure patch touches only allowed paths
      while read -r line; do
        [[ "$line" =~ ^\*\*\*\ Update\ File:\  ]] || continue
        file="${line#*** Update File: }"
        if ! path_allowed "$file"; then
          set_task_status "$tid" "failed" "patch touches forbidden path"
          update_current_task "$tid" "executor" "failed" "$desc"
          append_last_run "[$ts] ${tid} failed (forbidden path in patch)"
          return 1
        fi
      done < "$target"
      set_task_status "$tid" "running"
      update_current_task "$tid" "executor" "running" "$desc"
      if apply_patch_file "$target" "$log_file"; then
        set_task_status "$tid" "completed" "patch applied"
        append_last_run "[$ts] ${tid} applied patch"
        update_current_task "$tid" "executor" "completed" "$desc"
        return 0
      else
        local tail hash class count
        tail="$(tail -n 40 "$log_file" 2>/dev/null | tr '\n' ' ' | cut -c1-500)"
        classify_error "$tail"
        hash="$ERROR_HASH"; class="$ERROR_TYPE"
        count=$(increment_failure_count "$tid" "$hash")
        set_task_status "$tid" "failed" "apply patch failed"
        record_last_error "$tid" "executor" "$target" "$tail" "$class" "$count" "$hash"
        append_last_run "[$ts] ${tid} failed apply"
        update_current_task "$tid" "executor" "failed" "$desc"
        return 1
      fi
      ;;

    *)
      set_task_status "$tid" "running"
      update_current_task "$tid" "executor" "running" "$desc"
      set +e
      TASK_ID="$tid" TASK_TYPE="$type" TASK_TARGET="$target" TASK_DESC="$desc" LOG_FILE="$log_file" "${REPO_ROOT}/scripts/ai_harness.sh" >> "$log_file" 2>&1
      rc=$?
      set -e
      if [ "$rc" -eq 0 ]; then
        set_task_status "$tid" "completed" "completed by executor"
        append_last_run "[$ts] ${tid} completed"
        update_current_task "$tid" "executor" "completed" "$desc"
        return 0
      fi
      local tail hash class count
      tail="$(tail -n 60 "$log_file" 2>/dev/null | tr '\n' ' ' | cut -c1-500)"
      classify_error "$tail"
      hash="$ERROR_HASH"; class="$ERROR_TYPE"
      count=$(increment_failure_count "$tid" "$hash")
      if [ "$count" -lt "$max_retries" ]; then
        local next_retry=$(( $(date +%s) + 60 * ( count < 10 ? count : 10 ) ))
        set_task_status "$tid" "waiting_retry" "executor retry scheduled" "$next_retry"
        append_last_run "[$ts] ${tid} waiting_retry (count=$count)"
        update_current_task "$tid" "executor" "waiting_retry" "$desc"
      else
        set_task_status "$tid" "blocked" "escalated after failures"
        append_engineer_task "$tid" "$target" "$tail"
        append_last_run "[$ts] ${tid} blocked -> engineer"
        update_current_task "$tid" "executor" "blocked" "$desc"
      fi
      record_last_error "$tid" "executor" "$target" "$tail" "$class" "$count" "$hash"
      return "$rc"
      ;;
  esac
}
