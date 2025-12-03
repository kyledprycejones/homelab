#!/usr/bin/env bash
set -euo pipefail

# This is the Stage 0 Codex orchestrator entrypoint.
# It loops until the backlog is empty.
# It wraps orchestrator_loop.sh.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BACKLOG_YAML="${BACKLOG_YAML:-ai/backlog.yaml}"
CURRENT_TASK_FILE="${CURRENT_TASK_FILE:-ai/state/current_task.json}"
METRICS_FILE="${METRICS_FILE:-ai/state/metrics.json}"
LAST_RUN_FILE="${LAST_RUN_FILE:-ai/state/last_run.log}"
ORCHESTRATOR_LOOP="${ORCHESTRATOR_LOOP:-${REPO_ROOT}/ai/scripts/orchestrator_loop.sh}"
LOG_DIR="${LOG_DIR:-logs/executor}"
STAGE1_BACKLOG_SYNC="${STAGE1_BACKLOG_SYNC:-${REPO_ROOT}/ai/scripts/executor/stage1_backlog_sync.py}"
STAGE1_BACKLOG_SYNC_LOG="${STAGE1_BACKLOG_SYNC_LOG:-${LOG_DIR}/stage1-backlog-sync.log}"
LOOP_SLEEP_SECONDS="${LOOP_SLEEP_SECONDS:-3}"
STAGE="${STAGE:-0}"
export STAGE

err(){ echo "ERROR: $*" >&2; }
die(){ err "$*"; exit 1; }

ensure_state_files(){
  mkdir -p "$(dirname "$CURRENT_TASK_FILE")"
  [ -f "$CURRENT_TASK_FILE" ] || echo '{"task_id":null,"persona":null,"status":"idle","started_at":null,"note":""}' > "$CURRENT_TASK_FILE"
  [ -f "$METRICS_FILE" ] || echo '{"tasks_completed":0,"tasks_failed":0,"last_run":null,"failure_counts":{},"failure_totals":{}}' > "$METRICS_FILE"
  [ -f "$LAST_RUN_FILE" ] || touch "$LAST_RUN_FILE"
}

ensure_environment(){
  [ -f "$BACKLOG_YAML" ] || die "Missing backlog: $BACKLOG_YAML"
  [ -f "$ORCHESTRATOR_LOOP" ] || die "Missing orchestrator loop: $ORCHESTRATOR_LOOP"
  [ -f "$STAGE1_BACKLOG_SYNC" ] || die "Missing stage1 backlog sync: $STAGE1_BACKLOG_SYNC"
  ensure_state_files
  mkdir -p "$LOG_DIR" "$(dirname "$STAGE1_BACKLOG_SYNC_LOG")"
}

ensure_environment

# shellcheck source=/dev/null
. ai/orchestrator/lib/util_yaml.sh

populate_stage1_backlog(){
  local stamp sync_output
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if sync_output="$(python3 "$STAGE1_BACKLOG_SYNC" 2>&1)"; then
    if printf '%s' "$sync_output" | grep -q 'SYNC: changed'; then
      {
        printf '[%s] Stage 1 backlog sync applied changes\n' "$stamp"
        printf '%s\n' "$sync_output"
      } >> "$STAGE1_BACKLOG_SYNC_LOG"
    fi
    return 0
  fi
  {
    printf '[%s] Stage 1 backlog sync failed\n' "$stamp"
    printf '%s\n' "$sync_output"
  } >> "$STAGE1_BACKLOG_SYNC_LOG"
  err "Stage 1 backlog sync failed; see $STAGE1_BACKLOG_SYNC_LOG"
  return 1
}

main(){
  local iteration=0
  populate_stage1_backlog

  while true; do
    local task_json
    if ! task_json="$(yaml_next_task "$BACKLOG_YAML")"; then
      populate_stage1_backlog || break
      if ! task_json="$(yaml_next_task "$BACKLOG_YAML")"; then
        echo "Backlog empty; exiting Codex loop."
        break
      fi
    fi

    local task_id type target desc persona task_stage
    task_id="$(echo "$task_json" | jq -r '.task_id')"
    type="$(echo "$task_json" | jq -r '.type // "run"')"
    target="$(echo "$task_json" | jq -r '.target // ""')"
    desc="$(echo "$task_json" | jq -r '.description // ""')"
    persona="$(echo "$task_json" | jq -r '.persona // "executor"')"
    task_stage="$(echo "$task_json" | jq -r '.metadata.stage // "0"')"

    local run_ts log_file
    run_ts="$(date -u +%Y%m%d-%H%M%S)"
    log_file="${LOG_DIR}/executor-${run_ts}.log"
    mkdir -p "$(dirname "$log_file")"
    echo "=== [${run_ts}] Starting ${task_id} (${persona}) ===" | tee -a "$log_file"

    LOG_FILE="$log_file" "$ORCHESTRATOR_LOOP" "$task_id" "$type" "$target" "$desc" "$persona" "$task_stage"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
      err "Task ${task_id} exited with ${rc}; see ${log_file}"
    fi

    local pending
    pending="$(yaml_count_pending "$BACKLOG_YAML" "executor")"
    echo ">>> Remaining executor-backlog tasks: ${pending}"

    iteration=$((iteration + 1))
    sleep "$LOOP_SLEEP_SECONDS"
  done
}

main
