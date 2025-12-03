# AI Control Plane

This directory houses the AI company personas (Planner, Engineer, Executor, Robo-Kyle, Narrative), orchestrator, state, backlog, and studio scaffolding. Use `ai/agents/orchestrator.md` as the Codex CLI entrypoint and manage approvals via `ai/state/human_approvals.md`.

## Model tiers
- `chatgpt-mini` (remote) powers planning personas: Planner, Orchestrator coordination, and Narrative recaps.
- `qwen2.5-coder:7b` (local) is the default Engineer coder for all repo-wide edits.
- `deepseek-coder` (local) is the Executor fast shell/diagnostics runner.

## Logging contracts
- All runs print the `CMD/RES/FILE/SUMMARY` block described in `ai/agents/orchestrator.md`.  
- `ai/state/last_run.log` archives the full technical transcript (commands, stdout/stderr).  
- `logs/ai/narrative-<timestamp>.log` captures the cinematic recap when the Narrative persona is invoked.

## Personas
- **Planner** – high-level planner (no commands or code). Aligns with `ai/mission.md`, manages backlog/charter, approves stage transitions.
- **Engineer** – repo surgeon. Reads only the files cited by the mission/objective, edits YAML/scripts/docs within allowed paths, obeys branch workflow `ai/<slug>-<yyyymmdd>`.
- **Executor** – runs commands/diagnostics inside the allowed scope; no refactors, no secrets.
- **Narrative** – optional log summarizer (never runs tools).

Full prompt text lives under `ai/agents/`.

## Backlog + Harness
- `ai/backlog.yaml` – single source of Stage 1 tasks (BACKLOG_v1, S1-xxx).
- `ai/state/` – state files for long-running CLI loops (current_task.json, metrics.json, last_run.log).
- `logs/executor/` – per-run logs for Executor/CLI loops.
- `scripts/ai_harness.sh` – orchestrator entrypoint; documents the backlog/state/log contract and will drive unattended runs.
- `ai/golden_trail.md` – higher-level tracker with ACTIVE_TASKS and J↔A summaries.

## Safe edit boundaries
- **Allowed for AI edits**: `ai/**`, `cluster/kubernetes/**`, `cluster/talos/**`, `infrastructure/proxmox/**` (scripts only), `scripts/**`, `docs/**`, `ui/logs/**` (static assets), mission/backlog files.
- **Read-only**: `config/env/**` (secrets), Kubernetes Secret manifests, `cluster/kubernetes/platform/ingress/cloudflared/deployment.yaml`, low-level bootstrap binaries, any file explicitly tagged “human only”.
- **Stage 1 vs Stage 2**: Stage 1 tasks must not touch `ai/studio/**` (Biz2/Biz3). Stage 2 tasks must stay inside AI Studio assets unless the backlog explicitly requires an infra fix.

## Branch workflow
- Canonical branch = `main`. Always sync it before starting new work.
- AI-created branches must follow `ai/<short-purpose>-<yyyymmdd>` (example: `ai/cloudflared-20251127`) and be based on `main`.
- Standard flow: checkout `main` → create new `ai/...` branch → make scoped changes → `git add/commit` → push branch → open PR → human/automation merges to `main`.
- Never push directly to `main` unless a human explicitly requests a hotfix.
