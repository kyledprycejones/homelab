#!/usr/bin/env bash
set -euo pipefail

: "${BACKLOG_YAML:=ai/backlog.yaml}"

# Check if a planner recovery task already exists for a parent task within a stage.
# Returns 0 if found, 1 otherwise. Prints the found task id when present.
planner_escalation_exists(){
  local parent="$1" stage_raw="${2:-1}"
  python3 - "$BACKLOG_YAML" "$parent" "$stage_raw" <<'PY'
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
}
