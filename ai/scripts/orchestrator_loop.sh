#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BACKLOG_YAML="${BACKLOG_YAML:-ai/backlog.yaml}"
ORCH_CONFIG="${ORCH_CONFIG:-ai/config/config.yaml}"
MODELS_CONFIG="${MODELS_CONFIG:-ai/config/models.yaml}"
CURRENT_TASK_FILE="${CURRENT_TASK_FILE:-ai/state/current_task.json}"
METRICS_FILE="${METRICS_FILE:-ai/state/metrics.json}"
LAST_RUN_FILE="${LAST_RUN_FILE:-ai/state/last_run.log}"
LAST_ERROR_FILE="${LAST_ERROR_FILE:-ai/state/last_error.json}"
PATCH_DIR="${PATCH_DIR:-ai/patches}"
LOG_DIR="${LOG_DIR:-logs/executor}"
STAGE="${STAGE:-0}"
export STAGE

err(){ echo "ERROR: $*" >&2; }
die(){ err "$*"; exit 1; }

ensure_state_files(){
  mkdir -p "$(dirname "$CURRENT_TASK_FILE")" "$PATCH_DIR" "$LOG_DIR"
  [ -f "$CURRENT_TASK_FILE" ] || echo '{"task_id":null,"persona":null,"status":"idle","started_at":null,"note":""}' > "$CURRENT_TASK_FILE"
  [ -f "$METRICS_FILE" ] || echo '{"tasks_completed":0,"tasks_failed":0,"last_run":null,"failure_counts":{}}' > "$METRICS_FILE"
  [ -f "$LAST_RUN_FILE" ] || touch "$LAST_RUN_FILE"
  [ -f "$LAST_ERROR_FILE" ] || echo '{"task_id":null,"persona":null,"command":null,"stderr_tail":null,"error_hash":null,"failure_count":0,"classification":null}' > "$LAST_ERROR_FILE"
}

validate_environment(){
  [ -f "$BACKLOG_YAML" ] || die "Missing backlog: $BACKLOG_YAML"
  [ -f "$ORCH_CONFIG" ] || die "Missing orchestrator config: $ORCH_CONFIG"
  [ -f "$MODELS_CONFIG" ] || die "Missing models config: $MODELS_CONFIG"
  ensure_state_files
}

validate_environment

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

if [ "$#" -lt 4 ]; then
  die "Usage: $(basename "$0") TASK_ID TASK_TYPE TASK_TARGET TASK_DESC [PERSONA]"
fi

TASK_ID="$1"
TASK_TYPE="$2"
TASK_TARGET="$3"
TASK_DESC="$4"
PERSONA="${5:-executor}"
TASK_STAGE="${6:-0}"

LOG_FILE="${LOG_FILE:-${LOG_DIR}/executor-$(date -u +%Y%m%d-%H%M%S).log}"
mkdir -p "$(dirname "$LOG_FILE")"

run_ts="$(date -u +%Y%m%d-%H%M%S)"
run_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log_line(){ printf "%s\n" "$1" | tee -a "$LOG_FILE"; }

log_line "=== Starting ${TASK_ID} (${PERSONA}) @ ${run_ts} ==="

handler_rc=0
set +e
case "$PERSONA" in
  executor)
    persona_executor_handle "$TASK_ID" "$TASK_TYPE" "$TASK_TARGET" "$TASK_DESC" "$run_iso" "$LOG_FILE" "$TASK_STAGE"
    handler_rc=$?
    ;;
  engineer)
    persona_engineer_handle "$TASK_ID" "$TASK_TYPE" "$TASK_TARGET" "$TASK_DESC" "$run_iso" "$LOG_FILE" "$TASK_STAGE"
    handler_rc=$?
    ;;
  planner)
    persona_planner_handle "$TASK_ID" "$TASK_TYPE" "$TASK_TARGET" "$TASK_DESC" "$run_iso" "$LOG_FILE" "$TASK_STAGE"
    handler_rc=$?
    ;;
  *)
    log_line "Unknown persona ${PERSONA}; skipping ${TASK_ID}"
    # Use set_task_status with validation bypass for unknown persona (special case)
    if yaml_task_exists "$TASK_ID"; then
      SKIP_VALIDATION=1 set_task_status "$TASK_ID" "failed" "unknown persona"
    fi
    update_current_task "$TASK_ID" "$PERSONA" "failed" "$TASK_DESC"
    append_last_run "[$run_iso] ${TASK_ID} failed (unknown persona)"
    handler_rc=1
    ;;
esac

backlog_present=0
if yaml_task_exists "$TASK_ID"; then
  backlog_present=1
fi

current_status="$(jq -r '.status // "unknown"' "$CURRENT_TASK_FILE" 2>/dev/null || echo "unknown")"
current_persona="$(jq -r '.persona // "unknown"' "$CURRENT_TASK_FILE" 2>/dev/null || echo "unknown")"
# Valid final states: completed, failed, escalated, review, blocked, waiting_retry
# Invalid final states: idle, unknown, running (persona should have set a final state)
if [ -z "$current_status" ] || [ "$current_status" = "idle" ] || [ "$current_status" = "unknown" ] || [ "$current_status" = "running" ]; then
  log_line "[WARN] Persona ${PERSONA} did not finalize ${TASK_ID} (status=${current_status})"
  if [ "$backlog_present" -eq 1 ]; then
    # Use set_task_status with validation bypass for this error case
    SKIP_VALIDATION=1 set_task_status "$TASK_ID" "failed" "persona did not complete properly"
  fi
  update_current_task "$TASK_ID" "$PERSONA" "failed" "$TASK_DESC"
  append_last_run "[$run_iso] ${TASK_ID} failed (persona did not complete properly)"
  handler_rc=1
elif [ "$current_persona" != "$PERSONA" ]; then
  log_line "[WARN] Persona mismatch: expected ${PERSONA}, got ${current_persona}"
  handler_rc=1
fi

if [ "$backlog_present" -eq 0 ]; then
  log_line "[WARN] Backlog entry missing; marking failed"
  append_last_run "[$run_iso] ${TASK_ID} missing from backlog"
  handler_rc=1
fi

set -euo pipefail


final_status="$(jq -r '.status // "unknown"' "$CURRENT_TASK_FILE" 2>/dev/null || echo "unknown")"

update_metrics_status(){
  local status="$1" timestamp="$2"
  python3 - "$METRICS_FILE" "$status" "$timestamp" <<'PY'
import json, os, sys
path, status, timestamp = sys.argv[1:]
base = {"tasks_completed":0,"tasks_failed":0,"last_run":None,"failure_counts":{}}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            base.update(json.load(f))
    except Exception:
        pass
increment = 0
if status == "completed":
    base["tasks_completed"] = base.get("tasks_completed", 0) + 1
elif status in {"failed","blocked"}:
    base["tasks_failed"] = base.get("tasks_failed", 0) + 1
base["last_run"] = timestamp
with open(path, "w", encoding="utf-8") as f:
    json.dump(base, f, indent=2)
PY
}

update_metrics_status "$final_status" "$run_iso"
append_last_run "[$run_iso] ${TASK_ID} ended with ${final_status}"
log_line "=== ${TASK_ID} -> ${final_status} ==="
exit "$handler_rc"
