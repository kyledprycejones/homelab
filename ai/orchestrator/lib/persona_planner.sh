#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

. ai/orchestrator/lib/util_yaml.sh
. ai/orchestrator/lib/util_logging.sh
. ai/orchestrator/lib/util_tasks.sh
. ai/orchestrator/lib/util_inventory.sh

build_executor_task(){
  local id="$1" stage="$2" summary="$3" detail="$4" target="$5" depends_json="${6:-[]}" max_attempts="${7:-3}"
  jq -n --arg id "$id" --arg stage "$stage" --arg summary "$summary" --arg detail "$detail" \
    --arg target "$target" --argjson depends "$depends_json" --arg max_attempts "$max_attempts" \
    '{id:$id,stage:(($stage|tonumber?)//0),persona:"executor",summary:$summary,detail:$detail,target:$target,status:"pending",attempts:0,max_attempts:(($max_attempts|tonumber?)//3),depends_on:$depends}'
}

append_if_missing(){
  local payload="$1"
  local task_id
  task_id="$(echo "$payload" | jq -r '.id')"
  if yaml_task_exists "$task_id"; then
    echo "[planner] ${task_id} already exists; skipping" >> "$log_file"
    return 1
  fi
  yaml_append_task "$payload"
  echo "[planner] appended ${task_id}" >> "$log_file"
  return 0
}

RECOVERY_CHAIN_EXISTING_IDS=()

append_bootstrap_chain(){
  local stage_num="$1"
  local appended_any=0
  local base_stage
  base_stage="$(printf 'S%s' "$stage_num")"

  local preflight_id="${base_stage}-PREFLIGHT-HOST"
  local lint_id="${base_stage}-LINT-BACKLOG"
  local apply_id="${base_stage}-APPLY-BOOTSTRAP"
  local validate_id="${base_stage}-VALIDATE-BOOTSTRAP"

  local preflight lint
  preflight="$(build_executor_task "$preflight_id" "$stage_num" "PREFLIGHT: verify control plane host" "Ensure control-plane environment ready for stage ${stage_num} using ai/preflight/preflight_tools.sh" "ai/preflight/preflight_tools.sh" "[]" 1)"
  lint="$(build_executor_task "$lint_id" "$stage_num" "LINT: validate backlog + targets" "Lint backlog and target scripts before apply" "ai/scripts/lint_backlog.sh" "[\"$preflight_id\"]" 1)"
  local depends_apply_json depends_validate_json
  depends_apply_json="$(jq -cn --arg dep "$lint_id" '[$dep]')"
  depends_validate_json="$(jq -cn --arg dep "$apply_id" '[$dep]')"
  local apply_task validate_task
  apply_task="$(build_executor_task "$apply_id" "$stage_num" "APPLY: bootstrap infrastructure" "Run infrastructure/proxmox/cluster_bootstrap.sh to apply desired state" "infrastructure/proxmox/cluster_bootstrap.sh" "$depends_apply_json" 3)"
  validate_task="$(build_executor_task "$validate_id" "$stage_num" "VALIDATE: verify bootstrap results" "Confirm cluster state after apply using infrastructure/proxmox/check_cluster.sh" "infrastructure/proxmox/check_cluster.sh" "$depends_validate_json" 3)"

  append_if_missing "$preflight" && appended_any=$((appended_any + 1))
  append_if_missing "$lint" && appended_any=$((appended_any + 1))
  append_if_missing "$apply_task" && appended_any=$((appended_any + 1))
  append_if_missing "$validate_task" && appended_any=$((appended_any + 1))
  echo "$appended_any"
}

append_inventory_task(){
  local stage_num="$1"
  local payload
  payload="$(inventory_task_payload "$stage_num")"
  append_if_missing "$payload"
}

# Check if a task ID is part of the recovery-family (should not trigger further recovery)
# Recovery-family tasks: -RECONCILE, -DELETE, -RESET, -WIPE, -APPLY-RETRY, -VALIDATE-RETRY, -PLANNER-RECOVERY, PLANNER-DEADLOCK
is_recovery_family_task(){
  local task_id="$1"
  case "$task_id" in
    *-RECONCILE*|*-DELETE*|*-RESET*|*-WIPE*|*-APPLY-RETRY*|*-VALIDATE-RETRY*|*-PLANNER-RECOVERY*|*PLANNER-DEADLOCK*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Count occurrences of RECONCILE in task ID (to detect runaway recursion)
count_reconcile_depth(){
  local task_id="$1"
  local count=0
  local tmp="$task_id"
  while [[ "$tmp" == *-RECONCILE* ]]; do
    count=$((count + 1))
    tmp="${tmp/-RECONCILE/}"
  done
  echo "$count"
}

append_recovery_chain(){
  local stage_num="$1" parent="$2" classification="${3:-}" planner_task_id="$4"
  RECOVERY_CHAIN_EXISTING_IDS=()
  local appended_any=0

  # GUARDRAIL: Never generate recovery chains for recovery-family task IDs
  # This prevents runaway recursion like ...-RECONCILE-RECONCILE-RECONCILE...
  if is_recovery_family_task "$parent"; then
    echo "[planner] GUARDRAIL: refusing to generate recovery chain for recovery-family task ${parent}" >> "$log_file"
    PLANNER_GUARDRAIL_BLOCKED=1
    PLANNER_GUARDRAIL_NOTE="Guardrail: refused to generate recovery chain for recovery-family task ${parent}"
    echo "0"
    return
  fi

  # GUARDRAIL: Cap recursion - refuse if parent already contains RECONCILE
  local reconcile_depth
  reconcile_depth="$(count_reconcile_depth "$parent")"
  if [ "$reconcile_depth" -ge 1 ]; then
    echo "[planner] GUARDRAIL: refusing to generate recovery chain - parent ${parent} already contains RECONCILE (depth=${reconcile_depth})" >> "$log_file"
    PLANNER_GUARDRAIL_BLOCKED=1
    PLANNER_GUARDRAIL_NOTE="Guardrail: refused to generate recovery chain for task ${parent} (reconcile depth=${reconcile_depth})"
    echo "0"
    return
  fi

  local reconcile_id="${parent}-RECONCILE"
  local delete_id="${parent}-DELETE"
  local apply_retry_id="${parent}-APPLY-RETRY"
  local validate_retry_id="${parent}-VALIDATE-RETRY"

  # When a VM SSH failure occurred but the Proxmox host is still reachable, first gather inventory
  if [ "$classification" = "ERR_VM_UNREACHABLE" ]; then
    local inventory_id
    inventory_id="$(inventory_task_id "$stage_num")"
    if append_inventory_task "$stage_num"; then
      appended_any=$((appended_any + 1))
    else
      RECOVERY_CHAIN_EXISTING_IDS+=("$inventory_id")
    fi
  fi

  local dep_planner_recovery dep_reconcile dep_delete dep_apply_retry
  dep_planner_recovery="$(jq -cn --arg dep "$planner_task_id" '[$dep]')"
  dep_reconcile="$(jq -cn --arg dep "$reconcile_id" '[$dep]')"
  dep_delete="$(jq -cn --arg dep "$delete_id" '[$dep]')"
  dep_apply_retry="$(jq -cn --arg dep "$apply_retry_id" '[$dep]')"

  local reconcile_task delete_task apply_task validate_task
  reconcile_task="$(build_executor_task "$reconcile_id" "$stage_num" "RECONCILE: observe state for ${parent}" "Read-only discovery to document current state after failure of ${parent}" "infrastructure/proxmox/check_cluster.sh" "$dep_planner_recovery" 1)"
  delete_task="$(build_executor_task "$delete_id" "$stage_num" "DELETE/RESET: clear partial state for ${parent}" "Explicit reset to clear partial state before re-apply" "infrastructure/proxmox/wipe_proxmox.sh" "$dep_reconcile" 1)"
  apply_task="$(build_executor_task "$apply_retry_id" "$stage_num" "APPLY: rebuild after ${parent}" "Re-apply desired state from clean baseline" "infrastructure/proxmox/cluster_bootstrap.sh" "$dep_delete" 3)"
  validate_task="$(build_executor_task "$validate_retry_id" "$stage_num" "VALIDATE: confirm recovery for ${parent}" "Verify rebuilt state after recovery apply" "infrastructure/proxmox/check_cluster.sh" "$dep_apply_retry" 3)"

  if append_if_missing "$reconcile_task"; then
    appended_any=$((appended_any + 1))
  else
    RECOVERY_CHAIN_EXISTING_IDS+=("$reconcile_id")
  fi
  if append_if_missing "$delete_task"; then
    appended_any=$((appended_any + 1))
  else
    RECOVERY_CHAIN_EXISTING_IDS+=("$delete_id")
  fi
  if append_if_missing "$apply_task"; then
    appended_any=$((appended_any + 1))
  else
    RECOVERY_CHAIN_EXISTING_IDS+=("$apply_retry_id")
  fi
  if append_if_missing "$validate_task"; then
    appended_any=$((appended_any + 1))
  else
    RECOVERY_CHAIN_EXISTING_IDS+=("$validate_retry_id")
  fi
  echo "$appended_any"
}

main(){
  if [ "$#" -lt 1 ]; then
    echo "Usage: persona_planner.sh TASK_ID" >&2
    exit 1
  fi
  local task_id="$1"
  local task_json
  task_json="$(yaml_get_task "$task_id")" || { echo "Planner task $task_id missing" >&2; exit 1; }
  local summary detail stage_num
  summary="$(echo "$task_json" | jq -r '.summary // "planner task"')"
  detail="$(echo "$task_json" | jq -r '.detail // ""')"
  stage_num="$(echo "$task_json" | jq -r '.stage // 1')"
  local log_file
  log_file="$(log_persona_event "planner" "$task_id" "running" "$summary: $detail")"

  set_task_status "$task_id" "running" "$summary"
  update_current_task "$task_id" "planner" "running" "$summary" "{\"stage\":$stage_num,\"log_path\":\"$log_file\"}"

  if [ -f "ai/state/last_error.json" ]; then
    echo "[planner] last_error.json context:" >> "$log_file"
    jq '.' "ai/state/last_error.json" >> "$log_file" 2>/dev/null || cat "ai/state/last_error.json" >> "$log_file"
  fi

  # Portable array read (avoids mapfile which requires bash 4+)
  PLANNER_GUARDRAIL_BLOCKED=0
  PLANNER_GUARDRAIL_NOTE=""
  local depends=()
  local dep_line
  while IFS= read -r dep_line; do
    [ -n "$dep_line" ] && depends+=("$dep_line")
  done < <(echo "$task_json" | jq -r '.depends_on[]?')
  local appended_any=0
  local last_error_classification
  last_error_classification="$(jq -r '.error_classification // ""' "ai/state/last_error.json" 2>/dev/null || echo "")"
  local parent_task=""
  if [ "${#depends[@]}" -gt 0 ]; then
    parent_task="${depends[0]}"
    if [ "$last_error_classification" = "ERR_CONFIG_MISSING_CTRL_IP" ]; then
      echo "[planner] GUARDRAIL: missing controller.ip; recovery chain would not fix config wiring" >> "$log_file"
      PLANNER_GUARDRAIL_BLOCKED=1
      PLANNER_GUARDRAIL_NOTE="Guardrail: missing controller.ip in cluster config; set controller.ip or export CTRL_IP"
    elif is_recovery_family_task "$parent_task"; then
      echo "[planner] GUARDRAIL: parent ${parent_task} is recovery-family; refusing to spawn another recovery chain" >> "$log_file"
      PLANNER_GUARDRAIL_BLOCKED=1
      PLANNER_GUARDRAIL_NOTE="Guardrail: refused to generate recovery chain for recovery-family task ${parent_task}"
    else
      appended_any="$(append_recovery_chain "$stage_num" "$parent_task" "$last_error_classification" "$task_id")"
    fi
  else
    appended_any="$(append_bootstrap_chain "$stage_num")"
  fi
  local planner_reason
  if [ "$PLANNER_GUARDRAIL_BLOCKED" -eq 1 ]; then
    planner_reason="guardrail"
  elif [ "${#depends[@]}" -gt 0 ]; then
    planner_reason="recovery"
  else
    planner_reason="bootstrap"
  fi

  local final_status note
  if [ "$PLANNER_GUARDRAIL_BLOCKED" -eq 1 ]; then
    # Guardrail triggered - mark as success but log the guardrail reason
    final_status="success"
    note="${PLANNER_GUARDRAIL_NOTE:-Guardrail: refused to generate recovery chain}"
  elif [ "$appended_any" -ge 1 ]; then
    final_status="success"
    note="Planner added tasks"
  elif [ "${#depends[@]}" -gt 0 ] && [ "${#RECOVERY_CHAIN_EXISTING_IDS[@]}" -gt 0 ]; then
    final_status="success"
    local existing_list
    existing_list="$(IFS=,; echo "${RECOVERY_CHAIN_EXISTING_IDS[*]}")"
    note="Recovery chain already present for ${parent_task}: ${existing_list}"
  elif [ "${#depends[@]}" -gt 0 ]; then
    # v7.2 invariant: zero-append planner recovery runs still conclude as success.
    final_status="success"
    note="Zero-append recovery run; no tasks generated (missing evidence: inspect ai/state/last_error.json)"
  else
    final_status="success"
    note="No additional work needed at this time"
  fi
  local escaped_note="${note//\"/\\\"}"
  echo "PLANNER_RESULT appended=${appended_any} reason=${planner_reason} note=\"${escaped_note}\"" >> "$log_file"
  local extras
  extras="$(jq -n --arg stage "$stage_num" --arg log_path "$log_file" '{stage:(($stage|tonumber?)//0),log_path:$log_path}')"
  if [ "$final_status" = "success" ]; then
    set_task_status "$task_id" "success" "$note"
    update_current_task "$task_id" "planner" "success" "$note" "$extras"
    log_persona_event "planner" "$task_id" "success" "$note"
    exit 0
  fi
  set_task_status "$task_id" "blocked" "$note"
  update_current_task "$task_id" "planner" "blocked" "$note" "$extras"
  log_persona_event "planner" "$task_id" "blocked" "$note"
  exit 0
}

main "$@"
