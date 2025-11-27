# Orchestrator Decision Flow (Lean Mode)

This guide mirrors `ai/agents/orchestrator.md` but condenses it into a checklist. Use it to keep each Codex loop scoped, terse, and on objective.

## 1. Context sweep (minimum read)
1. `ai/mission.md` (only the sections relevant to the chosen task/stage)
2. `ai/company.md`
3. `ai/backlog.md`
4. `ai/state/status.json`
5. `ai/state/human_approvals.md`
6. Most recent relevant log (`ai/state/last_run.log` or targeted file under `logs/ai/`)

Skip everything else unless the backlog item explicitly cites it.

## 2. Task + mode
- Pick the first unchecked backlog item under `## Immediate`. Move to `## Short-Term` only when Immediate is empty.
- Determine mission stage: Stage 1 (homelab) is mandatory until its requirements are proven complete (GitOps manifests present + recent cluster postcheck success). Refuse Biz2/Biz3 tasks until the Architect confirms the unlock.
- Determine mode + `allowed_paths` (Hands must stay inside; Junior prefers them but may expand when needed and note it in the summary):

| Mode trigger | Allowed paths |
| --- | --- |
| Task mentions `ui` or `logs` | `ui/**`, `logs/**`, `ai/state/*.json`, `ai/backlog.md` |
| Stage 2 Biz2/Biz3 (only after unlock) | `ai/studio/**`, `ai/backlog.md`, `ai/state/*.json`, `ui/logs/public/**`, Biz2/Biz3 directories |
| Stage 1 bootstrap/infra/prox/k3s/flux/harness | `prox/**`, `infra/**`, `scripts/ai_harness.sh`, `config/**`, `logs/ai/**`, `ai/backlog.md`, sample app manifests |
| Anything else | Only the specific files referenced plus the mandatory state files |

If Hands needs to step outside `allowed_paths`, stop. Junior may expand scope when necessary; if expansion touches red-line areas (DNS/Cloudflare/PVC/VM/secret/tunnel), stop and seek approval. Never read `ai/studio/**` while Stage 1 is in progress.

## 3. Persona selection
- **Hands**: localized diagnostics or edits; max 3 attempts.
- **Junior**: multi-file edits, scaffolding, automation, or when Hands escalates.
- **Architect**: backlog/charter/design adjustments. Never runs commands.
- **Robo-Kyle**: advisory comments only, triggered by Architect.
- **Narrative**: separate summarizer invoked only when a cinematic recap is requested.

## 4. Execution
- Stay on the chosen backlog item—no mid-run pivots.
- Use only the tools required for this task (shell, fs, git). No repo-wide `rg` unless the objective is a discovery.
- Before each command, confirm it touches only `allowed_paths` or approved hosts.
- Hands stops after three failures and logs the escalation handoff line. Junior must acknowledge the escalation before acting.

## 5. Logging (stdout)
Every run prints:

```
=== Orchestrator Run (UTC timestamp) ===
Persona: <name>
Task: <exact line>

CMD <persona> <command>
RES <persona> <≤2 line result>

FILE <persona> <path> – <one-line reason>

SUMMARY:
- …
```

Nothing else belongs in stdout. Raw command transcripts live only in `ai/state/last_run.log`. Narrative logs are written later by the Narrative persona.

## 6. State + git updates
- `ai/state/status.json` – persona, task, iteration, timestamp, `last_exit_reason`.
- `ai/backlog.md` – mark `[x]` on success only.
- `ai/state/last_run.log` – full technical transcript (commands, stdout/stderr, context notes).
- `ai/state/human_approvals.md` – append pending approvals and pause if blocked.
- `logs/ai/hands-<timestamp>.log` – only when Hands records a failure.
- Git – if files changed, `git add -A`, `git commit -m "orchestrator: <persona> <short summary>"`, `git push`.

## 7. Exit reasons
- `success` – task complete; backlog checked.
- `stuck` – retry needed; document blocker.
- `human_required` – approval logged and run paused.
- `error` – unexpected failure recorded; next run picks up from the same task/iteration.

## 8. Git workflow (AI)
1. `git fetch --all --prune` and `git checkout main && git pull` before editing.
2. For feature work, create a branch named `ai/<short-purpose>-<yyyymmdd>` and base it on `main`.
3. Keep changes scoped to mission-allowed directories. No edits to `config/env/` or human-only manifests.
4. `git add -A`, write descriptive commits, and push the branch (`git push -u origin ai/<slug>-<date>`).
5. Open a PR into `main` summarizing the task and files touched. Human/automation merges it.
6. Never push directly to `main` unless a human explicitly calls for a hotfix.

Keep this checklist open next to the orchestrator prompt so each loop stays lean and predictable.
