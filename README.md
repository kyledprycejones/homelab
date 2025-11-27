# Funoffshore Homelab

Canonical repo for the Funoffshore homelab + multi-agent incubator. All automation, manifests, and AI orchestration live here so we can keep the cluster reproducible and safe.

## Canonical branch
- `main` is the only default branch. Always sync `main` before creating new work.
- AI- or automation-created branches must follow `ai/<slug>-<yyyymmdd>` (e.g., `ai/cloudflared-20251127`). Base every branch on `main`.

## Directory map
- `ai/` – mission, backlog, persona prompts, orchestrator docs, AI studio (Biz2/Biz3) scaffolding.
- `config/` – cluster configs and env overrides. **Secrets in `config/env/` stay local and must never be committed.**
- `infra/` – Kubernetes/Flux manifests (storage, cloudflared, monitoring, etc.).
- `prox/` – Proxmox + bootstrap scripts (k3s installer, cluster helpers).
- `scripts/` – local helper scripts (`ai_harness.sh`, host/bootstrap utilities).
- `logs/` – runtime logs (gitignored). Use `ui/logs/` to view summaries.
- `synology/` – NAS setup helpers.
- `ui/` – static UI/log viewer and indexer scripts.

## AI orchestration quick rules
- Personas: Architect (planning), Junior (repo edits), Hands (commands), Narrative (optional summaries). Definitions live in `ai/agents/`.
- Mission stages in `ai/mission.md` control what directories the AI may touch (Stage 1 = homelab infra only; Stage 2 = Biz2/Biz3).
- Secrets and env files (`config/env/`) are strictly human-managed. AI must never read or edit them.
- Cloudflared ingress routes live in `infra/k8s/cloudflared/config.yaml` and are the only tunnel files the AI may edit.
- Full workflow/branching rules are documented in `CONTRIBUTING.md` and `ai/README.md`.
