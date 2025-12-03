#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# TASK STATE MACHINE
# ============================================================================
# Valid task states:
#   - pending: Task is queued and ready to be processed
#   - running: Task is currently being executed by a persona handler
#   - waiting_retry: Task failed but will be retried after a delay
#   - review: Task produced output (e.g., patch) that needs review/approval
#   - blocked: Task cannot proceed (requires human intervention)
#   - completed: Task finished successfully
#   - failed: Task failed and will not be retried
#   - escalated: Task escalated to a different persona (e.g., executor -> engineer)
#
# Valid state transitions:
#   - pending -> running (persona handler starts processing)
#   - running -> completed (task succeeded)
#   - running -> failed (task failed, no retries left)
#   - running -> waiting_retry (task failed, will retry)
#   - running -> review (task produced output needing review)
#   - running -> blocked (task cannot proceed)
#   - running -> escalated (task escalated to another persona)
#   - waiting_retry -> pending (retry delay expired, ready to retry)
#   - waiting_retry -> escalated (too many retries, escalate)
#   - review -> completed (review approved, task complete)
#   - review -> failed (review rejected)
#   - review -> escalated (review needs higher-level approval)
#
# IMPORTANT: Persona handlers MUST transition pending -> running FIRST before
# attempting any other transition. Direct pending -> failed transitions are
# invalid and will be rejected.
# ============================================================================

VALID_STATUSES=(pending running waiting_retry review blocked completed failed escalated)

_is_valid_transition(){
  local current="$1" next="$2"
  case "$current:$next" in
    pending:running) return 0 ;;
    running:completed|running:failed|running:waiting_retry|running:review|running:blocked|running:escalated) return 0 ;;
    waiting_retry:pending|waiting_retry:escalated) return 0 ;;
    review:completed|review:failed|review:escalated) return 0 ;;
  esac
  return 1
}

# Get current task status from backlog
# Usage: get_task_status TASK_ID
# Returns: status string or empty if task not found
get_task_status(){
  local tid="$1"
  python3 - "$BACKLOG_YAML" "$tid" <<'PY'
import sys, yaml
path, tid = sys.argv[1:3]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
for entry in data:
    if entry.get("task_id") == tid:
        print(entry.get("status", ""))
        sys.exit(0)
sys.exit(1)
PY
}

# Update task status with validation.
# Usage: set_task_status TASK_ID STATUS [NOTE] [NEXT_RETRY_AT]
# If skip_validation=1 is set in environment, validation is bypassed (use with caution).
# Returns: 0 on success, 1 if task not found, 2 if invalid transition
set_task_status(){
  local tid="$1" next_status="$2" note="${3:-}" next_retry_at="${4:-}"
  local skip_validation="${SKIP_VALIDATION:-0}"
  set +e
  python3 - "$BACKLOG_YAML" "$tid" "$next_status" "$note" "$next_retry_at" "$skip_validation" <<'PY'
import sys, yaml, os
path, tid, next_status, note, next_retry_at, skip_validation = sys.argv[1:7]
allowed = {"pending","running","waiting_retry","review","blocked","completed","failed","escalated"}
if next_status not in allowed:
    sys.exit(1)
data = yaml.safe_load(open(path, encoding="utf-8")) or []
found=False
current = None
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
    ("running","escalated"),
    ("waiting_retry","pending"),
    ("waiting_retry","escalated"),
    ("review","completed"),
    ("review","failed"),
    ("review","escalated"),
}
if skip_validation != "1" and (current, next_status) not in valid:
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
  local rc=$?
  set -e
  return $rc
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
  local tid="$1" target="$2" tail="$3" stage="${4:-1}"
  local new_id="${tid}-ENG"
  python3 - "$BACKLOG_YAML" "$new_id" "$tid" "$target" "$tail" "$stage" <<'PY'
import sys, yaml, os
from textwrap import shorten

path, new_id, parent, target, tail, stage = sys.argv[1:7]
try:
    stage_int = int(stage)
except Exception:
    stage_int = 1

summary = shorten((tail or "").replace("\n", " ").strip(), width=180, placeholder="...")
desc = (
    "Investigate and fix the Stage 1 prox-n100 bootstrap script based on recent executor failures. "
    "Focus on code and path correctness (no heavy infra actions). "
    f"Recent error tail: {summary or '<none>'}"
)
payload = {
    "task_id": new_id,
    "type": "edit",
    "persona": "engineer",
    "target": target,
    "description": desc,
    "status": "pending",
    "metadata": {"stage": stage_int, "parent_task": parent},
    "note": f"auto-escalated from {parent}",
}

data = yaml.safe_load(open(path, encoding="utf-8")) or []
found = False
for entry in data:
    if entry.get("task_id") == new_id:
        entry.update({k: v for k, v in payload.items() if k != "metadata"})
        meta = entry.setdefault("metadata", {})
        meta.update(payload.get("metadata") or {})
        found = True
        break
if not found:
    data.append(payload)

tmp = f"{path}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, sort_keys=False)
yaml.safe_load(open(tmp, encoding="utf-8"))
os.replace(tmp, path)
PY
}

append_planner_task(){
  local tid="$1" patch="$2" stage="${3:-1}"
  local new_id="${tid}-REVIEW"
  python3 - "$BACKLOG_YAML" "$new_id" "$tid" "$patch" "$stage" <<'PY'
import sys, yaml, os

path, new_id, parent, patch, stage = sys.argv[1:6]
try:
    stage_int = int(stage)
except Exception:
    stage_int = 1

payload = {
    "task_id": new_id,
    "type": "design",
    "persona": "planner",
    "target": patch,
    "description": f"Review engineer patch for {parent} before applying.",
    "status": "pending",
    "metadata": {"stage": stage_int, "parent_task": parent},
    "note": f"auto-escalated from {parent}",
}

data = yaml.safe_load(open(path, encoding="utf-8")) or []
found = False
for entry in data:
    if entry.get("task_id") == new_id:
        entry.update({k: v for k, v in payload.items() if k != "metadata"})
        meta = entry.setdefault("metadata", {})
        meta.update(payload.get("metadata") or {})
        found = True
        break
if not found:
    data.append(payload)

tmp = f"{path}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, sort_keys=False)
yaml.safe_load(open(tmp, encoding="utf-8"))
os.replace(tmp, path)
PY
}

append_apply_task(){
  local tid="$1" patch="$2" stage="${3:-1}"
  local new_id="${tid}-APPLY"
  yaml_append_task "$(jq -n --arg id "$new_id" --arg patch "$patch" --arg stage "$stage" '{task_id:$id,type:"apply_patch",persona:"executor",target:$patch,description:("Apply planner-approved patch " + $id),status:"pending",metadata:{stage:(try ($stage|tonumber) catch 1)}}')"
}

append_revision_task(){
  local tid="$1" target="$2" note="$3" stage="${4:-1}"
  local new_id="${tid}-REVISION"
  yaml_append_task "$(jq -n --arg id "$new_id" --arg target "$target" --arg note "$note" --arg stage "$stage" '{task_id:$id,type:"code_fix",persona:"engineer",target:$target,description:$note,status:"pending",metadata:{stage:(try ($stage|tonumber) catch 1)}}')"
}
