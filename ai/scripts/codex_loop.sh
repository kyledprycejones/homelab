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
: "${STATUS_FILE:=ai/state/status.json}"
: "${LOOP_SLEEP_SECONDS:=3}"
: "${LINT_BACKLOG_SCRIPT:=ai/scripts/lint_backlog.sh}"
: "${BACKLOG_VALIDATOR:=ai/scripts/validate_backlog_yaml.sh}"
: "${DEADLOCK_THROTTLE_FILE:=ai/state/deadlock_throttle.json}"
: "${DEADLOCK_COOLDOWN_SECONDS:=60}"
STAGE="${STAGE:-1}"
export STAGE
STAGE_COMPLETE_MARKER="${STAGE_COMPLETE_DIR}/stage_${STAGE}_complete"

. ai/orchestrator/lib/util_yaml.sh
. ai/orchestrator/lib/util_errors.sh
. ai/orchestrator/lib/util_logging.sh
. ai/orchestrator/lib/util_inventory.sh
. ai/orchestrator/lib/util_tasks.sh

ensure_environment(){
  mkdir -p "$(dirname "$CURRENT_TASK_FILE")" "$(dirname "$ISSUES_FILE")" "$STAGE_COMPLETE_DIR" "$(dirname "$STAGE0_LOG")" "ai/logs/planner" "ai/logs/executor"
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

deadlock_should_log(){
  local signature="$1"
  python3 - "$DEADLOCK_THROTTLE_FILE" "$signature" "$DEADLOCK_COOLDOWN_SECONDS" <<'PY'
import json
import os
import sys
import time

path, signature, cooldown = sys.argv[1:4]
cooldown = int(cooldown)
now = int(time.time())
data = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh) or {}
    except Exception:
        data = {}
last_logged = int(data.get(signature, 0) or 0)
should_log = (now - last_logged) >= cooldown
if should_log:
    data[signature] = now
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp_path = path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, sort_keys=True)
    os.replace(tmp_path, path)
print("1" if should_log else "0")
PY
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
  local detail="Review docs/master_memo.txt and ai/issues.yaml entry ${issue_id} for architecture context; propose the next action for stage ${STAGE}."
  local payload
  payload="$(build_task_payload "PLANNER-${issue_id}" "$STAGE" "planner" "$summary" "$detail" "docs/master_memo.txt" "" 0 3)"
  yaml_append_task "$payload"
}

validate_backlog_yaml(){
  if "$BACKLOG_VALIDATOR" "$BACKLOG_YAML"; then
    return 0
  fi
  local note="P0: invalid ai/backlog.yaml; review $(basename "$BACKLOG_VALIDATOR") output"
  log_stage0_event "$STAGE" "<none>" "stage0" "error" "ERR_INVALID_BACKLOG" "none" "$note"
  echo "$note" >&2
  exit 2
}

run_backlog_lint(){
  if "$LINT_BACKLOG_SCRIPT" "$BACKLOG_YAML"; then
    return 0
  fi
  local note="P0: ai/scripts/lint_backlog.sh failed; backlog requires fixing"
  log_stage0_event "$STAGE" "<none>" "stage0" "error" "ERR_LINT_BACKLOG" "none" "$note"
  echo "$note" >&2
  exit 2
}

last_error_classification(){
  if [ ! -f "ai/state/last_error.json" ]; then
    echo ""
    return
  fi
  jq -r '.error_classification // ""' "ai/state/last_error.json" 2>/dev/null || echo ""
}

ensure_proxmox_inventory_task(){
  local stage="${1:-$STAGE}"
  local inventory_id
  inventory_id="$(inventory_task_id "$stage")"
  if yaml_task_exists "$inventory_id"; then
    return 1
  fi
  local payload
  payload="$(inventory_task_payload "$stage")"
  yaml_append_task "$payload"
  return 0
}

append_executor_task_if_missing(){
  local task_id="$1"
  local payload="$2"
  if yaml_task_exists "$task_id"; then
    return 1
  fi
  yaml_append_task "$payload"
  return 0
}

is_vm_provisioning_classification(){
  case "$1" in
    ERR_CONFIG_MISSING_CTRL_IP|ERR_PREREQ_MISSING_VMS) return 0 ;;
    *) return 1 ;;
  esac
}

queue_vm_provisioning_tasks(){
  local stage="$1"
  local classification="$2"
  local triggering_task="$3"
  local appended=0
  local inventory_id provision_id resolve_id
  inventory_id="$(inventory_task_id "$stage")"
  provision_id="$(provision_task_id "$stage")"
  resolve_id="$(resolve_ctrl_ip_task_id "$stage")"
  if append_executor_task_if_missing "$inventory_id" "$(inventory_task_payload "$stage")"; then
    appended=$((appended + 1))
  fi
  if append_executor_task_if_missing "$provision_id" "$(provision_task_payload "$stage")"; then
    appended=$((appended + 1))
  fi
  if append_executor_task_if_missing "$resolve_id" "$(resolve_ctrl_ip_task_payload "$stage")"; then
    appended=$((appended + 1))
  fi
  local note
  if [ "$appended" -gt 0 ]; then
    note="VM provisioning queued (stage S${stage})"
  else
    note="VM provisioning already queued (stage S${stage})"
  fi
  log_stage0_event "$stage" "$triggering_task" "executor" "blocked" "$classification" "inventory-provision" "$note"
  return 0
}

sync_backlog(){
  if [ -f "$STAGE1_BACKLOG_SYNC" ]; then
    python3 "$STAGE1_BACKLOG_SYNC" >/dev/null 2>&1 || true
  fi
}

create_planner_escalation(){
  local parent="$1" classification="$2" stage_id="$3"
  local summary="Planner recovery for ${parent}"
  local existing
  existing="$(python3 - "$BACKLOG_YAML" "$parent" "$stage_id" <<'PY'
import sys, yaml
path, parent, stage_raw = sys.argv[1:4]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
try:
    stage_int = int(stage_raw)
except Exception:
    stage_int = 0
for entry in data:
    if entry.get("persona") != "planner":
        continue
    try:
        entry_stage = int(entry.get("stage", 0))
    except Exception:
        entry_stage = 0
    if entry_stage != stage_int:
        continue
    depends = entry.get("depends_on") or []
    if parent in depends:
        print(entry.get("id"))
        sys.exit(0)
sys.exit(1)
PY
  )" || true
  if [ -n "$existing" ]; then
    echo "planner"
    return
  fi
  local detail
  detail="Executor exhausted retries with classification=${classification}; planner must read ai/state/last_error.json and synthesize recovery tasks (RECONCILE, DELETE/RESET, APPLY, VALIDATE)."
  local task_id="${parent}-PLANNER-RECOVERY"
  local payload
  payload="$(build_task_payload "$task_id" "$stage_id" "planner" "$summary" "$detail" "docs/orchestrator_v7_2.txt" "$parent" 0 1)"
  yaml_append_task "$payload"
  echo "planner"
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
  local hint="Consult docs/master_memo.txt, ai/issues.yaml, and failing logs."
  if issue_already_logged "$reason"; then
    sleep "$LOOP_SLEEP_SECONDS"
    return
  fi
  local issue_id
  issue_id="$(append_issue_entry "$reason" "$hint")"
  seed_planner_task "$issue_id"
  sleep "$LOOP_SLEEP_SECONDS"
}

handle_deadlock_if_needed(){
  local stage="$1"
  local report
  if ! report="$(yaml_deadlock_report "$stage" 2>/dev/null)"; then
    return 1
  fi
  local blocked_summary top_blocker_summary signature
  blocked_summary="$(printf '%s' "$report" | jq -r '.blocked_summary')"
  top_blocker_summary="$(printf '%s' "$report" | jq -r '.top_blocker_summary // ""')"
  signature="$(printf '%s' "$report" | jq -r '.signature // ""')"
  if [ -z "$top_blocker_summary" ] || [ "$top_blocker_summary" = "null" ]; then
    top_blocker_summary="$blocked_summary"
  fi
  local last_classification
  last_classification="$(last_error_classification)"
  if [ "$last_classification" = "ERR_VM_UNREACHABLE" ] && is_proxmox_host_reachable; then
    if ensure_proxmox_inventory_task "$stage"; then
      log_stage0_event "$stage" "<none>" "stage0" "idle" "ERR_DEADLOCK" "inventory" "Deadlock: ${top_blocker_summary}; VM SSH unreachable; seeded inventory reconcile"
    else
      if [ "$(deadlock_should_log "$signature")" -eq 1 ]; then
        log_stage0_event "$stage" "<none>" "stage0" "idle" "ERR_DEADLOCK" "inventory" "Deadlock: ${top_blocker_summary}; VM SSH unreachable; inventory reconcile already queued"
      fi
    fi
    return 0
  fi
  local pending_count blocked_count
  pending_count="$(printf '%s' "$report" | jq -r '.pending_count // 0')"
  blocked_count="$(printf '%s' "$report" | jq -r '.blocked_count // 0')"
  if [ "$pending_count" -eq 0 ] || [ "$blocked_count" -eq 0 ]; then
    return 1
  fi
  if [ -z "$signature" ]; then
    return 1
  fi
  local task_id="S${stage}-PLANNER-DEADLOCK-${signature:0:8}"
  if yaml_task_exists "$task_id"; then
    if [ "$(deadlock_should_log "$signature")" -eq 1 ]; then
      log_stage0_event "$stage" "<none>" "stage0" "idle" "ERR_DEADLOCK" "deadlock" "Deadlock: ${top_blocker_summary}; planner task ${task_id} already queued (signature ${signature})"
    fi
    return 0
  fi
  local summary detail
  summary="Deadlock recovery for stage ${stage}"
  detail="Deadlock detected: ${blocked_summary}. top_blocker=${top_blocker_summary}. signature=${signature}"
  local payload
  payload="$(build_task_payload "$task_id" "$stage" "planner" "$summary" "$detail" "docs/orchestrator_v7_2.txt" "" 0 1)"
  yaml_append_task "$payload"
  log_stage0_event "$stage" "<none>" "stage0" "idle" "ERR_DEADLOCK" "deadlock" "Deadlock: ${top_blocker_summary}; seeded planner task ${task_id}"
  return 0
}

ensure_environment
if [ "${1:-}" = "deadlock-detect" ]; then
  requested_stage="${2:-}"
  if [ -n "$requested_stage" ]; then
    STAGE="$requested_stage"
  fi
  if handle_deadlock_if_needed "$STAGE"; then
    exit 0
  fi
  exit 1
fi

check_safe_mode(){
  if [ -f "$STATUS_FILE" ]; then
    local orchestrator_status
    orchestrator_status="$(jq -r '.orchestrator_status // ""' "$STATUS_FILE" 2>/dev/null || echo "")"
    if [ "$orchestrator_status" = "halted_safe_mode" ]; then
      local reason
      reason="$(jq -r '.safe_mode_reason // "unknown"' "$STATUS_FILE" 2>/dev/null || echo "unknown")"
      echo "Orchestrator halted: safe_mode (reason: $reason)" >&2
      return 1
    fi
  fi
  return 0
}

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
  if ! check_safe_mode; then
    exit 0
  fi
  validate_backlog_yaml
  run_backlog_lint
  sync_backlog
  if ! task_json="$(yaml_next_task "$STAGE" 2>/dev/null)"; then
    if handle_deadlock_if_needed "$STAGE"; then
      sleep "$LOOP_SLEEP_SECONDS"
      continue
    fi
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
  current_confidence="$(jq -r '.classification_confidence // ""' "$CURRENT_TASK_FILE")"
  final_status="$current_status"
  final_note="$note"
  final_classification=""
  final_confidence="$current_confidence"
  escalation="none"
  final_attempts="$attempts"

  if [ "$persona" = "executor" ] && [ "$current_status" = "failed" ]; then
    final_classification="$(classify_error "$log_path")"
    final_confidence="${CLASSIFICATION_CONFIDENCE:-low}"
    attempts_next=$((attempts + 1))
    yaml_update_task "$task_id" "{\"attempts\":$attempts_next}"

    # Check if this is an EXTERNAL blocker (SSH/DNS/network unreachable)
    # External blockers should NOT trigger planner recovery - they require human intervention
    if is_external_block_classification "$final_classification"; then
      set_task_status "$task_id" "blocked" "Blocked: ${final_classification} (external - requires human intervention)"
      yaml_update_task "$task_id" "{\"metadata\":{\"blocked_mode\":\"external\",\"classification\":\"${final_classification}\"}}"
      final_status="blocked"
      final_note="Blocked: ${final_classification} (external - no recovery possible until connectivity restored)"
      escalation="external"
      log_stage0_event "$STAGE" "$task_id" "$persona" "blocked" "$final_classification" "external" "External blocker detected - SSH/network unreachable"
    elif [ "$attempts_next" -lt "$max_attempts" ]; then
      set_task_status "$task_id" "pending" "Retry attempt ${attempts_next}"
      final_status="pending"
      final_note="Retry attempt ${attempts_next}"
    elif is_vm_provisioning_classification "$final_classification"; then
      queue_vm_provisioning_tasks "$stage_num" "$final_classification" "$task_id"
      set_task_status "$task_id" "blocked" "Blocked: VM provisioning queued (stage S${stage_num})"
      yaml_update_task "$task_id" "{\"metadata\":{\"blocked_mode\":\"recovery\",\"classification\":\"${final_classification}\"}}"
      final_status="blocked"
      final_note="Blocked: VM provisioning queued (stage S${stage_num})"
      escalation="inventory-provision"
    else
      escalation="$(create_planner_escalation "$task_id" "$final_classification" "$stage_num" || true)"
      blocked_mode="recovery"
      if is_external_block_classification "$final_classification"; then
        blocked_mode="external"
      fi
      set_task_status "$task_id" "blocked" "Blocked after ${attempts_next} failures (recovery queued)"
      yaml_update_task "$task_id" "{\"metadata\":{\"blocked_mode\":\"${blocked_mode}\"}}"
      final_status="blocked"
      final_note="Blocked after ${attempts_next} failures (planner recovery queued)"
    fi
    final_attempts="$attempts_next"
  fi

  final_classification="${final_classification:-UNKNOWN}"
  extras="$(jq -n --arg stage "$stage_num" --arg target "$target" --arg log_path "$log_path" --arg classification "$final_classification" --arg confidence "${final_confidence:-}" '{stage:(($stage|tonumber?)//0),target:$target,log_path:$log_path,error_classification:$classification,classification_confidence:($confidence // empty)}')"
  update_current_task "$task_id" "$persona" "$final_status" "$final_note" "$extras"
  log_loop "$STAGE" "$task_id" "$persona" "$final_status" "$final_attempts" "$escalation" "$final_classification" "$final_note"
  sleep "$LOOP_SLEEP_SECONDS"
done
