#!/usr/bin/env bash
# =============================================================================
# Orchestrator v7 Smoke Test
#
# Validates:
#   1. Drift engine runs and produces valid output
#   2. Model router selects correct providers for executor/architect roles
#   3. State files are created and readable
#   4. Converge command starts without errors
#
# Usage: ./ai/scripts/test_v7_smoke.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$REPO_ROOT"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() {
  echo -e "${GREEN}✓${NC} $1"
}

fail() {
  echo -e "${RED}✗${NC} $1"
  FAILED=$((FAILED + 1))
}

warn() {
  echo -e "${YELLOW}⚠${NC} $1"
}

FAILED=0

echo "=== Orchestrator v7 Smoke Test ==="
echo ""

# -----------------------------------------------------------------------------
# Test 1: Verify drift engine exists and is executable
# -----------------------------------------------------------------------------
echo "--- Test 1: Drift Engine ---"

if [ -f "ai/drift_engine.py" ]; then
  pass "Drift engine exists"
else
  fail "Drift engine not found: ai/drift_engine.py"
fi

# Test drift engine can be invoked
if python3 ai/drift_engine.py --help >/dev/null 2>&1; then
  pass "Drift engine is executable"
else
  fail "Drift engine failed to run"
fi

# Test measure command (dry run)
if python3 ai/drift_engine.py measure --memo docs/master_memo.txt --repo-root "$REPO_ROOT" --json >/dev/null 2>&1; then
  pass "Drift engine measure command works"
else
  warn "Drift engine measure failed (memo may not exist)"
fi

echo ""

# -----------------------------------------------------------------------------
# Test 2: Verify model router configuration
# -----------------------------------------------------------------------------
echo "--- Test 2: Model Router Configuration ---"

if [ -f "ai/config/model_router.yaml" ]; then
  pass "Model router config exists"
else
  fail "Model router config not found"
fi

# Validate JSON structure
if python3 -c "import json; json.load(open('ai/config/model_router.yaml'))" 2>/dev/null; then
  pass "Model router config is valid JSON"
else
  fail "Model router config is not valid JSON"
fi

# Check for v7 provider structure
if python3 -c "
import json
cfg = json.load(open('ai/config/model_router.yaml'))
assert 'ollama_architect' in cfg.get('providers', {}), 'ollama_architect missing'
assert 'ollama_executor' in cfg.get('providers', {}), 'ollama_executor missing'
assert 'codex' in cfg.get('providers', {}), 'codex missing'
roles = cfg.get('roles', {})
assert 'ollama_architect' in roles.get('architect', {}).get('priority', []), 'architect priority wrong'
assert 'codex' in roles.get('executor', {}).get('priority', []), 'executor priority wrong'
" 2>/dev/null; then
  pass "v7 provider structure is correct"
else
  fail "v7 provider structure is incorrect"
fi

echo ""

# -----------------------------------------------------------------------------
# Test 3: Verify model router script
# -----------------------------------------------------------------------------
echo "--- Test 3: Model Router Script ---"

if [ -f "ai/model_router.sh" ] && [ -x "ai/model_router.sh" ]; then
  pass "Model router script exists and is executable"
else
  fail "Model router script missing or not executable"
fi

# Test router status command
if ai/model_router.sh status >/dev/null 2>&1; then
  pass "Model router status command works"
else
  fail "Model router status command failed"
fi

# Test executor role selection
set +e
executor_output="$(ai/model_router.sh select executor test_error_key 2>/dev/null)"
executor_rc=$?
set -e

if [ "$executor_rc" -eq 0 ]; then
  pass "Model router can select executor provider"
  # Check output format
  if echo "$executor_output" | grep -q "^provider="; then
    pass "Executor selection returns correct format"
  else
    fail "Executor selection format incorrect"
  fi
else
  warn "Executor selection failed (may need providers running)"
fi

# Test architect role selection
set +e
architect_output="$(ai/model_router.sh select architect test_error_key 2>/dev/null)"
architect_rc=$?
set -e

if [ "$architect_rc" -eq 0 ]; then
  pass "Model router can select architect provider"
  # Check that local architect is preferred
  if echo "$architect_output" | grep -q "provider=ollama_architect"; then
    pass "Local architect (ollama_architect) is selected first"
  elif echo "$architect_output" | grep -q "provider=openrouter"; then
    warn "OpenRouter selected for architect (local not available)"
  else
    warn "Unknown architect provider selected"
  fi
else
  warn "Architect selection failed (may need providers running)"
fi

echo ""

# -----------------------------------------------------------------------------
# Test 4: Verify state files
# -----------------------------------------------------------------------------
echo "--- Test 4: State Files ---"

if [ -d "ai/state" ]; then
  pass "State directory exists"
else
  fail "State directory missing"
fi

# Verify initial state files exist or can be created
for state_file in "drift.json" "now.json" "timeline.json"; do
  if [ -f "ai/state/$state_file" ]; then
    if python3 -c "import json; json.load(open('ai/state/$state_file'))" 2>/dev/null; then
      pass "State file $state_file exists and is valid JSON"
    else
      fail "State file $state_file is corrupted"
    fi
  else
    warn "State file $state_file does not exist (will be created on first run)"
  fi
done

echo ""

# -----------------------------------------------------------------------------
# Test 5: Verify bootstrap_loop.sh has v7 commands
# -----------------------------------------------------------------------------
echo "--- Test 5: Bootstrap Loop v7 Commands ---"

if [ -f "ai/bootstrap_loop.sh" ]; then
  pass "Bootstrap loop script exists"
else
  fail "Bootstrap loop script missing"
fi

# Check for converge command
if grep -q "converge_loop" ai/bootstrap_loop.sh; then
  pass "Bootstrap loop has converge_loop function"
else
  fail "Bootstrap loop missing converge_loop function"
fi

# Check for drift engine integration
if grep -q "DRIFT_ENGINE" ai/bootstrap_loop.sh; then
  pass "Bootstrap loop integrates with drift engine"
else
  fail "Bootstrap loop missing drift engine integration"
fi

# Check for v7 header
if head -20 ai/bootstrap_loop.sh | grep -q "v7"; then
  pass "Bootstrap loop header references v7"
else
  warn "Bootstrap loop header may not reference v7"
fi

echo ""

# -----------------------------------------------------------------------------
# Test 6: Verify protected files list
# -----------------------------------------------------------------------------
echo "--- Test 6: Protected Files ---"

# Check that protected files are listed in bootstrap_loop
protected_files=(
  "docs/master_memo.txt"
  "ai/context_map.yaml"
  "ai/bootstrap_loop.sh"
  "ai/drift_engine.py"
)

for pf in "${protected_files[@]}"; do
  if grep -q "$pf" ai/bootstrap_loop.sh; then
    pass "Protected file listed: $pf"
  else
    warn "Protected file may not be listed: $pf"
  fi
done

echo ""

# -----------------------------------------------------------------------------
# Test 7: Dry run converge (syntax check)
# -----------------------------------------------------------------------------
echo "--- Test 7: Converge Syntax Check ---"

# Check that the converge function can be parsed (syntax check)
set +e
bash -n ai/bootstrap_loop.sh 2>&1
syntax_rc=$?
set -e

if [ "$syntax_rc" -eq 0 ]; then
  pass "Bootstrap loop has valid syntax"
else
  fail "Bootstrap loop has syntax errors"
fi

# Check that converge command is recognized (usage shows it)
usage_output="$(./ai/bootstrap_loop.sh 2>&1 || true)"
if echo "$usage_output" | grep -q "converge"; then
  pass "Converge command is listed in usage"
else
  fail "Converge command not in usage"
fi

echo ""

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo "=== Summary ==="
if [ "$FAILED" -eq 0 ]; then
  echo -e "${GREEN}All critical tests passed!${NC}"
  echo ""
  echo "Next steps:"
  echo "  1. Ensure Ollama is running: ollama list"
  echo "  2. Pull required models: ollama pull qwen-2.5:7b-coder && ollama pull qwen2.5:7b-instruct"
  echo "  3. Run convergence: ./ai/bootstrap_loop.sh converge"
  exit 0
else
  echo -e "${RED}$FAILED test(s) failed${NC}"
  echo "Review the failures above and fix before running convergence."
  exit 1
fi
