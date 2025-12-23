#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BACKLOG_FILE="${BACKLOG_YAML:-ai/backlog.yaml}"

if [ ! -f "$BACKLOG_FILE" ]; then
  echo "Backlog missing: ${BACKLOG_FILE}" >&2
  exit 1
fi

python3 - "$BACKLOG_FILE" <<'PY'
import sys, yaml, os
from pathlib import Path

path = Path(sys.argv[1])
data = yaml.safe_load(path.read_text()) or []
if not isinstance(data, list):
    print(f"{path}: expected list of tasks", file=sys.stderr)
    sys.exit(1)

ids = {entry.get("id") for entry in data if entry.get("id")}
ok = True

for idx, entry in enumerate(data, start=1):
    tid = entry.get("id")
    if not tid:
        print(f"[entry {idx}] missing id", file=sys.stderr)
        ok = False
        continue
    persona = entry.get("persona")
    if persona not in {"planner", "executor"}:
        print(f"{tid}: invalid persona '{persona}'", file=sys.stderr)
        ok = False
    status = entry.get("status")
    if status in {"waiting_retry", "escalated"}:
        print(f"{tid}: reserved status '{status}' present", file=sys.stderr)
        ok = False
    if "stage" not in entry:
        print(f"{tid}: missing stage", file=sys.stderr)
        ok = False
    else:
        try:
            int(entry.get("stage", 0))
        except Exception:
            print(f"{tid}: non-integer stage '{entry.get('stage')}'", file=sys.stderr)
            ok = False
    if persona == "executor":
        target = entry.get("target") or ""
        if not target:
            print(f"{tid}: missing target for executor task", file=sys.stderr)
            ok = False
        else:
            target_path = Path(target)
            if not target_path.exists():
                print(f"{tid}: target path missing: {target}", file=sys.stderr)
                ok = False
    depends = entry.get("depends_on") or []
    for dep in depends:
        if dep not in ids:
            print(f"{tid}: dependency not found in backlog: {dep}", file=sys.stderr)
            ok = False

if not ok:
    sys.exit(1)

print("backlog lint passed")
PY
