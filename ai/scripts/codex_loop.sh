#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

: "${BACKLOG_YAML:=ai/backlog.yaml}"
: "${CURRENT_TASK_FILE:=ai/state/CURRENT_TASK_FILE}"
: "${ISSUES_FILE:=ai/issues.yaml}"
: "${STAGE_COMPLETE_DIR:=ai/state}"
: "${STAGE0_LOG:=ai/logs/stage0.log}"
: "${STAGE1_BACKLOG_SYNC:=ai/scripts/executor/stage1_backlog_sync.py}"
: "${ORCHESTRATOR_LOOP:=ai/scripts/orchestrator_loop.sh}"
: "${LOOP_SLEEP_SECONDS:=3}"
STAGE="${STAGE:-1}"
export STAGE
STAGE_COMPLETE_MARKER="${STAGE_COMPLETE_DIR}/stage_${STAGE}_complete"

. ai/orchestrator/lib/util_yaml.sh
. ai/orchestrator/lib/util_errors.sh
. ai/orchestrator/lib/util_logging.sh
. ai/orchestrator/lib/util_escalation.sh

ensure_environment(){
  mkdir -p "$(dirname "$CURRENT_TASK_FILE")" "$(dirname "$ISSUES_FILE")" "$STAGE_COMPLETE_DIR" "$(dirname "$STAGE0_LOG")" "ai/logs/planner" "ai/logs/engineer" "ai/logs/executor"
  [ -f "$CURRENT_TASK_FILE" ] || jq -n '{"task_id":null,"persona":null,"status":"idle","note":""}' > "$CURRENT_TASK_FILE"
  if [ ! -s "$ISSUES_FILE" ]; then
    printf 'issues:\n' > "$ISSUES_FILE"
  elif ! grep -q '^issues:' "$ISSUES_FILE"; then
    printf 'issues:\n' >> "$ISSUES_FILE"
  fi
  yaml_ensure_backlog
}

planner_task_pending(){
  python3 - "$BACKLOG_YAML" "$STAGE" <<'PY'
import sys, yaml
path, stage_raw = sys.argv[1:3]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
try:
    stage_int = int(stage_raw)
except Exception:
    stage_int = 0
for entry in data:
    if entry.get("persona") != "planner":
        continue
    if entry.get("status") != "pending":
        continue
    if int(entry.get("stage", 0)) != stage_int:
        continue
    sys.exit(0)
sys.exit(1)
PY
}

task_pending_by_summary(){
  local stage="$1" persona="$2" summary="$3"
  python3 - "$BACKLOG_YAML" "$stage" "$persona" "$summary" <<'PY'
import sys, yaml
path, stage_raw, persona, summary = sys.argv[1:5]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
try:
    stage_int = int(stage_raw)
except Exception:
    stage_int = 0
for entry in data:
    if entry.get("persona") != persona:
        continue
    if entry.get("status") != "pending":
        continue
    if int(entry.get("stage", 0)) != stage_int:
        continue
    if entry.get("summary") == summary:
        sys.exit(0)
sys.exit(1)
PY
}

issue_already_logged(){
  local reason="$1"
  grep -F "$reason" "$ISSUES_FILE" >/dev/null 2>&1
}

append_issue_entry(){
  local reason="$1" hint="$2"
  reason="${reason//$'\n'/ }"
  hint="${hint//$'\n'/ }"
  reason="${reason//\"/\\\"}"
  hint="${hint//\"/\\\"}"
  local ts issue_id
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  issue_id="ISSUE-${ts//[:.-]/}"
  cat <<EOF >> "$ISSUES_FILE"
  - id: "$issue_id"
    timestamp: "$ts"
    persona: planner
    status: stuck
    reason: "$reason"
    hint: "$hint"
EOF
  echo "$issue_id"
}

build_task_payload(){
  local task_id="$1" stage="$2" persona="$3" summary="$4" detail="$5" target="$6" depends="${7:-}" attempts="${8:-0}" max_attempts="${9:-3}"
  jq -n --arg id "$task_id" --arg stage "$stage" --arg persona "$persona" --arg summary "$summary" \
    --arg detail "$detail" --arg target "$target" --arg depends "$depends" --arg attempts "$attempts" --arg max_attempts "$max_attempts" \
    '{
      id: $id,
      stage: ($stage | tonumber? // 0),
      persona: $persona,
      summary: $summary,
      detail: $detail,
      target: $target,
      attempts: ($attempts | tonumber? // 0),
      max_attempts: ($max_attempts | tonumber? // 3),
      status: "pending",
      note: $summary,
      depends_on: ($depends | split(",") | map(select(. != "")))
    }'
}

seed_planner_task(){
  local issue_id="$1"
  local summary="Backlog empty; Planner must generate next work"
  local detail="Review ai/master_memo.txt, ai/memos/master_memo_orchestrator.txt, and ai/issues.yaml entry ${issue_id} for architecture context; propose the next action for stage ${STAGE}."
  local payload
  payload="$(build_task_payload "PLANNER-${issue_id}" "$STAGE" "planner" "$summary" "$detail" "ai/master_memo.txt" "" 0 3)"
  yaml_append_task "$payload"
}

sync_backlog(){
  if [ -f "$STAGE1_BACKLOG_SYNC" ]; then
    python3 "$STAGE1_BACKLOG_SYNC" >/dev/null 2>&1 || true
  fi
}

is_architectural_error(){
  case "${1:-}" in
    ERR_TALOS_KUBECONFIG_MISSING) return 0 ;;
    *) return 1 ;;
  esac
}

create_planner_escalation(){
  local parent="$1" classification="$2" stage_id="$3"
  local summary="Structural failure in executor task ${parent}"
  if task_pending_by_summary "$stage_id" "planner" "$summary"; then
    return
  fi
  local detail
  detail=$'Executor exhausted retries and error_class=${classification}.\nPlanner must consult master_memo_orchestrator.txt + ai/master_memo.txt + logs and determine next tasks.'
  local task_id="PLAN-$(date -u +%Y%m%dT%H%M%SZ)"
  local payload
  payload="$(build_task_payload "$task_id" "$stage_id" "planner" "$summary" "$detail" "ai/master_memo.txt" "$parent" 0 1)"
  yaml_append_task "$payload"
  echo "planner"
}

create_engineer_escalation(){
  local parent="$1" classification="$2" stage_id="$3" target="$4"
  local summary="Fix failure in ${parent}"
  if task_pending_by_summary "$stage_id" "engineer" "$summary"; then
    return
  fi
  local existing_id
  existing_id="$(engineer_task_for_parent "$parent" "$stage_id" 2>/dev/null || true)"
  if [ -n "$existing_id" ]; then
    echo "engineer"
    return
  fi
  local detail
  detail="Executor failed with error_class=${classification}. Engineer must produce minimal diffs only."
  local base_id="${parent%-*}"
  local task_id="${base_id}-ENGINEER-FIX"
  local payload
  payload="$(build_task_payload "$task_id" "$stage_id" "engineer" "$summary" "$detail" "$target" "$parent" 0 2)"
  yaml_append_task "$payload"
  echo "engineer"
}

handle_empty_backlog(){
  if [ -f "$STAGE_COMPLETE_MARKER" ]; then
    log_stage0_event "$STAGE" "<none>" "stage0" "idle" "ERR_UNKNOWN" "none" "Stage ${STAGE} already complete"
    sleep "$LOOP_SLEEP_SECONDS"
    return
  fi
  if planner_task_pending; then
    sleep "$LOOP_SLEEP_SECONDS"
    return
  fi
  local reason="Backlog empty for stage ${STAGE}; awaiting planner direction."
  local hint="Consult ai/master_memo.txt, ai/issues.yaml, and failing logs."
  if issue_already_logged "$reason"; then
    sleep "$LOOP_SLEEP_SECONDS"
    return
  fi
  local issue_id
  issue_id="$(append_issue_entry "$reason" "$hint")"
  seed_planner_task "$issue_id"
  sleep "$LOOP_SLEEP_SECONDS"
}

ensure_environment

log_loop(){
  local stage="$1"
  local task_id="$2"
  local persona="$3"
  local status="$4"
  local attempts="$5"
  local escalation_note="$6"
  local classification="${7:-UNKNOWN}"
  local note="${8:-}"
  log_stage0_event "$stage" "$task_id" "$persona" "$status" "$classification" "$escalation_note" "${note:-}"
  local ts
  ts="$(date -u +%H:%M:%SZ)"
  printf '[STAGE-0] cycle=%s stage=%s next_task=%s persona=%s status=%s attempts=%s escalation=%s\n' \
    "$ts" "$stage" "$task_id" "$persona" "$status" "$attempts" "${escalation_note:-none}"
}

while true; do
  sync_backlog
  if ! task_json="$(yaml_next_task "$STAGE" 2>/dev/null)"; then
    handle_empty_backlog
    continue
  fi
  task_id="$(echo "$task_json" | jq -r '.id')"
  persona="$(echo "$task_json" | jq -r '.persona')"
  summary="$(echo "$task_json" | jq -r '.summary')"
  detail="$(echo "$task_json" | jq -r '.detail')"
  target="$(echo "$task_json" | jq -r '.target // ""')"
  stage_num="$(echo "$task_json" | jq -r '.stage // 0')"
  attempts="$(echo "$task_json" | jq -r '.attempts // 0')"
  max_attempts="$(echo "$task_json" | jq -r '.max_attempts // 3')"

  update_current_task "$task_id" "$persona" "running" "$summary" "{\"stage\":$stage_num,\"target\":\"$target\"}"

  set +e
  "$ORCHESTRATOR_LOOP"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    log_stage0_event "$STAGE" "$task_id" "$persona" "error" "ERR_UNKNOWN" "none" "orchestrator loop failed"
  fi

  current_status="$(jq -r '.status // "unknown"' "$CURRENT_TASK_FILE")"
  note="$(jq -r '.note // ""' "$CURRENT_TASK_FILE")"
  log_path="$(jq -r '.log_path // ""' "$CURRENT_TASK_FILE")"
  log_path="${log_path:-ai/logs/executor/${task_id}.log}"
  final_status="$current_status"
  final_note="$note"
  final_classification=""
  escalation="none"
  final_attempts="$attempts"

  if [ "$persona" = "executor" ] && [ "$current_status" = "failed" ]; then
    final_classification="$(classify_error "$log_path")"
    attempts_next=$((attempts + 1))
    yaml_update_task "$task_id" "{\"attempts\":$attempts_next}"
    if [ "$attempts_next" -lt "$max_attempts" ]; then
      yaml_update_task "$task_id" "{\"status\":\"pending\",\"note\":\"Retry attempt ${attempts_next}\"}"
      final_status="pending"
      final_note="Retry attempt ${attempts_next}"
    else
      new_escalation=""
      if is_architectural_error "$final_classification"; then
        new_escalation="$(create_planner_escalation "$task_id" "$final_classification" "$stage_num")"
      else
        new_escalation="$(create_engineer_escalation "$task_id" "$final_classification" "$stage_num" "$target")"
      fi
      if [ -n "$new_escalation" ]; then
        escalation="$new_escalation"
      fi
      yaml_update_task "$task_id" "{\"status\":\"blocked\",\"note\":\"Blocked after ${attempts_next} failures\"}"
      final_status="blocked"
      final_note="Blocked after ${attempts_next} failures"
    fi
    final_attempts="$attempts_next"
  fi

  final_classification="${final_classification:-UNKNOWN}"
  extras="$(jq -n --arg stage "$stage_num" --arg target "$target" --arg log_path "$log_path" --arg classification "$final_classification" '{stage:(($stage|tonumber?)//0),target:$target,log_path:$log_path,error_classification:$classification}')"
  update_current_task "$task_id" "$persona" "$final_status" "$final_note" "$extras"
  log_loop "$STAGE" "$task_id" "$persona" "$final_status" "$final_attempts" "$escalation" "$final_classification" "$final_note"
  sleep "$LOOP_SLEEP_SECONDS"
done
