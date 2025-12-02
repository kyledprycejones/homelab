#!/usr/bin/env bash
set -euo pipefail

VALID_STATUSES=(pending running waiting_retry review blocked completed failed)

_is_valid_transition(){
  local current="$1" next="$2"
  case "$current:$next" in
    pending:running) return 0 ;;
    running:completed|running:failed|running:waiting_retry|running:review|running:blocked) return 0 ;;
    waiting_retry:pending) return 0 ;;
    review:completed|review:failed) return 0 ;;
  esac
  return 1
}

set_task_status(){
  local tid="$1" next_status="$2" note="${3:-}" next_retry_at="${4:-}"
  python3 - "$BACKLOG_YAML" "$tid" "$next_status" "$note" "$next_retry_at" <<'PY'
import sys, yaml, os
path, tid, next_status, note, next_retry_at = sys.argv[1:6]
allowed = {"pending","running","waiting_retry","review","blocked","completed","failed"}
if next_status not in allowed:
    sys.exit(1)
data = yaml.safe_load(open(path, encoding="utf-8")) or []
found=False
for entry in data:
    if entry.get("task_id") == tid:
        current = entry.get("status")
        found=True
        break
if not found:
    sys.exit(1)
sys.stderr.write(f"[set_task_status] {tid}: {current}->{next_status}\n")
valid = {
    ("pending","running"),
    ("running","completed"),
    ("running","failed"),
    ("running","waiting_retry"),
    ("running","review"),
    ("running","blocked"),
    ("waiting_retry","pending"),
    ("review","completed"),
    ("review","failed"),
}
if (current, next_status) not in valid:
    sys.stderr.write(f"Invalid transition {current}->{next_status}\n")
    sys.exit(2)
for entry in data:
    if entry.get("task_id") == tid:
        entry["status"] = next_status
        if note:
            entry["note"] = note
        if next_retry_at:
            entry.setdefault("metadata", {})["next_retry_at"] = float(next_retry_at)
        elif entry.get("metadata", {}).get("next_retry_at"):
            entry["metadata"].pop("next_retry_at", None)
        break
tmp = f"{path}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, sort_keys=False)
yaml.safe_load(open(tmp, encoding="utf-8"))
os.replace(tmp, path)
PY
}

set_task_note(){
  local tid="$1" note="$2"
  python3 - "$BACKLOG_YAML" "$tid" "$note" <<'PY'
import sys, yaml, os
path, tid, note = sys.argv[1:4]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
for entry in data:
    if entry.get("task_id") == tid:
        entry["note"] = note
        break
tmp=f"{path}.tmp"
with open(tmp,"w",encoding="utf-8") as f:
    yaml.safe_dump(data,f,sort_keys=False)
yaml.safe_load(open(tmp,encoding="utf-8"))
os.replace(tmp,path)
PY
}

append_engineer_task(){
  local tid="$1" target="$2" tail="$3"
  local new_id="${tid}-FIX"
  yaml_append_task "$(jq -n --arg id "$new_id" --arg target "$target" --arg tail "$tail" '{task_id:$id,type:"code_fix",persona:"engineer",target:$target,description:("Investigate failure for " + $id + ": " + $tail),status:"pending",metadata:{stage:1}}')"
}

append_planner_task(){
  local tid="$1" patch="$2"
  local new_id="${tid}-REVIEW"
  yaml_append_task "$(jq -n --arg id "$new_id" --arg patch "$patch" '{task_id:$id,type:"design",persona:"planner",target:$patch,description:("Review engineer patch " + $id + " before applying."),status:"pending",metadata:{stage:1}}')"
}

append_apply_task(){
  local tid="$1" patch="$2"
  local new_id="${tid}-APPLY"
  yaml_append_task "$(jq -n --arg id "$new_id" --arg patch "$patch" '{task_id:$id,type:"apply_patch",persona:"executor",target:$patch,description:("Apply planner-approved patch " + $id),status:"pending",metadata:{stage:1}}')"
}

append_revision_task(){
  local tid="$1" target="$2" note="$3"
  local new_id="${tid}-REVISION"
  yaml_append_task "$(jq -n --arg id "$new_id" --arg target "$target" --arg note "$note" '{task_id:$id,type:"code_fix",persona:"engineer",target:$target,description:$note,status:"pending",metadata:{stage:1}}')"
}
