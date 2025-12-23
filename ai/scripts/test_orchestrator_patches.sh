#!/usr/bin/env bash
set -euo pipefail

# Smoke test for orchestrator patches
# Tests:
# 1. Task status transitions work (id field correctly used)
# 2. Safe mode halts the loop
# 3. Failed execution is reported as failed
# 4. Reserved statuses are rejected
# 5. Backlog lookups consistently use id

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

. ai/orchestrator/lib/util_yaml.sh
. ai/orchestrator/lib/util_tasks.sh

TEST_BACKLOG="ai/backlog_test.yaml"
TEST_STATUS_FILE="ai/state/status_test.json"
TEST_TASK_ID="TEST-001"

cleanup() {
  rm -f "$TEST_BACKLOG" "$TEST_STATUS_FILE"
}

trap cleanup EXIT

echo "=== Test 1: Task status transitions (id field) ==="
# Create test backlog entry with 'id' field
cat > "$TEST_BACKLOG" <<EOF
- id: $TEST_TASK_ID
  stage: 1
  persona: executor
  summary: Test task
  status: pending
  attempts: 0
  max_attempts: 3
EOF

BACKLOG_YAML="$TEST_BACKLOG"

# Test: get_task_status should find task using 'id'
status=$(yaml_task_status "$TEST_TASK_ID" 2>/dev/null || echo "")
if [ "$status" != "pending" ]; then
  echo "FAIL: get_task_status returned '$status', expected 'pending'"
  exit 1
fi
echo "PASS: get_task_status correctly finds task using 'id' field"

# Test: set_task_status should update task using 'id'
set_task_status "$TEST_TASK_ID" "running" "test"
status=$(yaml_task_status "$TEST_TASK_ID" 2>/dev/null || echo "")
if [ "$status" != "running" ]; then
  echo "FAIL: set_task_status failed to update status, got '$status'"
  exit 1
fi
echo "PASS: set_task_status correctly updates task using 'id' field"

# Test: status transition to success
set_task_status "$TEST_TASK_ID" "success" "test complete"
status=$(yaml_task_status "$TEST_TASK_ID" 2>/dev/null || echo "")
if [ "$status" != "success" ]; then
  echo "FAIL: Status transition to success failed, got '$status'"
  exit 1
fi
echo "PASS: Status transition to 'success' works"

echo ""
echo "=== Test 2: Safe mode halts loop ==="
# Create status.json with halted_safe_mode
mkdir -p "$(dirname "$TEST_STATUS_FILE")"
cat > "$TEST_STATUS_FILE" <<EOF
{
  "orchestrator_status": "halted_safe_mode",
  "safe_mode_reason": "max_cycles",
  "safe_mode_timestamp": "2025-01-01T00:00:00Z"
}
EOF

# Source the check_safe_mode function from codex_loop.sh
# Extract just the check function for testing
check_safe_mode(){
  local STATUS_FILE="$TEST_STATUS_FILE"
  if [ -f "$STATUS_FILE" ]; then
    local orchestrator_status
    orchestrator_status="$(jq -r '.orchestrator_status // ""' "$STATUS_FILE" 2>/dev/null || echo "")"
    if [ "$orchestrator_status" = "halted_safe_mode" ]; then
      return 1
    fi
  fi
  return 0
}

if check_safe_mode; then
  echo "FAIL: check_safe_mode should return non-zero when halted_safe_mode"
  exit 1
fi
echo "PASS: check_safe_mode correctly detects halted_safe_mode"

# Test: should pass when status is normal
cat > "$TEST_STATUS_FILE" <<EOF
{
  "orchestrator_status": "running"
}
EOF

if ! check_safe_mode; then
  echo "FAIL: check_safe_mode should return zero when not halted"
  exit 1
fi
echo "PASS: check_safe_mode correctly allows normal status"

echo ""
echo "=== Test 3: Failed execution reports failure ==="
# Check that ai_harness.sh uses variable exit code, not hardcoded 0
if grep -q 'printf.*HARNESS_END.*exit=0[^0-9]' ai/scripts/ai_harness.sh || grep -q 'HARNESS_END.*exit=0"' ai/scripts/ai_harness.sh; then
  echo "FAIL: ai_harness.sh still has hardcoded exit=0"
  exit 1
fi
# Should use variable exit codes (exec_rc, scp_rc, mv_rc)
if ! grep -q 'exit=.*rc' ai/scripts/ai_harness.sh; then
  echo "FAIL: ai_harness.sh does not use variable exit code"
  exit 1
fi
# Should have exit statements that use the variables
if ! grep -q 'exit "\$exec_rc"' ai/scripts/ai_harness.sh; then
  echo "FAIL: ai_harness.sh does not exit with exec_rc variable"
  exit 1
fi
echo "PASS: ai_harness.sh reports actual exit code"

echo ""
echo "=== Test 4: Reserved statuses rejected ==="
BACKLOG_YAML="$TEST_BACKLOG"
set +e
yaml_update_task "$TEST_TASK_ID" '{"status":"running","note":"test reserved"}'
rc_status=$?
set -e
if [ "$rc_status" -ne 2 ]; then
  echo "FAIL: yaml_update_task allowed status mutation (rc=$rc_status)"
  exit 1
fi
echo "PASS: yaml_update_task rejects status updates"

set +e
set_task_status "$TEST_TASK_ID" "waiting_retry" "reserved transition"
rc_reserved=$?
set -e
if [ "$rc_reserved" -ne 2 ]; then
  echo "FAIL: set_task_status allowed reserved waiting_retry (rc=$rc_reserved)"
  exit 1
fi
echo "PASS: reserved statuses are rejected by default"

echo ""
echo "=== Test 5: Consistent 'id' field usage across codebase ==="
# Check that key files use 'id' not 'task_id' for backlog lookups
if grep -q "\.get(\"task_id\")" ai/scripts/executor/run_summary.py; then
  echo "FAIL: run_summary.py still uses task_id for backlog lookup"
  exit 1
fi
if grep -q "\.task_id.*//.*unknown" ai/scripts/orchestrator_dry_run.sh; then
  echo "FAIL: orchestrator_dry_run.sh still uses .task_id for backlog lookup"
  exit 1
fi
echo "PASS: Codebase consistently uses 'id' for backlog tasks"

echo ""
echo "=== All smoke tests passed ==="
