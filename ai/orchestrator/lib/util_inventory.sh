#!/usr/bin/env bash
set -euo pipefail

# Generate the task ID for the Proxmox inventory snapshot
inventory_task_id(){
  local stage="$1"
  printf 'S%s-PROXMOX-INVENTORY' "$stage"
}

# Generate the task payload for the Proxmox inventory snapshot
inventory_task_payload(){
  local stage="$1"
  local task_id summary detail target depends attempts max_attempts
  task_id="$(inventory_task_id "$stage")"
  summary="INVENTORY: snapshot Proxmox VMs"
  detail="Capture qm list --full output on the Proxmox host to serve as the canonical inventory snapshot."
  target="ai/scripts/reconcile_proxmox_inventory.sh"
  depends="[]"
  attempts="0"
  max_attempts="1"
  jq -n --arg id "$task_id" --arg stage "$stage" --arg persona "executor" --arg summary "$summary" \
    --arg detail "$detail" --arg target "$target" --arg depends "$depends" --arg attempts "$attempts" \
    --arg max_attempts "$max_attempts" '{
      id: $id,
      stage: ($stage | tonumber? // 0),
      persona: "executor",
      summary: $summary,
      detail: $detail,
      target: $target,
      status: "pending",
      attempts: ($attempts | tonumber? // 0),
      max_attempts: ($max_attempts | tonumber? // 1),
      depends_on: ($depends | fromjson)
    }'
}

provision_task_id(){
  local stage="$1"
  printf 'S%s-PROVISION-VMS' "$stage"
}

provision_task_payload(){
  local stage="$1"
  local task_id summary detail target depends attempts max_attempts depends_json
  task_id="$(provision_task_id "$stage")"
  summary="PROVISION: create Ubuntu Server + k3s VMs"
  detail="Wrap infrastructure/proxmox/provision_vms.sh to ensure the control-plane and worker VMs exist with the Ubuntu cloud image and static networking."
  target="infrastructure/proxmox/provision_vms.sh"
  depends_json="$(jq -cn --arg dep "$(inventory_task_id "$stage")" '[$dep]')"
  attempts="0"
  max_attempts="1"
  jq -n --arg id "$task_id" --arg stage "$stage" --arg persona "executor" --arg summary "$summary" \
    --arg detail "$detail" --arg target "$target" --argjson depends "$depends_json" --arg attempts "$attempts" \
    --arg max_attempts "$max_attempts" '{
      id: $id,
      stage: ($stage | tonumber? // 0),
      persona: "executor",
      summary: $summary,
      detail: $detail,
      target: $target,
      status: "pending",
      attempts: ($attempts | tonumber? // 0),
      max_attempts: ($max_attempts | tonumber? // 1),
      depends_on: $depends
    }'
}

resolve_ctrl_ip_task_id(){
  local stage="$1"
  printf 'S%s-RESOLVE-CTRL_IP' "$stage"
}

resolve_ctrl_ip_task_payload(){
  local stage="$1"
  local task_id summary detail target depends attempts max_attempts depends_json
  task_id="$(resolve_ctrl_ip_task_id "$stage")"
  summary="RESOLVE: load controller IP"
  detail="Ensure proxmox_inventory.json exists and export the controller_ip/node_ips snapshot for downstream bootstrapping."
  target="ai/scripts/resolve_ctrl_ip.sh"
  depends_json="$(jq -cn --arg dep "$(provision_task_id "$stage")" '[$dep]')"
  attempts="0"
  max_attempts="1"
  jq -n --arg id "$task_id" --arg stage "$stage" --arg persona "executor" --arg summary "$summary" \
    --arg detail "$detail" --arg target "$target" --argjson depends "$depends_json" --arg attempts "$attempts" \
    --arg max_attempts "$max_attempts" '{
      id: $id,
      stage: ($stage | tonumber? // 0),
      persona: "executor",
      summary: $summary,
      detail: $detail,
      target: $target,
      status: "pending",
      attempts: ($attempts | tonumber? // 0),
      max_attempts: ($max_attempts | tonumber? // 1),
      depends_on: $depends
    }'
}
