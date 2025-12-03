# Executor helpers

This directory now holds small helpers used by the Codex CLI loop:

- `run_summary.py` – emits a compact human + JSON summary for each loop run (used by `scripts/codex_loop.sh` and `scripts/ai_harness.sh`).
- `stream_limiter.sh` – trims noisy stdout when `AI_VERBOSITY=normal` while preserving the full log on disk.
- `stage1_backlog_sync.py` – keeps `ai/backlog.yaml` Stage 1 items aligned with repo state (runs before each orchestrator loop).

These keep the CLI lean while still capturing full context in `logs/ai/`.
