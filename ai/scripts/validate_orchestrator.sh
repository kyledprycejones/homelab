#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$REPO_ROOT"

BACKLOG_YAML="${BACKLOG_YAML:-ai/backlog.yaml}"
STAGE="${STAGE:-1}"

JSON_MODE=0
if [ "${1:-}" = "--json" ]; then
  JSON_MODE=1
  shift
fi

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

run_check() {
  local label="$1"
  shift
  local output rc
  set +e
  output="$($@ 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    pass "$label"
  else
    fail "$label"
    printf '%s\n' "---- ${label} output (tail) ----" >&2
    if [ -n "$output" ]; then
      printf '%s\n' "$output" | tail -n 20 >&2
    else
      printf '<no output>\n' >&2
    fi
  fi
  return "$rc"
}

check_tool() {
  local tool="$1"
  if command -v "$tool" >/dev/null 2>&1; then
    pass "tool $tool"
    return 0
  fi
  fail "missing tool: $tool"
  return 1
}

emit_json() {
  python3 - "$BACKLOG_YAML" "$STAGE" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict, List

import yaml

backlog_path = Path(sys.argv[1])
stage_raw = sys.argv[2]
try:
    stage_env = int(stage_raw)
except Exception:
    stage_env = 0

if not backlog_path.exists():
    print(f"ERROR: backlog missing: {backlog_path}", file=sys.stderr)
    sys.exit(1)

try:
    entries = yaml.safe_load(backlog_path.read_text(encoding="utf-8")) or []
except Exception as exc:
    print(f"ERROR: backlog parse failed: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(entries, list):
    print("ERROR: backlog must be a YAML list", file=sys.stderr)
    sys.exit(1)

id_map = {entry.get("id"): entry for entry in entries if isinstance(entry, dict) and entry.get("id")}

def deps_satisfied(entry: Dict[str, Any]) -> bool:
    deps = entry.get("depends_on") or []
    if not deps:
        return True
    for dep in deps:
        target = id_map.get(dep)
        if not target or target.get("status") != "success":
            return False
    return True

runnable = [
    entry
    for entry in entries
    if isinstance(entry, dict)
    and entry.get("persona") == "executor"
    and entry.get("status") == "pending"
    and int(entry.get("stage", 0) or 0) == stage_env
    and deps_satisfied(entry)
]
runnable.sort(key=lambda e: str(e.get("id", "")))

blocked = [
    entry
    for entry in entries
    if isinstance(entry, dict)
    and entry.get("status") == "blocked"
    and int(entry.get("stage", 0) or 0) == stage_env
]
blocked.sort(key=lambda e: str(e.get("id", "")))

last_error_path = Path("ai/state/last_error.json")
last_error = {}
if last_error_path.exists():
    try:
        last_error = json.loads(last_error_path.read_text(encoding="utf-8"))
    except Exception:
        last_error = {}

pending = [
    entry
    for entry in entries
    if isinstance(entry, dict)
    and entry.get("status") == "pending"
    and int(entry.get("stage", 0) or 0) == stage_env
]

pending_ids = {entry.get("id") for entry in pending if entry.get("id")}
blocked_pending = []
cycle_detected = False
top_blocker_summary = None

for entry in pending:
    deps = entry.get("depends_on") or []
    if not deps:
        continue
    unsatisfied = []
    for dep in deps:
        target = id_map.get(dep)
        status = target.get("status") if target else "missing"
        if not target or status != "success":
            unsatisfied.append({
                "id": dep,
                "status": status or "unknown",
                "note": (target.get("note") if target else "") if target else "",
            })
    if unsatisfied:
        blocked_pending.append({
            "id": entry.get("id"),
            "unsatisfied": unsatisfied,
        })
        if top_blocker_summary is None:
            first = unsatisfied[0]
            note = " ".join((first.get("note") or "").split())
            if note:
                top_blocker_summary = f"{entry.get('id')} blocked_by {first.get('id')} (status={first.get('status')} note={note})"
            else:
                top_blocker_summary = f"{entry.get('id')} blocked_by {first.get('id')} (status={first.get('status')})"
        if any(item.get("id") in pending_ids for item in unsatisfied):
            cycle_detected = True

payload = {
    "stage": stage_env,
    "runnable_executor_tasks": [entry.get("id") for entry in runnable if entry.get("id")],
    "blocked_tasks": [
        {
            "id": entry.get("id"),
            "blocked_mode": (entry.get("metadata") or {}).get("blocked_mode", "unknown"),
        }
        for entry in blocked
        if entry.get("id")
    ],
    "last_error": {
        "classification": last_error.get("error_classification") or "<none>",
        "confidence": last_error.get("classification_confidence") or "<none>",
        "signature": last_error.get("failure_signature") or "<none>",
    },
    "deadlock": {
        "pending_count": len(pending),
        "blocked_count": len(blocked_pending),
        "cycle_detected": cycle_detected,
        "top_blocker": top_blocker_summary,
    },
}

print(json.dumps(payload, sort_keys=True))
PY
}

backlog_health_checks() {
  local output rc
  set +e
  output="$(python3 - "$BACKLOG_YAML" "$STAGE" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Dict, List

import yaml

backlog_path = Path(sys.argv[1])
stage_raw = sys.argv[2]
try:
    stage_env = int(stage_raw)
except Exception:
    stage_env = 0

try:
    entries = yaml.safe_load(backlog_path.read_text(encoding="utf-8")) or []
except Exception as exc:
    print(f"ERROR: backlog parse failed: {exc}")
    sys.exit(1)

if not isinstance(entries, list):
    print("ERROR: backlog must be a YAML list")
    sys.exit(1)

errors: List[str] = []
seen: set[str] = set()

for idx, entry in enumerate(entries):
    if not isinstance(entry, dict):
        errors.append(f"entry[{idx}] not a mapping")
        continue
    task_id = entry.get("id")
    label = task_id or f"entry[{idx}]"
    if not task_id:
        errors.append(f"{label} missing id")
    elif task_id in seen:
        errors.append(f"duplicate id: {task_id}")
    else:
        seen.add(task_id)

    persona = entry.get("persona")
    if persona not in {"executor", "planner"}:
        errors.append(f"{label} invalid persona: {persona}")

    stage_val = entry.get("stage", 0)
    try:
        int(stage_val)
    except Exception:
        errors.append(f"{label} invalid stage: {stage_val}")

    status = entry.get("status", "pending")
    if status in {"waiting_retry", "escalated"}:
        errors.append(f"{label} reserved status: {status}")

    if persona == "executor":
        target = entry.get("target") or ""
        if not target:
            errors.append(f"{label} executor missing target")
        else:
            target_path = Path(target)
            if not target_path.is_absolute():
                target_path = Path.cwd() / target_path
            if not target_path.exists():
                errors.append(f"{label} target missing: {target}")

id_map = {entry.get("id"): entry for entry in entries if isinstance(entry, dict) and entry.get("id")}

def deps_satisfied(entry: Dict[str, Any]) -> bool:
    deps = entry.get("depends_on") or []
    if not deps:
        return True
    for dep in deps:
        target = id_map.get(dep)
        if not target or target.get("status") != "success":
            return False
    return True

pending = [
    entry
    for entry in entries
    if isinstance(entry, dict)
    and entry.get("status") == "pending"
    and int(entry.get("stage", 0) or 0) == stage_env
]

runnable = [
    entry
    for entry in pending
    if entry.get("persona") == "executor" and deps_satisfied(entry)
]

pending_ids = {entry.get("id") for entry in pending if entry.get("id")}
blocked_pending = []
top_blocker_summary = ""

for entry in pending:
    deps = entry.get("depends_on") or []
    if not deps:
        continue
    unsatisfied = []
    for dep in deps:
        target = id_map.get(dep)
        status = target.get("status") if target else "missing"
        if not target or status != "success":
            unsatisfied.append({
                "id": dep,
                "status": status or "unknown",
                "note": (target.get("note") if target else "") if target else "",
            })
    if unsatisfied:
        blocked_pending.append({
            "id": entry.get("id"),
            "unsatisfied": unsatisfied,
        })
        if not top_blocker_summary:
            first = unsatisfied[0]
            note = " ".join((first.get("note") or "").split())
            if note:
                top_blocker_summary = f"{entry.get('id')} blocked_by {first.get('id')} (status={first.get('status')} note={note})"
            else:
                top_blocker_summary = f"{entry.get('id')} blocked_by {first.get('id')} (status={first.get('status')})"

    planner_in_progress = any(
        isinstance(entry, dict)
        and entry.get("persona") == "planner"
        and entry.get("status") in {"pending", "blocked"}
        for entry in entries
    )
    if pending and not runnable and blocked_pending and not planner_in_progress:
        summary = top_blocker_summary or "<none>"
        errors.append(f"deadlock symptoms: pending tasks but none runnable (top_blocker={summary})")

if errors:
    for err in errors:
        print(f"ERROR: {err}")
    sys.exit(1)
PY
)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    pass "backlog health checks"
  else
    fail "backlog health checks"
    printf '%s\n' "---- backlog health checks output (tail) ----" >&2
    if [ -n "$output" ]; then
      printf '%s\n' "$output" | tail -n 40 >&2
    else
      printf '<no output>\n' >&2
    fi
  fi
  return "$rc"
}

if [ "$JSON_MODE" -eq 1 ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found; cannot emit JSON" >&2
    exit 1
  fi
  emit_json
  exit $?
fi

FAILURES=0

printf '== v7.2 Orchestrator Validation ==\n'

printf '\n-- Tooling checks --\n'
check_tool python3
check_tool jq

HAS_PYTHON=0
if command -v python3 >/dev/null 2>&1; then
  HAS_PYTHON=1
fi

printf '\n-- Bash syntax checks --\n'
SHELL_FILES=(
  "ai/scripts/codex_loop.sh"
  "ai/scripts/orchestrator_loop.sh"
  "ai/scripts/ai_harness.sh"
  "ai/scripts/lint_backlog.sh"
  "ai/scripts/validate_backlog_yaml.sh"
  "ai/orchestrator/lib/persona_executor.sh"
  "ai/orchestrator/lib/persona_planner.sh"
  "ai/orchestrator/lib/util_errors.sh"
  "ai/orchestrator/lib/util_logging.sh"
  "ai/orchestrator/lib/util_tasks.sh"
  "ai/orchestrator/lib/util_yaml.sh"
  "ai/orchestrator/lib/util_escalation.sh"
  "ai/orchestrator/lib/util_inventory.sh"
)
for file in "${SHELL_FILES[@]}"; do
  if [ -f "$file" ]; then
    run_check "bash -n $file" bash -n "$file"
  else
    fail "missing shell file: $file"
  fi
done

printf '\n-- Python compile checks --\n'
if [ "$HAS_PYTHON" -eq 1 ]; then
  PY_FILES=(
    "ai/scripts/backlog_summary.py"
    "ai/scripts/executor/run_summary.py"
    "ai/scripts/executor/stage1_backlog_sync.py"
  )
  for file in "${PY_FILES[@]}"; do
    if [ -f "$file" ]; then
      run_check "py_compile $file" python3 -m py_compile "$file"
    else
      fail "missing python file: $file"
    fi
  done
else
  fail "python3 missing; python checks skipped"
fi

printf '\n-- Backlog YAML parse --\n'
if [ "$HAS_PYTHON" -eq 1 ]; then
  run_check "validate_backlog_yaml $BACKLOG_YAML" ai/scripts/validate_backlog_yaml.sh "$BACKLOG_YAML"
else
  fail "python3 missing; cannot parse backlog"
fi

printf '\n-- Backlog lint --\n'
if [ "$HAS_PYTHON" -eq 1 ]; then
  run_check "lint_backlog $BACKLOG_YAML" ai/scripts/lint_backlog.sh "$BACKLOG_YAML"
else
  fail "python3 missing; cannot lint backlog"
fi

printf '\n-- Backlog health checks --\n'
if [ "$HAS_PYTHON" -eq 1 ]; then
  backlog_health_checks
else
  fail "python3 missing; backlog health checks skipped"
fi

printf '\n-- Backlog summary --\n'
if [ "$HAS_PYTHON" -eq 1 ]; then
  python3 - "$BACKLOG_YAML" "$STAGE" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict, List

import yaml

backlog_path = Path(sys.argv[1])
stage_raw = sys.argv[2]
try:
    stage_env = int(stage_raw)
except Exception:
    stage_env = 0

entries: List[Dict[str, Any]] = []
if backlog_path.exists():
    try:
        entries = yaml.safe_load(backlog_path.read_text(encoding="utf-8")) or []
    except Exception:
        entries = []

id_map = {entry.get("id"): entry for entry in entries if isinstance(entry, dict) and entry.get("id")}

def deps_satisfied(entry: Dict[str, Any]) -> bool:
    deps = entry.get("depends_on") or []
    if not deps:
        return True
    for dep in deps:
        target = id_map.get(dep)
        if not target or target.get("status") != "success":
            return False
    return True

runnable = [
    entry
    for entry in entries
    if isinstance(entry, dict)
    and entry.get("persona") == "executor"
    and entry.get("status") == "pending"
    and int(entry.get("stage", 0) or 0) == stage_env
    and deps_satisfied(entry)
]
runnable.sort(key=lambda e: str(e.get("id", "")))

blocked = [
    entry
    for entry in entries
    if isinstance(entry, dict)
    and entry.get("status") == "blocked"
    and int(entry.get("stage", 0) or 0) == stage_env
]
blocked.sort(key=lambda e: str(e.get("id", "")))

last_error_path = Path("ai/state/last_error.json")
last_error = {}
if last_error_path.exists():
    try:
        last_error = json.loads(last_error_path.read_text(encoding="utf-8"))
    except Exception:
        last_error = {}

pending = [
    entry
    for entry in entries
    if isinstance(entry, dict)
    and entry.get("status") == "pending"
    and int(entry.get("stage", 0) or 0) == stage_env
]

blocked_pending = []
cycle_detected = False
top_blocker_summary = ""

pending_ids = {entry.get("id") for entry in pending if entry.get("id")}

for entry in pending:
    deps = entry.get("depends_on") or []
    if not deps:
        continue
    unsatisfied = []
    for dep in deps:
        target = id_map.get(dep)
        status = target.get("status") if target else "missing"
        if not target or status != "success":
            unsatisfied.append({
                "id": dep,
                "status": status or "unknown",
                "note": (target.get("note") if target else "") if target else "",
            })
    if unsatisfied:
        blocked_pending.append({
            "id": entry.get("id"),
            "unsatisfied": unsatisfied,
        })
        if not top_blocker_summary:
            first = unsatisfied[0]
            note = " ".join((first.get("note") or "").split())
            if note:
                top_blocker_summary = f"{entry.get('id')} blocked_by {first.get('id')} (status={first.get('status')} note={note})"
            else:
                top_blocker_summary = f"{entry.get('id')} blocked_by {first.get('id')} (status={first.get('status')})"
        if any(item.get("id") in pending_ids for item in unsatisfied):
            cycle_detected = True

print(f"Stage: {stage_env}")
print(f"Runnable executor tasks: {len(runnable)}")
for entry in runnable:
    summary = (entry.get("summary") or "").strip()
    if summary:
        print(f"- {entry.get('id')}: {summary}")
    else:
        print(f"- {entry.get('id')}")

print(f"Blocked tasks: {len(blocked)}")
for entry in blocked:
    metadata = entry.get("metadata") or {}
    blocked_mode = metadata.get("blocked_mode", "unknown")
    note = " ".join((entry.get("note") or "").split())
    if note:
        print(f"- {entry.get('id')} blocked_mode={blocked_mode} note={note}")
    else:
        print(f"- {entry.get('id')} blocked_mode={blocked_mode}")

classification = last_error.get("error_classification") or "<none>"
confidence = last_error.get("classification_confidence") or "<none>"
signature = last_error.get("failure_signature") or "<none>"
print(f"Last error: classification={classification} confidence={confidence} signature={signature}")

print(
    "Deadlock report: pending_count={pending} blocked_count={blocked} cycle_detected={cycle} top_blocker={top}".format(
        pending=len(pending),
        blocked=len(blocked_pending),
        cycle="yes" if cycle_detected else "no",
        top=top_blocker_summary or "<none>",
    )
)
PY
else
  fail "python3 missing; backlog summary skipped"
fi

printf '\n-- Summary --\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 'VALIDATOR_RESULT PASS\n'
  exit 0
fi
printf 'VALIDATOR_RESULT FAIL (%d issues)\n' "$FAILURES" >&2
exit 1
