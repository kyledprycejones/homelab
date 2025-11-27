# Biz2 Scaffolding Checklist

## Foundations (Week 0)
- [ ] Confirm `ai/studio/config.yaml` matches available models (Ollama qwen2 + deepseek-coder) and toggle remote models only when secrets exist.
- [x] Create agent prompt kits under `ai/studio/agents/` (PM, Architect, Engineer, Researcher, Marketer) referencing the charter.
- [x] Define workflow entrypoints (daily_digest, prototype_loop) under `ai/studio/workflows/`.
- [x] Wire `ai/studio/main.py` with an argparse CLI to run a workflow stub that logs decisions to `ai/studio/reports/`.

## Data + Memory
- [x] Stand up `memory/` schema (news cache, interviews, experiment notes) with timestamped JSON/Markdown files.
- [x] Add `reports/` template for digest + experiment recap (YAML header + Markdown body).
 - [x] Capture at least one manual news digest in `news_digest/` to test file naming conventions.

## Ops + Tooling
- [ ] Document a `./scripts/ai_studio.sh` helper that shells into the studio environment with proper env vars.
- [ ] Ensure gitignore rules avoid leaking generated datasets while keeping templates tracked.
- [ ] Add automated logging guidelines (what to store in `logs/ai/studio-*`).

## Graduation Gates
- [ ] Define criteria for promoting a Biz2 experiment to "production" (hand-off doc template + owner).
- [ ] Integrate Biz2 backlog triage into `ai/backlog.md` or a dedicated cadence note.
- [ ] Establish how Biz3 will subscribe to Biz2 outputs (RSS-style files, Matrix room, etc.).

This checklist is intentionally repo-scoped so Hands or Junior personas can tackle one box per loop without external dependencies.
