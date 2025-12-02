# AI Studio (Biz2/Biz3 Incubator)

Local multi-agent “studio” for ideating and prototyping AI projects on the homelab (Ollama-first, optional cloud LLMs).

## Key Files & Folders
- `config.yaml` – agents/LLMs/tools skeleton (JSON-flavored YAML so it can be parsed without PyYAML).
- `backlog.md` – ideation queue; now tracks Biz2 scaffolding work.
- `projects/` – houses Biz2/Biz3 charters (see `projects/biz2/`).
- `memory/`, `news_digest/`, `reports/` – shared storage for inputs/outputs.
- `main.py` – placeholder entrypoint soon to evolve into a workflow runner.

## Getting Started
1. Read `projects/biz2/README.md` for mission/guardrails.
2. Pick a box from `projects/biz2/scaffolding_checklist.md` and log progress in `ai/studio/backlog.md`.
3. Run `python3 ai/studio/main.py --workflow overview` to confirm the CLI scaffold is wired up.
4. Keep generated artifacts under `memory/` or `reports/`, leaving templates tracked in Git.

Executor can extend/debug this once infra is stable; Engineer owns the roadmap until workflows exist.
