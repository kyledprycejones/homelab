# Orchestrator Decision Flow (Lean Mode)

This guide mirrors `ai/agents/orchestrator.md` but condenses it into a checklist. Use it to keep each Codex loop scoped, terse, and on objective.

## 1. Context sweep (minimum read)
1. `ai/mission.md` (Stage 1 vs Stage 2, completion checkboxes)
2. `ai/backlog.yaml` (Stage 1 only until unlocked)
3. `ai/state/status.json` (stage, needs_human, question)
4. `ai/state/human_approvals.md`
5. Most recent relevant log (`ai/state/last_run.log` or targeted file under `logs/ai/`)

Skip everything else unless the backlog item explicitly cites it.

## 2. Task + mode
- Run `scripts/executor/stage1_backlog_sync.py` to refresh Stage 1 backlog items from repo state.
- Pick the first unchecked backlog item under `Stage 1 – Homelab Bring-Up`. Ignore Stage 2/Biz2/Biz3 items until Stage 1 is explicitly unlocked.
- Determine mission stage: Stage 1 (homelab) is mandatory until its requirements are proven complete (GitOps manifests present + recent cluster postcheck success and `stage_1_complete` true). Refuse Biz2/Biz3 tasks until the Planner confirms the unlock.
- Determine mode + `allowed_paths` (Executor must stay inside; Engineer prefers them but may expand when needed and note it in the summary):

| Mode trigger | Allowed paths |
| --- | --- |
| Task mentions `ui` or `logs` | `ui/**`, `logs/**`, `ai/state/*.json`, `ai/backlog.yaml` |
| Stage 2 Biz2/Biz3 (only after unlock) | `ai/studio/**`, `ai/backlog.yaml`, `ai/state/*.json`, `ui/logs/public/**`, Biz2/Biz3 directories |
| Stage 1 bootstrap/infrastructure/talos/flux/harness | `infrastructure/proxmox/**`, `cluster/**`, `scripts/ai_harness.sh`, `config/**`, `logs/ai/**`, `ai/backlog.yaml`, sample app manifests |
| Anything else | Only the specific files referenced plus the mandatory state files |

If Executor needs to step outside `allowed_paths`, stop. Engineer may expand scope when necessary; if expansion touches red-line areas (DNS/Cloudflare/PVC/VM/secret/tunnel), stop and seek approval. Never read `ai/studio/**` while Stage 1 is in progress.

## 3. Persona selection
- **Executor**: localized diagnostics or edits; max 3 attempts.
- **Engineer**: multi-file edits, scaffolding, automation, or when Executor escalates.
- **Planner**: backlog/charter/design adjustments. Never runs commands.
- **Robo-Kyle**: advisory comments only, triggered by Planner.
- **Narrative**: separate summarizer invoked only when a cinematic recap is requested.

## 4. Execution
- Stay on the chosen backlog item—no mid-run pivots.
- Use only the tools required for this task (shell, fs, git). No repo-wide `rg` unless the objective is a discovery.
- Before each command, confirm it touches only `allowed_paths` or approved hosts.
- Executor stops after three failures and logs the escalation handoff line. Engineer must acknowledge the escalation before acting.

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

## 6. State updates
- `ai/state/status.json` – persona, task, iteration, timestamp, `last_exit_reason`.
- `ai/backlog.yaml` – mark `[x]` on success only.
- `ai/state/last_run.log` – full technical transcript (commands, stdout/stderr, context notes).
- `ai/state/human_approvals.md` – append pending approvals and pause if blocked.
- `logs/executor/executor-<timestamp>.log` – only when Executor records a failure.

Git ops (fetch/pull/checkout/add/push) are sandbox-blocked; treat git internals as read-only. If needed, a single `git status -sb` is acceptable, but focus on file edits.

## 7. Exit reasons
- `success` – task complete; backlog checked.
- `stuck` – retry needed; document blocker.
- `human_required` – approval logged and run paused.
- `error` – unexpected failure recorded; next run picks up from the same task/iteration.

## 8. Git workflow (AI)
- Skip git fetch/pull/checkout/add/push; sandbox forbids git internals.
- Assume current working tree; no branching/PRs from here. Humans handle commits/pushes outside the sandbox.

Keep this checklist open next to the orchestrator prompt so each loop stays lean and predictable.
