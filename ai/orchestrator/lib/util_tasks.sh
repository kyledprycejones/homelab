#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# TASK STATE MACHINE
# ============================================================================
# Valid task states:
#   - pending: Task is queued and ready to be processed
#   - running: Task is currently being executed by a persona handler
#   - waiting_retry: RESERVED (v7.2 MUST NOT set this state)
#   - review: Task produced output (e.g., patch) that needs review/approval
#   - blocked: Task cannot proceed (requires human intervention)
#   - success: Task finished successfully (canonical; "completed" is deprecated but normalized)
#   - failed: Last attempt failed (orchestrator may retry or block)
#   - escalated: RESERVED (v7.2 MUST NOT set this state)
#
# Valid state transitions:
#   - pending -> running (persona handler starts processing)
#   - running -> success (task succeeded)
#   - running -> failed (task failed, no retries left)
#   - running -> review (task produced output needing review)
#   - running -> blocked (task cannot proceed)
#   - failed -> pending (orchestrator retry)
#   - failed -> blocked (recovery queued)
#   - review -> success (review approved, task complete)
#   - review -> failed (review rejected)
#
# IMPORTANT: Persona handlers MUST transition pending -> running FIRST before
# attempting any other transition. Direct pending -> failed transitions are
# invalid and will be rejected.
# ============================================================================

VALID_STATUSES=(pending running waiting_retry review blocked success failed escalated completed)  # waiting_retry/escalated are reserved; v7.2 must not set them

_is_valid_transition(){
  local current="$1" next="$2"
  case "$current:$next" in
    pending:running) return 0 ;;
    running:success|running:failed|running:review|running:blocked) return 0 ;;
    failed:pending|failed:blocked) return 0 ;;
    review:success|review:failed) return 0 ;;
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
    if entry.get("id") == tid:
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
  local old_errexit=0
  case "$-" in
    *e*) old_errexit=1 ;;
  esac
  set +e
  python3 - "$BACKLOG_YAML" "$tid" "$next_status" "$note" "$next_retry_at" "$skip_validation" <<'PY'
import sys, yaml, os
path, tid, next_status, note, next_retry_at, skip_validation = sys.argv[1:7]
allowed = {"pending","running","waiting_retry","review","blocked","success","failed","escalated","completed"}  # Note: "completed" is deprecated, normalized to "success" below
if next_status not in allowed:
    sys.exit(1)
data = yaml.safe_load(open(path, encoding="utf-8")) or []
found=False
current = None
for entry in data:
    if entry.get("id") == tid:
        current = entry.get("status")
        found=True
        break
if not found:
    sys.exit(1)
# Normalize status values: completed <-> success are equivalent
# Map completed -> success for consistency with backlog format
if current == "completed":
    current = "success"
if next_status == "completed":
    next_status = "success"
sys.stderr.write(f"[set_task_status] {tid}: {current}->{next_status}\n")
valid = {
    ("pending","running"),
    ("running","success"),
    ("running","failed"),
    ("running","review"),
    ("running","blocked"),
    ("failed","pending"),
    ("failed","blocked"),
    ("review","success"),
    ("review","failed"),
}
if skip_validation != "1":
    if next_status in {"waiting_retry", "escalated"}:
        sys.stderr.write(f"Invalid transition {current}->{next_status} (reserved status)\n")
        sys.exit(2)
    if (current, next_status) not in valid:
        sys.stderr.write(f"Invalid transition {current}->{next_status}\n")
        sys.exit(2)
if skip_validation == "1":
    sys.stderr.write("[set_task_status] SKIP_VALIDATION=1 bypassing state checks\n")
if skip_validation != "1" and current not in allowed:
    sys.stderr.write(f"Invalid transition {current}->{next_status}\n")
    sys.exit(2)
for entry in data:
    if entry.get("id") == tid:
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
  if [ "$old_errexit" -eq 1 ]; then
    set -e
  else
    set +e
  fi
  return $rc
}

set_task_note(){
  local tid="$1" note="$2"
  python3 - "$BACKLOG_YAML" "$tid" "$note" <<'PY'
import sys, yaml, os
path, tid, note = sys.argv[1:4]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
for entry in data:
    if entry.get("id") == tid:
        entry["note"] = note
        break
tmp=f"{path}.tmp"
with open(tmp,"w",encoding="utf-8") as f:
    yaml.safe_dump(data,f,sort_keys=False)
yaml.safe_load(open(tmp,encoding="utf-8"))
os.replace(tmp,path)
PY
}
