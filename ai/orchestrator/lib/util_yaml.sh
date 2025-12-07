#!/usr/bin/env bash
set -euo pipefail

: "${BACKLOG_YAML:=ai/backlog.yaml}"

yaml_ensure_backlog(){
  mkdir -p "$(dirname "$BACKLOG_YAML")"
  if [ ! -f "$BACKLOG_YAML" ]; then
    printf '[]\n' > "$BACKLOG_YAML"
  fi
}

yaml_load(){
  yaml_ensure_backlog
  python3 - "$BACKLOG_YAML" <<'PY'
import sys, yaml
path = sys.argv[1]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
print(data)
PY
}

yaml_next_task(){
  local stage_raw="${1:-1}"
  yaml_ensure_backlog
  python3 - "$BACKLOG_YAML" "$stage_raw" <<'PY'
import json, yaml, sys, re
path, stage_raw = sys.argv[1:3]
backlog = yaml.safe_load(open(path, encoding="utf-8")) or []
try:
    stage_env = int(stage_raw)
except Exception:
    match = re.search(r"(\d+)", stage_raw or "")
    stage_env = int(match.group(1)) if match else 0
priority = {"planner": 0, "engineer": 1, "executor": 2}
id_map = {entry.get("id"): entry for entry in backlog}
def deps_satisfied(entry):
    deps = entry.get("depends_on") or []
    if not deps:
        return True
    persona = entry.get("persona")
    allow_status = {"success"}
    if persona in {"engineer", "planner"}:
        only_executor = True
        for dep in deps:
            target = id_map.get(dep)
            if not target or target.get("persona") != "executor":
                only_executor = False
                break
        if only_executor:
            allow_status = {"success", "failed", "blocked"}
    for dep in deps:
        target = id_map.get(dep)
        if not target or target.get("status") not in allow_status:
            return False
    return True
candidates = []
for entry in backlog:
    if entry.get("status") != "pending":
        continue
    try:
        entry_stage = int(entry.get("stage", 0))
    except Exception:
        entry_stage = 0
    if entry_stage != stage_env:
        continue
    if not deps_satisfied(entry):
        continue
    persona = entry.get("persona", "executor")
    prio = priority.get(persona, 3)
    candidates.append((prio, entry_stage, entry.get("id"), entry))
if not candidates:
    sys.exit(1)
candidates.sort()
print(json.dumps(candidates[0][-1]))
PY
}

yaml_task_exists(){
  yaml_ensure_backlog
  python3 - "$BACKLOG_YAML" "$1" <<'PY'
import yaml, sys
path, tid = sys.argv[1:3]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
for entry in data:
    if entry.get("id") == tid:
        sys.exit(0)
sys.exit(1)
PY
}

yaml_get_task(){
  yaml_ensure_backlog
  python3 - "$BACKLOG_YAML" "$1" <<'PY'
import json, yaml, sys
path, tid = sys.argv[1:3]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
for entry in data:
    if entry.get("id") == tid:
        print(json.dumps(entry))
        sys.exit(0)
sys.exit(1)
PY
}

yaml_task_status(){
  yaml_ensure_backlog
  python3 - "$BACKLOG_YAML" "$1" <<'PY'
import yaml, sys
path, tid = sys.argv[1:3]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
for entry in data:
    if entry.get("id") == tid:
        print(entry.get("status", "unknown"))
        sys.exit(0)
print("missing")
PY
}

yaml_update_task(){
  local task_id="$1"
  local patch="$2"
  yaml_ensure_backlog
  python3 - "$BACKLOG_YAML" "$task_id" "$patch" <<'PY'
import json, yaml, sys, os
path, tid, patch_json = sys.argv[1:4]
patch = json.loads(patch_json)
data = yaml.safe_load(open(path, encoding="utf-8")) or []
updated = False
for entry in data:
    if entry.get("id") == tid:
        entry.update(patch)
        updated = True
        break
if not updated:
    sys.exit(1)
with open(path + ".tmp", "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, sort_keys=False)
os.replace(path + ".tmp", path)
PY
}

yaml_increment_attempts(){
  local task_id="$1"
  yaml_ensure_backlog
  python3 - "$BACKLOG_YAML" "$task_id" <<'PY'
import yaml, sys, os
path, tid = sys.argv[1:3]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
for entry in data:
    if entry.get("id") == tid:
        entry["attempts"] = int(entry.get("attempts", 0)) + 1
        break
else:
    sys.exit(1)
with open(path + ".tmp", "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, sort_keys=False)
os.replace(path + ".tmp", path)
PY
}

yaml_append_task(){
  local payload="$1"
  yaml_ensure_backlog
  python3 - "$BACKLOG_YAML" "$payload" <<'PY'
import yaml, json, sys, os
path, payload_json = sys.argv[1:3]
payload = json.loads(payload_json)
data = yaml.safe_load(open(path, encoding="utf-8")) or []
for entry in data:
    if entry.get("id") == payload.get("id"):
        sys.exit(0)
data.append(payload)
with open(path + ".tmp", "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, sort_keys=False)
os.replace(path + ".tmp", path)
PY
}
