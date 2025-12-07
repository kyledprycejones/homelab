#!/usr/bin/env bash
set -euo pipefail

: "${BACKLOG_YAML:=ai/backlog.yaml}"

engineer_task_for_parent(){
  local parent="$1"
  local stage_raw="$2"
  python3 - "$BACKLOG_YAML" "$parent" "$stage_raw" <<'PY'
import sys, yaml

path, parent, stage_raw = sys.argv[1:4]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
try:
    stage_env = int(stage_raw)
except Exception:
    stage_env = 0

for entry in data:
    if entry.get("persona") != "engineer":
        continue
    try:
        entry_stage = int(entry.get("stage", 0))
    except Exception:
        entry_stage = 0
    if entry_stage != stage_env:
        continue
    depends = entry.get("depends_on") or []
    if parent in depends:
        print(entry.get("id"))
        sys.exit(0)
sys.exit(1)
PY
}
