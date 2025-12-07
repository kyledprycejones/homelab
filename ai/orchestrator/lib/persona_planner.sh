#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

. ai/orchestrator/lib/util_yaml.sh
. ai/orchestrator/lib/util_logging.sh

planner_stage_tasks(){
  cat <<'EOF'
[{
  "id": "S1-002-ENGINEER-FIX",
  "stage": 1,
  "persona": "engineer",
  "summary": "Harden prox-n100 bootstrap script",
  "detail": "Ensure infrastructure/proxmox/cluster_bootstrap.sh references $HOME/.talos instead of /root/.talos and document the Talos-only bootstrap flow described in ai/master_memo_orchestrator.txt.",
  "target": "infrastructure/proxmox/cluster_bootstrap.sh",
  "note": "Planner queued engineer patch",
  "depends_on": ["S1-001-RUN"],
  "attempts": 0,
  "max_attempts": 2,
  "status": "pending"
},
{
  "id": "S1-003-EXECUTOR-CHECK",
  "stage": 1,
  "persona": "executor",
  "summary": "Validate prox-n100 controller status",
  "detail": "Run infrastructure/proxmox/check_cluster.sh after the bootstrap patch so the Talos nodes verify correctly.",
  "target": "infrastructure/proxmox/check_cluster.sh",
  "note": "Planner queued executor validation",
  "depends_on": ["S1-002-ENGINEER-FIX"],
  "attempts": 0,
  "max_attempts": 3,
  "status": "pending"
},
{
  "id": "S1-004-EXECUTOR-GITOPS",
  "stage": 1,
  "persona": "executor",
  "summary": "Run Flux GitOps stage",
  "detail": "Execute infrastructure/proxmox/cluster_bootstrap.sh gitops stage so Flux controllers install and sync cluster/kubernetes/ per the master memo.",
  "target": "infrastructure/proxmox/cluster_bootstrap.sh",
  "note": "Planner queued GitOps staging",
  "depends_on": ["S1-003-EXECUTOR-CHECK"],
  "attempts": 0,
  "max_attempts": 3,
  "status": "pending"
},
{
  "id": "S1-005-ENGINEER-DOCS",
  "stage": 1,
  "persona": "engineer",
  "summary": "Document bootstrap expectations",
  "detail": "Add a note to infrastructure/proxmox/README.md describing the Talos-first workflow from ai/master_memo_orchestrator.txt and how to target the controller.",
  "target": "infrastructure/proxmox/README.md",
  "note": "Planner queued documentation update",
  "depends_on": ["S1-004-EXECUTOR-GITOPS"],
  "attempts": 0,
  "max_attempts": 2,
  "status": "pending"
}]
EOF
}

append_stage_tasks(){
  local appended=0
  while read -r payload; do
    local task_id
    task_id="$(echo "$payload" | jq -r '.id')"
    if yaml_task_exists "$task_id"; then
      continue
    fi
    yaml_append_task "$payload"
    appended=1
  done < <(planner_stage_tasks | jq -c '.[]')
  echo "$appended"
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

  log_persona_event "planner" "$task_id" "running" "$summary: $detail" >/dev/null
  yaml_update_task "$task_id" '{"status":"running"}'
  update_current_task "$task_id" "planner" "running" "$summary" "{\"stage\":$stage_num}"

  local appended
  appended="$(append_stage_tasks)"

  if [ "$appended" -eq 1 ]; then
    yaml_update_task "$task_id" '{"status":"success","note":"Planner added stage work"}'
    update_current_task "$task_id" "planner" "success" "$summary"
    log_persona_event "planner" "$task_id" "success" "planner generated stage ${stage_num} work"
    exit 0
  fi

  yaml_update_task "$task_id" '{"status":"success","note":"No additional work needed at this time"}'
  update_current_task "$task_id" "planner" "success" "$summary"
  log_persona_event "planner" "$task_id" "success" "planner had nothing new to add"
}

main "$@"
