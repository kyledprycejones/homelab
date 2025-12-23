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

test_deadlock_detection(){
  local tmp_dir stage_log backlog state_dir issues_file current_file
  tmp_dir="$(mktemp -d)"
  stage_log="$tmp_dir/stage0.log"
  backlog="$tmp_dir/backlog.yaml"
  cat <<'EOF' > "$backlog"
[
  {"id":"S1-001-EXECUTOR-A","persona":"executor","stage":1,"status":"pending","depends_on":["S1-002-EXECUTOR-B"]},
  {"id":"S1-002-EXECUTOR-B","persona":"executor","stage":1,"status":"pending","depends_on":["S1-001-EXECUTOR-A"]}
]
EOF
  state_dir="$tmp_dir/state"
  mkdir -p "$state_dir"
  issues_file="$tmp_dir/issues.yaml"
  touch "$issues_file"
  current_file="$tmp_dir/current_task.json"
  touch "$current_file"
  STAGE=1 STAGE0_LOG="$stage_log" ISSUES_FILE="$issues_file" CURRENT_TASK_FILE="$current_file" STAGE_COMPLETE_DIR="$state_dir" BACKLOG_YAML="$backlog" ai/scripts/codex_loop.sh deadlock-detect 1 || {
    rm -rf "$tmp_dir"
    die "deadlock detection command failed"
  }
  local planner_count
  planner_count="$(python3 - "$backlog" <<'PY'
import sys, yaml
path = sys.argv[1]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
count = sum(1 for entry in data if entry.get("persona") == "planner" and "PLANNER-DEADLOCK" in entry.get("id",""))
print(count)
PY
  )"
  planner_count="${planner_count//[$'\n\r']}"
  if [ "$planner_count" -ne 1 ]; then
    rm -rf "$tmp_dir"
    die "Deadlock detection did not add planner task (count=$planner_count)"
  fi
  if grep -q "Backlog empty" "$stage_log" 2>/dev/null; then
    rm -rf "$tmp_dir"
    die "Deadlock detection path should not log Backlog empty"
  fi
  if ! grep -q "Deadlock detected; seeded planner task" "$stage_log"; then
    rm -rf "$tmp_dir"
    die "Deadlock detection did not log seeding note"
  fi
  STAGE=1 STAGE0_LOG="$stage_log" ISSUES_FILE="$issues_file" CURRENT_TASK_FILE="$current_file" STAGE_COMPLETE_DIR="$state_dir" BACKLOG_YAML="$backlog" ai/scripts/codex_loop.sh deadlock-detect 1 >/dev/null 2>&1 || true
  local planner_count2
  planner_count2="$(python3 - "$backlog" <<'PY'
import sys, yaml
path = sys.argv[1]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
count = sum(1 for entry in data if entry.get("persona") == "planner" and "PLANNER-DEADLOCK" in entry.get("id",""))
print(count)
PY
  )"
  planner_count2="${planner_count2//[$'\n\r']}"
  if [ "$planner_count2" -ne 1 ]; then
    rm -rf "$tmp_dir"
    die "Deadlock detection re-seeded planner task (count=$planner_count2)"
  fi
  rm -rf "$tmp_dir"
}

test_planner_recovery_chain_present(){
  local tmp_dir backlog current last_error stage0 log_path status
  tmp_dir="$(mktemp -d)"
  backlog="$tmp_dir/backlog.yaml"
  cat <<'EOF' > "$backlog"
[
  {"id":"S1-001-EXECUTOR-RUN","persona":"executor","stage":1,"status":"failed"},
  {"id":"S1-001-EXECUTOR-RUN-PLANNER-RECOVERY","persona":"planner","stage":1,"status":"pending","depends_on":["S1-001-EXECUTOR-RUN"]},
  {"id":"S1-001-EXECUTOR-RUN-RECONCILE","persona":"executor","stage":1,"status":"pending"},
  {"id":"S1-001-EXECUTOR-RUN-DELETE","persona":"executor","stage":1,"status":"pending"},
  {"id":"S1-001-EXECUTOR-RUN-APPLY-RETRY","persona":"executor","stage":1,"status":"pending"},
  {"id":"S1-001-EXECUTOR-RUN-VALIDATE-RETRY","persona":"executor","stage":1,"status":"pending"}
]
EOF
  current="$tmp_dir/current_task.json"
  touch "$current"
  last_error="$tmp_dir/last_error.json"
  touch "$last_error"
  stage0="$tmp_dir/stage0.log"
  touch "$stage0"
  log_path="ai/logs/planner/S1-001-EXECUTOR-RUN-PLANNER-RECOVERY.log"
  BACKLOG_YAML="$backlog" CURRENT_TASK_FILE="$current" LAST_ERROR_FILE="$last_error" STAGE0_LOG="$stage0" ai/orchestrator/lib/persona_planner.sh "S1-001-EXECUTOR-RUN-PLANNER-RECOVERY"
  status="$(python3 - "$backlog" "S1-001-EXECUTOR-RUN-PLANNER-RECOVERY" <<'PY'
import sys, yaml
path, task = sys.argv[1:3]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
for entry in data:
    if entry.get("id") == task:
        print(entry.get("status", ""))
        sys.exit(0)
sys.exit(1)
PY
  )"
  status="${status//[$'\n\r']}"
  if [ "$status" != "success" ]; then
    rm -f "$log_path"
    rm -rf "$tmp_dir"
    die "Planner recovery should succeed when chain exists (status=$status)"
  fi
  if ! grep -q 'PLANNER_RESULT appended=0 reason=recovery note="Recovery chain already present' "$log_path"; then
    rm -f "$log_path"
    rm -rf "$tmp_dir"
    die "Planner log missing zero-append recovery note"
  fi
  rm -f "$log_path"
  rm -rf "$tmp_dir"
}

test_state_transition(){
  local tid="$1" current="$2" next="$3" expected_rc="${4:-0}"
  local test_name="${5:-$tid: $current -> $next}"
  
  # Set up test task
  python3 - "$TEST_BACKLOG" "$tid" "$current" <<'PY'
import sys, yaml, os
path, tid, status = sys.argv[1:4]
data = yaml.safe_load(open(path, encoding="utf-8")) or []
found = False
for entry in data:
    if entry.get("id") == tid:
        entry["status"] = status
        found = True
        break
if not found:
    data.append({"id": tid, "status": status, "type": "run", "persona": "executor"})
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
  test_state_transition "TEST-004" "running" "blocked" 0 || failed=1
  test_state_transition "TEST-005" "running" "review" 0 || failed=1
  
  echo ""
  echo "Testing invalid transitions..."
  test_state_transition "TEST-006" "pending" "failed" 2 "pending -> failed (should fail)" || failed=1
  test_state_transition "TEST-007" "escalated" "running" 2 "escalated -> running (should fail)" || failed=1
  test_state_transition "TEST-008" "completed" "running" 2 "completed -> running (should fail)" || failed=1
  
  echo ""
  echo "Testing deadlock detection..."
  test_deadlock_detection || failed=1

  echo ""
  echo "Testing planner recovery chain no-op..."
  test_planner_recovery_chain_present || failed=1

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
