#!/usr/bin/env bash
# Dry-run simulation of orchestrator loop
# Validates state machine, config loading, transitions, and persona routing
# WITHOUT executing actual tasks or modifying state files

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Dry-run mode: all state writes go to /tmp
DRY_RUN=1
export DRY_RUN

BACKLOG_YAML="${BACKLOG_YAML:-ai/backlog.yaml}"
ORCH_CONFIG="${ORCH_CONFIG:-ai/config/config.yaml}"
MODELS_CONFIG="${MODELS_CONFIG:-ai/config/models.yaml}"
CURRENT_TASK_FILE="${CURRENT_TASK_FILE:-/tmp/orchestrator_dry_run_current_task.json}"
METRICS_FILE="${METRICS_FILE:-/tmp/orchestrator_dry_run_metrics.json}"
LAST_RUN_FILE="${LAST_RUN_FILE:-/tmp/orchestrator_dry_run_last_run.log}"
LAST_ERROR_FILE="${LAST_ERROR_FILE:-/tmp/orchestrator_dry_run_last_error.json}"
PATCH_DIR="${PATCH_DIR:-/tmp/orchestrator_dry_run_patches}"
LOG_DIR="${LOG_DIR:-/tmp/orchestrator_dry_run_logs}"
STAGE="${STAGE:-1}"
export STAGE

REPORT_FILE="/tmp/orchestrator_dry_run_report.txt"
> "$REPORT_FILE"

log_report(){
  echo "[DRY-RUN] $*" | tee -a "$REPORT_FILE"
}

log_error(){
  echo "[DRY-RUN ERROR] $*" | tee -a "$REPORT_FILE" >&2
}

log_success(){
  echo "[DRY-RUN ✓] $*" | tee -a "$REPORT_FILE"
}

# Initialize dry-run state files
mkdir -p "$PATCH_DIR" "$LOG_DIR" "$(dirname "$CURRENT_TASK_FILE")"
echo '{"task_id":null,"persona":null,"status":"idle","started_at":null,"note":""}' > "$CURRENT_TASK_FILE"
echo '{"tasks_completed":0,"tasks_failed":0,"last_run":null,"failure_counts":{},"failure_totals":{}}' > "$METRICS_FILE"
> "$LAST_RUN_FILE"
echo '{"task_id":null,"persona":null,"command":null,"stderr_tail":null,"error_hash":null,"failure_count":0,"classification":null}' > "$LAST_ERROR_FILE"

log_report "=== ORCHESTRATOR DRY-RUN START ==="
log_report "Stage: $STAGE"
log_report "Backlog: $BACKLOG_YAML"
log_report "Config: $ORCH_CONFIG"
log_report "Models: $MODELS_CONFIG"
log_report ""

# Validation Phase 1: File Existence
log_report "--- Phase 1: File Existence Check ---"
errors=0

if [ ! -f "$BACKLOG_YAML" ]; then
  log_error "Missing backlog: $BACKLOG_YAML"
  errors=$((errors + 1))
else
  log_success "Backlog exists: $BACKLOG_YAML"
fi

if [ ! -f "$ORCH_CONFIG" ]; then
  log_error "Missing orchestrator config: $ORCH_CONFIG"
  errors=$((errors + 1))
else
  log_success "Config exists: $ORCH_CONFIG"
fi

if [ ! -f "$MODELS_CONFIG" ]; then
  log_error "Missing models config: $MODELS_CONFIG"
  errors=$((errors + 1))
else
  log_success "Models config exists: $MODELS_CONFIG"
fi

if [ "$errors" -gt 0 ]; then
  log_error "Phase 1 failed with $errors errors"
  exit 1
fi

# Validation Phase 2: Config Loading
log_report ""
log_report "--- Phase 2: Config Loading ---"

# Source utilities
# shellcheck source=/dev/null
. ai/orchestrator/lib/util_yaml.sh

# Test config loading
if executor_allowed=$(yaml_get_persona_config executor allowed_paths "[]" 2>&1); then
  log_success "Loaded executor allowed_paths: $executor_allowed"
else
  log_error "Failed to load executor config: $executor_allowed"
  errors=$((errors + 1))
fi

if engineer_allowed=$(yaml_get_persona_config engineer allowed_paths "[]" 2>&1); then
  log_success "Loaded engineer allowed_paths: $engineer_allowed"
else
  log_error "Failed to load engineer config: $engineer_allowed"
  errors=$((errors + 1))
fi

# Validation Phase 3: Backlog Parsing
log_report ""
log_report "--- Phase 3: Backlog Parsing ---"

if ! backlog_data=$(yaml_load_backlog 2>&1); then
  log_error "Failed to parse backlog: $backlog_data"
  errors=$((errors + 1))
else
  task_count=$(echo "$backlog_data" | jq 'length')
  log_success "Backlog parsed: $task_count tasks found"
  
  # Show task breakdown
  pending=$(echo "$backlog_data" | jq '[.[] | select(.status == "pending")] | length')
  running=$(echo "$backlog_data" | jq '[.[] | select(.status == "running")] | length')
  blocked=$(echo "$backlog_data" | jq '[.[] | select(.status == "blocked")] | length')
  log_report "  Pending: $pending, Running: $running, Blocked: $blocked"
fi

# Validation Phase 4: Task Selection
log_report ""
log_report "--- Phase 4: Task Selection Logic ---"

if task_json=$(yaml_next_task "$BACKLOG_YAML" 2>&1); then
  task_id=$(echo "$task_json" | jq -r '.task_id // "unknown"')
  task_persona=$(echo "$task_json" | jq -r '.persona // "unknown"')
  task_status=$(echo "$task_json" | jq -r '.status // "unknown"')
  task_type=$(echo "$task_json" | jq -r '.type // "unknown"')
  task_target=$(echo "$task_json" | jq -r '.target // ""')
  task_stage=$(echo "$task_json" | jq -r '.metadata.stage // "0"')
  
  log_success "Selected task: $task_id"
  log_report "  Persona: $task_persona"
  log_report "  Status: $task_status"
  log_report "  Type: $task_type"
  log_report "  Target: $task_target"
  log_report "  Stage: $task_stage"
  
  if [ "$task_status" != "pending" ]; then
    log_error "Selected task is not in 'pending' state: $task_status"
    errors=$((errors + 1))
  fi
else
  log_error "No eligible task found in backlog"
  errors=$((errors + 1))
fi

# Validation Phase 5: State Machine Transitions
log_report ""
log_report "--- Phase 5: State Machine Transition Validation ---"

# shellcheck source=/dev/null
. ai/orchestrator/lib/util_tasks.sh

# Test valid transitions
test_transition(){
  local from="$1" to="$2" expected="$3"
  if _is_valid_transition "$from" "$to"; then
    if [ "$expected" = "valid" ]; then
      log_success "Transition $from -> $to is valid"
    else
      log_error "Transition $from -> $to should be invalid but was accepted"
      return 1
    fi
  else
    if [ "$expected" = "invalid" ]; then
      log_success "Transition $from -> $to correctly rejected"
    else
      log_error "Transition $from -> $to should be valid but was rejected"
      return 1
    fi
  fi
  return 0
}

log_report "Testing valid transitions..."
test_transition "pending" "running" "valid"
test_transition "running" "completed" "valid"
test_transition "running" "failed" "valid"
test_transition "running" "waiting_retry" "valid"
test_transition "running" "escalated" "valid"
test_transition "waiting_retry" "pending" "valid"

log_report "Testing invalid transitions..."
test_transition "pending" "failed" "invalid"
test_transition "pending" "escalated" "invalid"
test_transition "completed" "running" "invalid"
test_transition "escalated" "running" "invalid"

# Validation Phase 6: Persona Handler Simulation
log_report ""
log_report "--- Phase 6: Persona Handler Simulation ---"

if [ -n "${task_id:-}" ] && [ "$task_id" != "unknown" ]; then
  log_report "Simulating persona handler for: $task_id ($task_persona)"
  
  # Mock the persona handlers
  case "$task_persona" in
    executor)
      log_report "  [MOCK] Executor would:"
      log_report "    1. Validate task status (pending -> running)"
      log_report "    2. Check target path: $task_target"
      
      if [ -n "$task_target" ] && [ -f "$task_target" ]; then
        log_success "    Target file exists: $task_target"
        log_report "    3. [MOCK] Would execute: $task_target"
        log_report "    4. [MOCK] Would capture output and logs"
        log_report "    5. [MOCK] Would classify errors if failed"
        log_report "    6. [MOCK] Would transition to: completed (on success) or escalated (on 3+ failures)"
      elif [ -n "$task_target" ]; then
        log_error "    Target file missing: $task_target"
        log_report "    3. [MOCK] Would fail with: missing target file"
        errors=$((errors + 1))
      else
        log_report "    No target specified (task type: $task_type)"
      fi
      ;;
    engineer)
      log_report "  [MOCK] Engineer would:"
      log_report "    1. Validate task status (pending -> running)"
      log_report "    2. Read last_error.json for context"
      log_report "    3. Analyze target: $task_target"
      log_report "    4. [MOCK] Would generate patch to: $PATCH_DIR/${task_id}.diff"
      log_report "    5. [MOCK] Would transition to: review (patch generated)"
      log_report "    6. [MOCK] Would create planner review task"
      ;;
    planner)
      log_report "  [MOCK] Planner would:"
      log_report "    1. Validate task status (pending -> running)"
      log_report "    2. Read README.md and ai/vision/inspiration.md"
      log_report "    3. Validate patch file exists"
      log_report "    4. Check patch size and allowed paths"
      log_report "    5. [MOCK] Would transition to: completed (approved) or blocked (rejected)"
      ;;
    *)
      log_error "Unknown persona: $task_persona"
      errors=$((errors + 1))
      ;;
  esac
fi

# Validation Phase 7: Path Resolution
log_report ""
log_report "--- Phase 7: Path Resolution Check ---"

# Check if paths referenced in code actually exist
paths_to_check=(
  "ai/orchestrator/lib/util_logging.sh"
  "ai/orchestrator/lib/util_metrics.sh"
  "ai/orchestrator/lib/util_patch.sh"
  "ai/orchestrator/lib/util_tasks.sh"
  "ai/orchestrator/error_classifier.sh"
  "ai/orchestrator/lib/persona_executor.sh"
  "ai/orchestrator/lib/persona_engineer.sh"
  "ai/orchestrator/lib/persona_planner.sh"
  "ai/patches"
  "README.md"
  "ai/vision/inspiration.md"
  "ai/vision/mission.md"
)

for path in "${paths_to_check[@]}"; do
  if [ -e "$path" ]; then
    log_success "Path exists: $path"
  else
    log_error "Path missing: $path"
    errors=$((errors + 1))
  fi
done

# Validation Phase 8: Escalation Flow Simulation
log_report ""
log_report "--- Phase 8: Escalation Flow Simulation ---"

log_report "Simulating escalation chain:"
log_report "  1. Executor fails 3 times"
log_report "  2. [MOCK] Executor would escalate to Engineer (only)"
log_report "  3. [MOCK] Engineer would analyze and generate patch"
log_report "  4. [MOCK] Engineer would transition to 'review' and create Planner task"
log_report "  5. [MOCK] Planner would review patch and approve/reject"
log_report "  6. [MOCK] If approved, Executor would apply patch"

# Check that double-escalation bug is fixed
log_report ""
log_report "Checking for double-escalation bug fix..."
if grep -q "append_planner_task" ai/orchestrator/lib/persona_executor.sh; then
  if grep -A2 "append_engineer_task" ai/orchestrator/lib/persona_executor.sh | grep -q "append_planner_task"; then
    log_error "Double-escalation bug still present: executor escalates to both engineer and planner"
    errors=$((errors + 1))
  else
    log_success "Double-escalation bug appears fixed (planner escalation not immediately after engineer)"
  fi
else
  log_success "No planner escalation in executor (correct - engineer handles it)"
fi

# Validation Phase 9: Config Path Validation
log_report ""
log_report "--- Phase 9: Config Path Validation ---"

# Verify config paths are correct
if grep -q "ai/config/config.yaml" ai/scripts/orchestrator_loop.sh; then
  log_success "orchestrator_loop.sh uses correct config path"
else
  log_error "orchestrator_loop.sh may have wrong config path"
  errors=$((errors + 1))
fi

if grep -q "ai/config/config.yaml" ai/orchestrator/lib/util_yaml.sh; then
  log_success "util_yaml.sh uses correct config path"
else
  log_error "util_yaml.sh may have wrong config path"
  errors=$((errors + 1))
fi

# Validation Phase 10: Planner Validation Checks
log_report ""
log_report "--- Phase 10: Planner Validation Checks ---"

# Check if planner uses grep instead of rg
if grep -q "rg -qi" ai/orchestrator/lib/persona_planner.sh; then
  log_error "Planner still uses 'rg' instead of 'grep'"
  errors=$((errors + 1))
else
  log_success "Planner uses 'grep' (universal compatibility)"
fi

# Check if planner uses correct inspiration path
if grep -q "ai/inspiration.md" ai/orchestrator/lib/persona_planner.sh; then
  log_error "Planner still uses wrong inspiration path (ai/inspiration.md)"
  errors=$((errors + 1))
else
  if grep -q "ai/vision/inspiration.md" ai/orchestrator/lib/persona_planner.sh; then
    log_success "Planner uses correct inspiration path"
  else
    log_error "Planner inspiration path check inconclusive"
  fi
fi

# Final Summary
log_report ""
log_report "=== DRY-RUN SUMMARY ==="
log_report "Total errors found: $errors"

if [ "$errors" -eq 0 ]; then
  log_success "All validations passed!"
  log_report ""
  log_report "Orchestrator is ready for execution."
  log_report "Next steps:"
  log_report "  1. Review this report"
  log_report "  2. Run: STAGE=1 ./ai/scripts/codex_loop.sh"
  log_report "  3. Monitor logs in: $LOG_DIR"
  exit 0
else
  log_error "Found $errors validation errors. Review report above."
  log_report ""
  log_report "Recommended fixes:"
  log_report "  - Fix all errors marked above"
  log_report "  - Re-run this dry-run to verify"
  exit 1
fi
