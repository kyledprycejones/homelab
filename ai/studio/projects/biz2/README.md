# Biz2: AI Studio Charter

## Mission
Deliver a local-first research and prototyping lab that lets Funoffshore rapidly spin up AI-powered services using homelab compute (Ollama-first, optional cloud). Biz2 exists to validate new business ideas quickly, gather data, and graduate the promising ones into production Biz lines.

## Outcomes
- Provide a standard multi-agent harness (PM + Planner + Engineer + Researcher + Marketer) wired into `ai/studio`.
- Ship a repeatable workflow for daily digests, opportunity scouting, and experiment tracking.
- Maintain a rolling backlog of experiments plus lightweight reports for leadership.

## Scope & Guardrails
- Operates entirely from `/ai/studio`, using local YAML config + Git-tracked artifacts.
- Uses k3s/Flux installs only when needed for demos; otherwise stays in userland.
- Keeps raw data (news, research feeds) under `ai/studio/memory/` or `ai/studio/news_digest/`.
- Avoids external network calls unless explicitly approved and proxied.

## Technical Pillars
1. **Configuration**: `config.yaml` enumerates LLM backends, agents, and tool permissions.
2. **Workflows**: `ai/studio/workflows/` holds orchestrated scripts (daily digests, prototype loops).
3. **Agents**: `ai/studio/agents/` stores persona-specific prompt kits or scripts.
4. **Projects**: `ai/studio/projects/` stores charters, experiment briefs, and outcome reports.
5. **Memory & Reports**: `memory/`, `reports/`, and `news_digest/` capture raw inputs and packaged outputs.

## Milestones
1. Publish scaffolding checklist + backlog updates.
2. Stand up a runnable `python ai/studio/main.py --workflow daily-digest` stub.
3. Deliver first digest/prototype using local Ollama models.
4. Integrate Biz2 learnings into Biz3 or production apps.

## Dependencies
- Homelab must have Ollama models installed (Qwen2, DeepSeek Coder as baseline).
- `scripts/ai_harness.sh` should be stable enough to run `ai/studio` workflows locally.
- Biz3 research backlog (DevRel) will consume Biz2 outputs once available.

## Next Actions
See `scaffolding_checklist.md` for a concrete punch list grounded in current repo state.
