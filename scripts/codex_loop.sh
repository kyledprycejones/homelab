#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LOG_DIR="logs/ai"
mkdir -p "$LOG_DIR"

while true; do
  run_ts="$(date -u +%Y%m%d-%H%M%S)"
  log_file="$LOG_DIR/orchestrator-${run_ts}.log"

  echo
  echo "=== ORCHESTRATOR LOOP $run_ts (UTC) ===" | tee -a "$log_file"

  codex exec \
    --sandbox workspace-write \
    -c ask_for_approval_policy="on-request" \
    -c agent.auto_actions=true \
    - < ai/agents/orchestrator.md | tee -a "$log_file"

  echo "=== SLEEPING 60s ===" | tee -a "$log_file"
  sleep 60
done
