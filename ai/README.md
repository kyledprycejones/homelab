# AI Control Plane

This directory houses the AI personas (Planner, Executor, Narrative), orchestrator, state, backlog, and studio scaffolding. The v7.2 contract lives in `docs/orchestrator_v7_2.txt`.

## Model tiers
- `chatgpt-mini` (remote) powers the planner and narrative recaps.
- `qwen-2.5:7b-coder` (local) is the default executor runner for infrastructure scripts.
- `deepseek-coder` (local) is the fast shell/diagnostics runner.

## Logging contracts
- All runs print the `CMD/RES/FILE/SUMMARY` block described in `ai/agents/orchestrator.md`.  
- `ai/state/last_run.log` archives the full technical transcript (commands, stdout/stderr).  
- `logs/ai/narrative-<timestamp>.log` captures the cinematic recap when the Narrative persona is invoked.

## Personas
- **Planner** – synthesizes tasks only; no commands or code edits. Aligns with `ai/mission.md` and manages backlog structure.
- **Executor** – runs backlog tasks via the harness; no refactors or self-modifying logic.
- **Narrative** – optional log summarizer (never runs tools).

Full prompt text lives under `ai/agents/`.

## Backlog + Harness
- `ai/backlog.yaml` – single source of Stage 1 tasks (BACKLOG_v1, S1-xxx).
- `ai/state/` – state files for long-running CLI loops (current_task.json, metrics.json, last_run.log).
- `logs/executor/` – per-run logs for Executor/CLI loops.
- `scripts/ai_harness.sh` – orchestrator entrypoint; documents the backlog/state/log contract and will drive unattended runs.
- `ai/golden_trail.md` – higher-level tracker with ACTIVE_TASKS and J↔A summaries.

## Model Router & Provider Notes

### Local Provider: Ollama
- Ollama is the sole local execution backend (v7 directive; LM Studio is removed).
- Verify models exist: `ollama list`
- Required models:
  - `qwen-2.5:7b-coder` — Primary executor (code capability)
  - `qwen2.5:7b-instruct` — Local architect / reasoning provider
- Health check: `./ai/providers/ollama.sh health`
- Default endpoint: `http://localhost:11434`

### Router Configuration
- Router decisions and circuit breakers live under `logs/router/router.log` and `ai/state/router_state.json`.
- Inspect current mapping: `ai/model_router.sh select <role> <error_key>`
- Override router defaults with environment variables:
  - `MODEL_ROUTER_CONFIG` (defaults to `ai/config/model_router.yaml`)
  - `MODEL_ROUTER_CMD`
  - `OLLAMA_ENDPOINT` (default: `http://localhost:11434`)
  - `OLLAMA_PRIMARY_MODEL` (default: `qwen-2.5:7b-coder`)
  - `OLLAMA_FALLBACK_MODEL` (default: `qwen-2.5:7b-coder`; override when you need alternate executor/inference models)
  - `OPENROUTER_MODEL`, `OPENROUTER_PROVIDER_CMD`

### Safety & Observability
- Safe mode is a manual loop-level halt (see `docs/orchestrator_v7_2.txt`); helper scripts do not enforce it.
- Summary written to `ai/state/safe_mode_summary.json`; reason logged to `ai/issues.yaml`.

## Safe edit boundaries
- **Allowed for AI edits**: `ai/**`, `cluster/kubernetes/**`, `infrastructure/proxmox/**` (scripts only), `scripts/**`, `docs/**`, `ui/logs/**` (static assets), mission/backlog files.
- **Read-only**: `config/env/**` (secrets), Kubernetes Secret manifests, `cluster/kubernetes/platform/ingress/cloudflared/deployment.yaml`, low-level bootstrap binaries, any file explicitly tagged “human only”.
- **Stage 1 vs Stage 2**: Stage 1 tasks must not touch `ai/studio/**` (Biz2/Biz3). Stage 2 tasks must stay inside AI Studio assets unless the backlog explicitly requires an infra fix.

## Branch workflow
- Canonical branch = `main`. Always sync it before starting new work.
- AI-created branches must follow `ai/<short-purpose>-<yyyymmdd>` (example: `ai/cloudflared-20251127`) and be based on `main`.
- Standard flow: checkout `main` → create new `ai/...` branch → make scoped changes → `git add/commit` → push branch → open PR → human/automation merges to `main`.
- Never push directly to `main` unless a human explicitly requests a hotfix.
