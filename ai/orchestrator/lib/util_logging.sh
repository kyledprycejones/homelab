#!/usr/bin/env bash
set -euo pipefail

append_last_run(){ echo "$1" >> "$LAST_RUN_FILE"; }

update_current_task(){
  local tid="$1" persona="$2" status="$3" note="$4"
  jq -n --arg t "$tid" --arg p "$persona" --arg s "$status" --arg n "$note" '{task_id:$t,persona:$p,status:$s,started_at:(now|tostring),note:$n}' > "$CURRENT_TASK_FILE"
}

record_last_error(){
  local tid="$1" persona="$2" cmd="$3" stderr_tail="$4" classification="$5" count="$6" hash="$7"
  jq -n --arg t "$tid" --arg p "$persona" --arg c "$cmd" --arg e "$stderr_tail" --arg cl "$classification" --arg h "$hash" --argjson fc "$count" '{task_id:$t,persona:$p,command:$c,stderr_tail:$e,error_hash:$h,failure_count:$fc,classification:$cl}' > "$LAST_ERROR_FILE"
}
