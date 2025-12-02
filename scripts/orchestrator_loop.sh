
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BACKLOG_YAML="${BACKLOG_YAML:-ai/backlog.yaml}"
ORCH_CONFIG="${ORCH_CONFIG:-ai/orchestrator/config.yaml}"
MODELS_CONFIG="${MODELS_CONFIG:-ai/orchestrator/models.yaml}"
CURRENT_TASK_FILE="${CURRENT_TASK_FILE:-ai/state/current_task.json}"
METRICS_FILE="${METRICS_FILE:-ai/state/metrics.json}"
LAST_RUN_FILE="${LAST_RUN_FILE:-ai/state/last_run.log}"
LAST_ERROR_FILE="${LAST_ERROR_FILE:-ai/state/last_error.json}"
EXECUTOR_LOG_DIR="${EXECUTOR_LOG_DIR:-logs/executor}"
PATCH_DIR="${PATCH_DIR:-ai/patches}"
EXECUTOR_MAX_RETRIES="${EXECUTOR_MAX_RETRIES:-3}"

mkdir -p "$EXECUTOR_LOG_DIR" ai/state "$PATCH_DIR" ai/orchestrator/lib

err(){ echo "ERROR: $*" >&2; }
die(){ err "$*"; exit 1; }

# shellcheck source=/dev/null
. ai/orchestrator/lib/util_yaml.sh
# shellcheck source=/dev/null
. ai/orchestrator/lib/util_logging.sh
# shellcheck source=/dev/null
. ai/orchestrator/lib/util_patch.sh
# shellcheck source=/dev/null
. ai/orchestrator/lib/util_metrics.sh
# shellcheck source=/dev/null
. ai/orchestrator/lib/util_tasks.sh
# shellcheck source=/dev/null
. ai/orchestrator/error_classifier.sh
# shellcheck source=/dev/null
. ai/orchestrator/lib/persona_executor.sh
# shellcheck source=/dev/null
. ai/orchestrator/lib/persona_engineer.sh
# shellcheck source=/dev/null
. ai/orchestrator/lib/persona_planner.sh

ensure_files() {
  [ -f "$BACKLOG_YAML" ] || die "Missing backlog: $BACKLOG_YAML"
  [ -f "$ORCH_CONFIG" ] || die "Missing orchestrator config: $ORCH_CONFIG"
  [ -f "$MODELS_CONFIG" ] || die "Missing models config: $MODELS_CONFIG"
  [ -f "$CURRENT_TASK_FILE" ] || echo '{"task_id":null,"persona":null,"status":"idle","started_at":null,"note":""}' > "$CURRENT_TASK_FILE"
  [ -f "$METRICS_FILE" ] || echo '{"tasks_completed":0,"tasks_failed":0,"last_run":null,"failure_counts":{}}' > "$METRICS_FILE"
  [ -f "$LAST_ERROR_FILE" ] || echo '{"task_id":null,"persona":null,"command":null,"stderr_tail":null,"error_hash":null,"failure_count":0,"classification":null}' > "$LAST_ERROR_FILE"
  touch "$LAST_RUN_FILE"
}

main_loop() {
  ensure_files
  local max_iterations="${MAX_ITERATIONS:-0}"
  local i=0
  local idle_backoff=5
  while true; do
    if [ "$max_iterations" -gt 0 ] && [ "$i" -ge "$max_iterations" ]; then
      echo "Reached max iterations ($max_iterations); exiting."
      break
    fi

    if ! task_json="$(yaml_next_task "$BACKLOG_YAML")"; then
      last_tid="$(jq -r '.task_id' "$CURRENT_TASK_FILE" 2>/dev/null || true)"
      echo ">>> HEARTBEAT: idle | pending=0 | last_task=${last_tid}"
      sleep "$idle_backoff"
      idle_backoff=$(( idle_backoff < 30 ? idle_backoff * 2 : 30 ))
      continue
    fi
    idle_backoff=5

    tid="$(echo "$task_json" | jq -r '.task_id')"
    type="$(echo "$task_json" | jq -r '.type')"
    target="$(echo "$task_json" | jq -r '.target')"
    desc="$(echo "$task_json" | jq -r '.description')"
    persona="$(echo "$task_json" | jq -r '.persona // "executor"')"

    run_ts="$(date -u +%Y%m%d-%H%M%S)"
    run_log="${EXECUTOR_LOG_DIR}/executor-${run_ts}.log"
    echo "=== Processing task @ ${run_ts} (${tid} :: ${persona}) ===" | tee -a "$run_log"

    case "$persona" in
      executor) persona_executor_handle "$tid" "$type" "$target" "$desc" "$run_ts" "$run_log" ;;
      engineer) persona_engineer_handle "$tid" "$type" "$target" "$desc" "$run_ts" "$run_log" ;;
      planner) persona_planner_handle "$tid" "$type" "$target" "$desc" "$run_ts" "$run_log" ;;
      *) err "Unknown persona $persona"; yaml_update_task "$BACKLOG_YAML" "$tid" "failed" "unknown persona" ;;
    esac

    remaining=$(yaml_count_pending "$BACKLOG_YAML" "executor")
    status="$(jq -r '.status' "$CURRENT_TASK_FILE" 2>/dev/null || true)"
    echo ">>> SUMMARY: ${tid} (${status:-unknown}) | persona: ${persona} | pending executor: ${remaining}"
    i=$((i+1))
    sleep "${LOOP_SLEEP_SECONDS:-5}"
  done
}

main_loop
