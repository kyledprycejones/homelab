#!/usr/bin/env bash
set -euo pipefail

: "${CURRENT_TASK_FILE:=ai/state/CURRENT_TASK_FILE}"
: "${LAST_ERROR_FILE:=ai/state/last_error.json}"
: "${STAGE0_LOG:=ai/logs/stage0.log}"

log_stage0_event(){
  local stage="$1"
  local task_id="$2"
  local persona="$3"
  local result="$4"
  local classification="$5"
  local escalation="$6"
  local note="${7:-}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$STAGE0_LOG")"
  note="${note//$'\n'/ }"
  printf '[%s] stage=%s task=%s persona=%s result=%s classification=%s escalation=%s note=%s\n' \
    "$ts" "$stage" "$task_id" "$persona" "$result" "${classification:-UNKNOWN}" "${escalation:-none}" "${note:-<none>}" >> "$STAGE0_LOG"
}

log_persona_event(){
  local persona="$1"
  local task_id="$2"
  local status="$3"
  local message="$4"
  local log_dir="ai/logs/${persona}"
  mkdir -p "$log_dir"
  local log_file="${log_dir}/${task_id}.log"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  message="${message//$'\n'/ }"
  printf '[%s] task=%s persona=%s status=%s message=%s\n' "$ts" "$task_id" "$persona" "$status" "${message:-<none>}" >> "$log_file"
  echo "$log_file"
}

update_current_task(){
  local task_id="$1"
  local persona="$2"
  local status="$3"
  local note="$4"
  local extras="${5:-null}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$extras" ] && [ "$extras" != "null" ]; then
    jq -n --arg task_id "$task_id" --arg persona "$persona" --arg status "$status" --arg note "$note" --arg updated "$ts" --argjson extras "$extras" \
      '{task_id:$task_id,persona:$persona,status:$status,note:$note,updated_at:$updated} + $extras' > "$CURRENT_TASK_FILE"
  else
    jq -n --arg task_id "$task_id" --arg persona "$persona" --arg status "$status" --arg note "$note" --arg updated "$ts" \
      '{task_id:$task_id,persona:$persona,status:$status,note:$note,updated_at:$updated}' > "$CURRENT_TASK_FILE"
  fi
}

record_last_error(){
  local task_id="$1"
  local persona="$2"
  local command="$3"
  local log_path="$4"
  local stderr_tail="$5"
  local classification="$6"
  local classification_confidence="${7:-low}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$LAST_ERROR_FILE")"
  local signature_source
  signature_source="${stderr_tail:-$classification}"
  if [ -z "$signature_source" ] && [ -f "$log_path" ]; then
    signature_source="$(tail -n 200 "$log_path" 2>/dev/null)"
  fi
  local failure_signature
  failure_signature="sha256:$(printf '%s' "$signature_source" | shasum -a 256 | awk '{print $1}')"
  jq -n --arg task_id "$task_id" --arg persona "$persona" --arg command "$command" --arg log_path "$log_path" \
    --arg stderr "$stderr_tail" --arg classification "$classification" --arg confidence "$classification_confidence" \
    --arg failed_at "$ts" --arg signature "$failure_signature" \
    '{task_id:$task_id,persona:$persona,command:$command,log_path:$log_path,stderr_tail:$stderr,error_classification:$classification,classification_confidence:$confidence,failure_signature:$signature,failed_at:$failed_at}' > "$LAST_ERROR_FILE"
}
