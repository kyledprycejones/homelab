#!/usr/bin/env bash
set -euo pipefail

# Increment failure count keyed by task_id + error_hash and return the new count
increment_failure_count(){
  local task_id="$1" error_hash="$2"
  python3 - "$METRICS_FILE" "$task_id" "$error_hash" <<'PY'
import sys, json
path, tid, h = sys.argv[1:4]
base = {"tasks_completed":0,"tasks_failed":0,"last_run":None,"failure_counts":{}}
try:
    with open(path,"r",encoding="utf-8") as f:
        base.update(json.load(f))
except Exception:
    pass
key = f"{tid}:{h}"
fc = base.get("failure_counts", {})
count = fc.get(key, 0) + 1
fc[key] = count
base["failure_counts"] = fc
with open(path,"w",encoding="utf-8") as f:
    json.dump(base,f,indent=2)
print(count)
PY
}
