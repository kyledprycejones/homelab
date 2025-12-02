#!/usr/bin/env bash
set -euo pipefail

: "${BACKLOG_YAML:=ai/backlog.yaml}"
: "${ORCH_CONFIG:=ai/orchestrator/config.yaml}"

# Ensure PyYAML is available
python3 - <<'PY' >/dev/null 2>&1
try:
    import yaml  # noqa: F401
except Exception as exc:
    import sys
    sys.stderr.write(f"PyYAML is required: {exc}\n")
    sys.exit(1)
PY

yaml_load_backlog() {
  python3 - "$BACKLOG_YAML" <<'PY'
import sys, json, warnings
warnings.filterwarnings("ignore", category=DeprecationWarning)
import yaml
path = sys.argv[1]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
print(json.dumps(data))
PY
}

yaml_write_backlog() {
  local tmp
  tmp="${BACKLOG_YAML}.tmp"
  python3 - "$BACKLOG_YAML" "$tmp" <<'PY'
import sys, yaml, os, json
src, tmp = sys.argv[1:3]
data = json.loads(sys.stdin.read())
with open(tmp, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, sort_keys=False)
# validate
yaml.safe_load(open(tmp, encoding="utf-8"))
os.replace(tmp, src)
PY
}

# Select next eligible task with ordering rules
# Priority: executor run -> executor other -> engineer -> planner, then stage, then original order
# Skip waiting_retry with future next_retry_at; if waiting_retry expired, move to pending
# Also promotes eligible waiting_retry tasks back to pending in-place

yaml_next_task() {
  python3 - "$BACKLOG_YAML" <<'PY'
import sys, time, json, warnings, yaml
warnings.filterwarnings("ignore", category=DeprecationWarning)
path = sys.argv[1]
backlog = yaml.safe_load(open(path, encoding="utf-8")) or []
changed = False
now = time.time()
for entry in backlog:
    if entry.get("status") == "waiting_retry":
        next_retry = entry.get("metadata",{}).get("next_retry_at")
        if next_retry is not None and now >= float(next_retry):
            entry["status"] = "pending"
            entry.setdefault("metadata", {}).pop("next_retry_at", None)
            changed = True
if changed:
    with open(path, "w", encoding="utf-8") as f:
        yaml.safe_dump(backlog, f, sort_keys=False)

# Filter pending tasks
candidates = []
for idx, entry in enumerate(backlog):
    if entry.get("status") != "pending":
        continue
    persona = entry.get("persona", "executor")
    ttype = entry.get("type", "run")
    stage = entry.get("metadata", {}).get("stage", 1)
    persona_rank = {"executor":0, "engineer":1, "planner":2}.get(persona, 3)
    exec_type_rank = 0 if (persona == "executor" and ttype == "run") else 1
    candidates.append((persona_rank, exec_type_rank, stage, idx, entry))

if not candidates:
    sys.exit(1)

candidates.sort(key=lambda x: (x[0], x[1], x[2], x[3]))
print(json.dumps(candidates[0][-1]))
PY
}

yaml_update_task() {
  local tid="$1" status="$2" note="${3:-}" next_retry_at="${4:-}"
  python3 - "$BACKLOG_YAML" "$tid" "$status" "$note" "$next_retry_at" <<'PY'
import sys, warnings, yaml, os, tempfile
warnings.filterwarnings("ignore", category=DeprecationWarning)
path, tid, status, note, next_retry_at = sys.argv[1:6]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
for entry in data:
    if entry.get("task_id") == tid:
        entry["status"] = status
        if note:
            entry["note"] = note
        if next_retry_at:
            entry.setdefault("metadata", {})["next_retry_at"] = float(next_retry_at)
        elif entry.get("metadata", {}).get("next_retry_at"):
            entry["metadata"].pop("next_retry_at", None)
        break
else:
    sys.exit(1)
tmp = f"{path}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, sort_keys=False)
yaml.safe_load(open(tmp, encoding="utf-8"))
os.replace(tmp, path)
PY
}

yaml_append_task() {
  local payload_json="$1"
  python3 - "$BACKLOG_YAML" "$payload_json" <<'PY'
import sys, warnings, json, yaml, os
warnings.filterwarnings("ignore", category=DeprecationWarning)
path = sys.argv[1]
payload = json.loads(sys.argv[2])
data = yaml.safe_load(open(path, encoding="utf-8")) or []
for entry in data:
    if entry.get("task_id") == payload.get("task_id"):
        break
else:
    data.append(payload)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, sort_keys=False)
    yaml.safe_load(open(tmp, encoding="utf-8"))
    os.replace(tmp, path)
PY
}

yaml_get_persona_config() {
  local persona="$1" field="$2" default_value="${3:-}"
  python3 - "$ORCH_CONFIG" "$persona" "$field" "$default_value" <<'PY'
import sys, warnings, yaml, json
warnings.filterwarnings("ignore", category=DeprecationWarning)
path, persona, field, default = sys.argv[1:5]
cfg = yaml.safe_load(open(path, encoding="utf-8")) or {}
val = cfg.get("personas", {}).get(persona, {}).get(field, default)
print(json.dumps(val))
PY
}

yaml_get_planner_autoapprove_paths() {
  python3 - "$ORCH_CONFIG" <<'PY'
import sys, warnings, yaml, json
warnings.filterwarnings("ignore", category=DeprecationWarning)
cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
paths = cfg.get("personas", {}).get("planner", {}).get("auto_approve_paths", [])
print(json.dumps(paths or []))
PY
}
