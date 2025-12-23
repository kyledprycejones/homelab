#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

. ai/orchestrator/lib/util_yaml.sh
. ai/orchestrator/lib/util_logging.sh
. ai/orchestrator/lib/util_errors.sh
. ai/orchestrator/lib/util_tasks.sh

# Local helper: wraps yaml_update_task for persona-specific status updates
# Note: set_task_status enforces reserved states and valid transitions.
set_backlog_status(){
  local tid="$1" state="$2" note="$3"
  set_task_status "$tid" "$state" "$note"
}

main(){
  if [ "$#" -lt 1 ]; then
    echo "Usage: persona_executor.sh TASK_ID" >&2
    exit 1
  fi
  local task_id="$1"
  local task_json
  task_json="$(yaml_get_task "$task_id")" || { echo "Executor task $task_id missing" >&2; exit 1; }
  local summary detail target stage_num
  summary="$(echo "$task_json" | jq -r '.summary // "executor task"')"
  detail="$(echo "$task_json" | jq -r '.detail // ""')"
  target="$(echo "$task_json" | jq -r '.target // ""')"
  stage_num="$(echo "$task_json" | jq -r '.stage // 1')"

  mkdir -p "ai/logs/executor"
  local log_file="ai/logs/executor/${task_id}-$(date -u +%Y%m%dT%H%M%SZ).log"
  log_persona_event "executor" "$task_id" "running" "$summary" >/dev/null
  set_backlog_status "$task_id" "running" "$summary"
  update_current_task "$task_id" "executor" "running" "$summary" "{\"stage\":$stage_num,\"target\":\"$target\",\"log_path\":\"$log_file\"}"

  if [ -z "$target" ]; then
    local note="Executor task missing target"
    set_backlog_status "$task_id" "failed" "$note"
    echo "[executor] ${note}" >> "$log_file"
    update_current_task "$task_id" "executor" "failed" "$note" "{\"log_path\":\"$log_file\",\"error_classification\":\"ERR_UNKNOWN\",\"classification_confidence\":\"low\"}"
    log_persona_event "executor" "$task_id" "failed" "$note"
    exit 0
  fi

  set +e
  TASK_ID="$task_id" TASK_STAGE="$stage_num" TASK_TARGET="$target" TASK_DETAIL="$detail" LOG_FILE="$log_file" ai/scripts/ai_harness.sh >> "$log_file" 2>&1
  local rc=$?
  set -e

  local stderr_tail
  stderr_tail="$(tail -n 60 "$log_file" 2>/dev/null | tr '\n' ' ' | head -c 500)"
  local classification
  classification="$(classify_error "$log_file")"
  local classification_confidence="${CLASSIFICATION_CONFIDENCE:-low}"

  if [ "$rc" -eq 0 ]; then
    local note="Executor succeeded"
    set_backlog_status "$task_id" "success" "$note"
    update_current_task "$task_id" "executor" "success" "$note" "{\"log_path\":\"$log_file\",\"error_classification\":\"$classification\",\"classification_confidence\":\"$classification_confidence\"}"
    log_persona_event "executor" "$task_id" "success" "$note"
    exit 0
  fi

  local note="Executor failed (rc=$rc)"
  set_backlog_status "$task_id" "failed" "$note"
  update_current_task "$task_id" "executor" "failed" "$note" "{\"log_path\":\"$log_file\",\"error_classification\":\"$classification\",\"classification_confidence\":\"$classification_confidence\"}"
  record_last_error "$task_id" "executor" "$target" "$log_file" "$stderr_tail" "$classification" "$classification_confidence"
  log_persona_event "executor" "$task_id" "failed" "$note"
}

main "$@"
