#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

: "${CURRENT_TASK_FILE:=ai/state/CURRENT_TASK_FILE}"

. ai/orchestrator/lib/util_yaml.sh
. ai/orchestrator/lib/util_logging.sh

if [ ! -f "$CURRENT_TASK_FILE" ]; then
  jq -n '{task_id:null,persona:null,status:"idle",note:""}' > "$CURRENT_TASK_FILE"
fi

task_json="$(cat "$CURRENT_TASK_FILE")"
task_id="$(echo "$task_json" | jq -r '.task_id // empty')"
persona="$(echo "$task_json" | jq -r '.persona // empty')"

if [ -z "$task_id" ] || [ -z "$persona" ]; then
  echo "Missing current task metadata" >&2
  exit 1
fi

case "$persona" in
  planner)
    ai/orchestrator/lib/persona_planner.sh "$task_id"
    ;;
  engineer)
    ai/orchestrator/lib/persona_engineer.sh "$task_id"
    ;;
  executor)
    ai/orchestrator/lib/persona_executor.sh "$task_id"
    ;;
  *)
    echo "Unknown persona '$persona'" >&2
    exit 1
    ;;
esac
