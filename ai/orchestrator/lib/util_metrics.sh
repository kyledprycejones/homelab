#!/usr/bin/env bash
set -euo pipefail

# Increment failure count keyed by task_id + error_hash and return the new count
increment_failure_count(){
  local task_id="$1" error_hash="$2"
  python3 - "$METRICS_FILE" "$task_id" "$error_hash" <<'PY'
import sys, json
path, tid, h = sys.argv[1:4]
base = {"tasks_completed":0,"tasks_failed":0,"last_run":None,"failure_counts":{}, "failure_totals":{}}
try:
    with open(path,"r",encoding="utf-8") as f:
        base.update(json.load(f))
except Exception:
    pass
key = f"{tid}:{h}"
fc = base.get("failure_counts", {})
totals = base.get("failure_totals", {})
count = fc.get(key, 0) + 1
fc[key] = count
totals[tid] = totals.get(tid, 0) + 1
base["failure_counts"] = fc
base["failure_totals"] = totals
with open(path,"w",encoding="utf-8") as f:
    json.dump(base,f,indent=2)
print(count)
PY
}

total_failure_count(){
  local task_id="$1"
  python3 - "$METRICS_FILE" "$task_id" <<'PY'
import sys, json
path, tid = sys.argv[1:3]
totals = {}
try:
    with open(path,"r",encoding="utf-8") as f:
        totals = json.load(f).get("failure_totals", {})
except Exception:
    pass
print(totals.get(tid, 0))
PY
}
