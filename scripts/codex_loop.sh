#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LOG_DIR="logs/ai"
mkdir -p "$LOG_DIR"

while true; do
  run_ts="$(date -u +%Y%m%d-%H%M%S)"
  run_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log_file="$LOG_DIR/orchestrator-${run_ts}.log"
  target="${TARGET:-${CLI_TARGET:-prox-n100}}"
  component="orchestrator"
  verbosity="${AI_VERBOSITY:-normal}"

  # Auto-sync Stage 1 backlog before each loop.
  scripts/executor/stage1_backlog_sync.py || true

  echo
  echo "=== ORCHESTRATOR LOOP $run_ts (UTC) ===" | tee -a "$log_file"

  set +e
  if [ "$verbosity" = "verbose" ]; then
    codex exec \
      --sandbox workspace-write \
      -c ask_for_approval_policy="on-request" \
      -c agent.auto_actions=true \
      - < ai/agents/orchestrator.md | tee -a "$log_file"
    pipe_status=("${PIPESTATUS[@]}")
  else
    codex exec \
      --sandbox workspace-write \
      -c ask_for_approval_policy="on-request" \
      -c agent.auto_actions=true \
      - < ai/agents/orchestrator.md | tee -a "$log_file" | scripts/executor/stream_limiter.sh
    pipe_status=("${PIPESTATUS[@]}")
  fi
  set -e
  run_rc=${pipe_status[0]:-0}

  scripts/executor/run_summary.py \
    --run-id "$run_iso" \
    --run-label "$run_ts" \
    --log-file "$log_file" \
    --target "$target" \
    --component "$component" \
    --stage "stage_1" \
    --exit-code "$run_rc" \
    --status-file "ai/state/status.json" \
    --backlog-file "ai/backlog.md" \
    --last-run-file "ai/state/last_run.log" \
    --summary-limit 5 || true

  echo "=== SLEEPING 60s ===" | tee -a "$log_file"
  sleep 60
done
