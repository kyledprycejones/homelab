#!/usr/bin/env bash
set -euo pipefail

_comment_prefix_for(){
  local path="$1"
  case "$path" in
    *.sh|*.bash|*.env|*.cfg|*.ini) echo "#";;
    *.yaml|*.yml) echo "#";;
    *.md) echo "<!--";;
    *) echo "#";;
  esac
}

engineer_generate_patch(){
  local tid="$1" target="$2" desc="$3" err_tail="$4" err_type="$5"
  local patch_file="${PATCH_DIR}/${tid}.diff"
  local prefix
  prefix=$(_comment_prefix_for "$target")
  local note
  note="${prefix} Engineer note for ${tid}: ${desc}; error_type=${err_type}; tail=${err_tail}"
  if [ ! -f "$target" ]; then
    cat > "$patch_file" <<PATCH
*** Begin Patch
*** Add File: $target
+$note
*** End Patch
PATCH
    echo "$patch_file"
    return
  fi
  # grab first ~120 lines for context (best-effort)
  local tmp_context
  tmp_context=$(python3 - "$target" <<'PY'
import sys
path=sys.argv[1]
lines=open(path,encoding='utf-8').read().splitlines()
print("\n".join(lines[:120]))
PY
)
  cat > "$patch_file" <<PATCH
*** Begin Patch
*** Update File: $target
@@
+$note
*** End Patch
PATCH
  echo "$patch_file"
}

persona_engineer_handle(){
  local tid="$1" type="$2" target="$3" desc="$4" ts="$5" log_file="$6" stage="${7:-0}"
  local allowed forbidden
  allowed=$(yaml_get_persona_config engineer allowed_paths "[]")
  forbidden=$(yaml_get_persona_config engineer forbidden_paths "[]")

  allowed_paths(){
    local path="$1"; local ok=1
    for p in $(echo "$allowed" | jq -r '.[]'); do
      [[ "$path" == "$p"* ]] && ok=0 && break
    done
    if [ "$ok" -ne 0 ]; then return 1; fi
    for f in $(echo "$forbidden" | jq -r '.[]'); do
      [[ "$path" == "$f"* ]] && return 1
    done
    return 0
  }

  engineer_log_event(){
    local status="$1" failure_count="${2:-0}" note="$3"
    log_task_event "$log_file" "$tid" "engineer" "${target:-<none>}" "$status" "$failure_count" "$note"
  }

  engineer_failure(){
    local tail="$1" classification="$2" hash="$3" note="$4"
    local count total next_retry
    count=$(increment_failure_count "$tid" "$hash")
    total=$(total_failure_count "$tid")
    # Engineer retries up to 2 times, then escalates to planner
    if [ "$total" -lt 2 ]; then
      # Still within retry limit - schedule retry
      next_retry=$(( $(date +%s) + 60 * ( total < 10 ? total : 10 ) ))
      set +e
      set_task_status "$tid" "waiting_retry" "engineer retry scheduled" "$next_retry"
      set -e
      engineer_log_event "waiting_retry" "$total" "engineer retry scheduled"
      append_last_run "[$ts] ${tid} waiting_retry (count=${total})"
      update_current_task "$tid" "engineer" "waiting_retry" "$desc"
    else
      # Exceeded retry limit - escalate to planner
      set +e
      set_task_status "$tid" "escalated" "$note"
      set -e
      engineer_log_event "escalated" "$total" "$note"
      local plan_note="Engineer escalation: $note"
      yaml_append_task "$(jq -n --arg id "${tid}-PLAN" --arg target "$target" --arg note "$plan_note" --arg stage "$stage" '{task_id:$id,type:"design",persona:"planner",target:$target,description:$note,status:"pending",metadata:{stage:(try ($stage|tonumber) catch 1)}}')"
      append_last_run "[$ts] ${tid} escalated to planner after ${total} attempts"
      update_current_task "$tid" "engineer" "escalated" "$desc"
    fi
    record_last_error "$tid" "engineer" "$target" "$tail" "$classification" "$count" "$hash"
    return 1
  }

  # Validate task is in a valid starting state
  local current_status
  current_status="$(get_task_status "$tid" 2>/dev/null || echo "")"
  if [ -z "$current_status" ]; then
    engineer_log_event "failed" "0" "task not found in backlog"
    update_current_task "$tid" "engineer" "failed" "$desc"
    append_last_run "[$ts] ${tid} failed (task not found)"
    return 1
  fi
  if [ "$current_status" != "pending" ] && [ "$current_status" != "waiting_retry" ]; then
    engineer_log_event "failed" "0" "task in invalid state: $current_status"
    update_current_task "$tid" "engineer" "failed" "$desc"
    append_last_run "[$ts] ${tid} failed (invalid state: $current_status)"
    return 1
  fi

  set +e
  set_task_status "$tid" "running" "engineer running"
  local transition_rc=$?
  set -e
  if [ "$transition_rc" -ne 0 ]; then
    engineer_log_event "failed" "0" "failed to transition to running (rc=$transition_rc)"
    update_current_task "$tid" "engineer" "failed" "$desc"
    append_last_run "[$ts] ${tid} failed (state transition error)"
    return 1
  fi
  engineer_log_event "running" "0" "$desc"
  update_current_task "$tid" "engineer" "running" "$desc"

  if [ -n "$target" ] && ! allowed_paths "$target"; then
    local guard_hash
    guard_hash="$(printf '%s\n' "$target" | sha256sum | awk '{print $1}')"
    engineer_failure "engineer target guardrail" "engineer" "$guard_hash" "engineer: target not allowed"
    return 1
  fi

  local err_tail err_type err_hash
  err_tail="$(jq -r '.stderr_tail // ""' "$LAST_ERROR_FILE" 2>/dev/null)"
  err_type="$(jq -r '.classification // "unknown"' "$LAST_ERROR_FILE" 2>/dev/null)"
  err_hash="$(jq -r '.error_hash // ""' "$LAST_ERROR_FILE" 2>/dev/null)"

  local patch_file
  set +e
  patch_file=$(engineer_generate_patch "$tid" "$target" "$desc" "$err_tail" "$err_type")
  local patch_rc=$?
  set -e
  if [ "$patch_rc" -ne 0 ] || [ -z "$patch_file" ] || [ ! -s "$patch_file" ]; then
    local failure_note="engineer patch generation failed"
    local failure_tail="${patch_file:-$failure_note}"
    local failure_hash
    failure_hash="$(printf '%s\n' "$failure_note" "$target" | sha256sum | awk '{print $1}')"
    engineer_failure "$failure_tail" "engineer" "$failure_hash" "$failure_note"
    return 1
  fi

  while read -r line; do
    [[ "$line" =~ ^\*\*\*\ (Update|Delete|Add)\ File:\  ]] || continue
    file="${line#*** Update File: }"
    file="${file#*** Delete File: }"
    file="${file#*** Add File: }"
    if ! allowed_paths "$file"; then
      local failure_note="engineer patch touches forbidden path $file"
      local failure_hash
      failure_hash="$(printf '%s\n' "$failure_note" "$file" | sha256sum | awk '{print $1}')"
      engineer_failure "$failure_note" "engineer" "$failure_hash" "$failure_note"
      return 1
    fi
  done < "$patch_file"

  set +e
  set_task_status "$tid" "review" "patch generated"
  set -e
  engineer_log_event "review" "0" "patch generated for review"
  append_planner_task "$tid" "$patch_file" "$stage"
  append_last_run "[$ts] ${tid} patch ready for review"
  update_current_task "$tid" "engineer" "review" "$desc"
}
