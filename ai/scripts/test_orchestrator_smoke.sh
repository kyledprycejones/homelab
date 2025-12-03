#!/usr/bin/env bash
# Minimal smoke test for orchestrator state machine transitions
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BACKLOG_YAML="${BACKLOG_YAML:-ai/backlog.yaml}"
TEST_BACKLOG="${TEST_BACKLOG:-ai/backlog.test.yaml}"

# Source utilities
# shellcheck source=/dev/null
. ai/orchestrator/lib/util_yaml.sh
# shellcheck source=/dev/null
. ai/orchestrator/lib/util_tasks.sh

err(){ echo "ERROR: $*" >&2; }
die(){ err "$*"; exit 1; }

test_state_transition(){
  local tid="$1" current="$2" next="$3" expected_rc="${4:-0}"
  local test_name="${5:-$tid: $current -> $next}"
  
  # Set up test task
  python3 - "$TEST_BACKLOG" "$tid" "$current" <<'PY'
import sys, yaml, os
path, tid, status = sys.argv[1:3]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
found = False
for entry in data:
    if entry.get("task_id") == tid:
        entry["status"] = status
        found = True
        break
if not found:
    data.append({"task_id": tid, "status": status, "type": "run", "persona": "executor"})
with open(path, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, sort_keys=False)
PY
  
  # Try transition
  local old_backlog="$BACKLOG_YAML"
  BACKLOG_YAML="$TEST_BACKLOG"
  set +e
  set_task_status "$tid" "$next" "test transition"
  local rc=$?
  set -e
  BACKLOG_YAML="$old_backlog"
  
  if [ "$rc" -eq "$expected_rc" ]; then
    echo "✓ $test_name"
    return 0
  else
    err "✗ $test_name (expected rc=$expected_rc, got rc=$rc)"
    return 1
  fi
}

main(){
  # Create test backlog
  echo "[]" > "$TEST_BACKLOG"
  
  local failed=0
  
  echo "Testing valid transitions..."
  test_state_transition "TEST-001" "pending" "running" 0 || failed=1
  test_state_transition "TEST-002" "running" "completed" 0 || failed=1
  test_state_transition "TEST-003" "running" "failed" 0 || failed=1
  test_state_transition "TEST-004" "running" "waiting_retry" 0 || failed=1
  test_state_transition "TEST-005" "waiting_retry" "pending" 0 || failed=1
  
  echo ""
  echo "Testing invalid transitions..."
  test_state_transition "TEST-006" "pending" "failed" 2 "pending -> failed (should fail)" || failed=1
  test_state_transition "TEST-007" "escalated" "running" 2 "escalated -> running (should fail)" || failed=1
  test_state_transition "TEST-008" "completed" "running" 2 "completed -> running (should fail)" || failed=1
  
  # Cleanup
  rm -f "$TEST_BACKLOG"
  
  if [ "$failed" -eq 0 ]; then
    echo ""
    echo "All smoke tests passed!"
    return 0
  else
    err "Some smoke tests failed"
    return 1
  fi
}

main "$@"
