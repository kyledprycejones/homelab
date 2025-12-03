#!/usr/bin/env bash
set -euo pipefail

: "${BACKLOG_YAML:=ai/backlog.yaml}"
: "${ORCH_CONFIG:=ai/config/config.yaml}"

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
# Priority: engineer pending -> executor pending w/ target -> planner pending -> due waiting_retry
# Stage filter protects against running higher-stage work when STAGE != metadata.stage.
yaml_next_task() {
  python3 - "$BACKLOG_YAML" <<'PY'
import json, os, re, sys, time, warnings, yaml
warnings.filterwarnings("ignore", category=DeprecationWarning)
path = sys.argv[1]
backlog = yaml.safe_load(open(path, encoding="utf-8")) or []
now = time.time()
changed = False

for entry in backlog:
    status = entry.get("status")
    if status == "waiting_retry":
        next_retry = entry.get("metadata", {}).get("next_retry_at")
        if next_retry is not None and now >= float(next_retry):
            entry["status"] = "pending"
            entry.setdefault("metadata", {}).pop("next_retry_at", None)
            changed = True

if changed:
    with open(path, "w", encoding="utf-8") as f:
        yaml.safe_dump(backlog, f, sort_keys=False)

stage_raw = os.environ.get("STAGE", "0")
try:
    stage_env = int(stage_raw)
except Exception:
    match = re.search(r"(\\d+)", stage_raw or "")
    stage_env = int(match.group(1)) if match else 0

def normalize_stage(value, default=1):
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return int(value)
    try:
        return int(value)
    except Exception:
        match = re.search(r"(\\d+)", str(value))
        if match:
            return int(match.group(1))
    return default

pending_engineer = []
pending_executor = []
pending_planner = []
waiting_retry_due = []

for idx, entry in enumerate(backlog):
    status = entry.get("status")
    metadata = entry.get("metadata", {}) or {}
    entry_stage = normalize_stage(metadata.get("stage"), 1)
    if entry_stage != stage_env:
        continue
    if status == "pending":
        persona = entry.get("persona", "executor")
        target = (entry.get("target") or "").strip()
        row = (entry_stage, entry.get("task_id", ""), idx, entry)
        if persona == "engineer":
            pending_engineer.append(row)
        elif persona == "executor" and target:
            pending_executor.append(row)
        elif persona == "planner":
            pending_planner.append(row)
    elif status == "waiting_retry":
        next_retry = metadata.get("next_retry_at")
        if next_retry is not None and now >= float(next_retry):
            waiting_retry_due.append((entry_stage, entry.get("task_id", ""), idx, entry))

def choose_candidates(bucket):
    if not bucket:
        return None
    bucket.sort()
    return bucket[0][-1]

for bucket in (pending_engineer, pending_executor, pending_planner, waiting_retry_due):
    candidate = choose_candidates(bucket)
    if candidate is not None:
        print(json.dumps(candidate))
        sys.exit(0)

sys.exit(1)
PY
}

yaml_count_pending() {
  local backlog="$1"
  local persona="${2:-executor}"
  python3 - "$backlog" "$persona" <<'PY'
import sys, json, warnings, yaml
warnings.filterwarnings("ignore", category=DeprecationWarning)
path, persona = sys.argv[1:3]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
count = sum(1 for entry in data if entry.get("status") == "pending" and entry.get("persona", "executor") == persona)
print(count)
PY
}

yaml_task_exists(){
  local tid="$1"
  python3 - "$BACKLOG_YAML" "$tid" <<'PY'
import sys, yaml
path, tid = sys.argv[1:3]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
for entry in data:
    if entry.get("task_id") == tid:
        sys.exit(0)
sys.exit(1)
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
