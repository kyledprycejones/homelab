# AI State

Runtime state files created by the orchestrator. Not versioned (see `.gitignore`).

Files created at runtime:
- `errors.json` — Per-error attempt tracking
- `stage_status.json` — Stage completion status
- `router_state.json` — Provider health and episode routes
- `drift.json` — v7 drift measurement (when enabled)

These files are recreated on first run.
