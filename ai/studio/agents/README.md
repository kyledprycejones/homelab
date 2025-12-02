# AI Studio Agents

Agent prompt kits / modules live here. Each persona should have:
- a charter summary pulled from `projects/biz2/README.md`,
- default tools (shell/fs/git) as defined in `config.yaml`,
- handoff guidance (what artifacts to drop into `memory/` or `reports/`).

Minimum Biz2 set:
1. **PM** – backlog triage + research questions.
2. **Planner** – systems constraints, env + tooling guardrails.
3. **Engineer** – prototype execution details.
4. **Researcher** – data gathering + digest writing.
5. **Marketer** – packaging outputs for Biz3/leadership.

Actual Python modules or prompt files can be added incrementally. Use the checklist in `projects/biz2/scaffolding_checklist.md` to decide the next addition.
