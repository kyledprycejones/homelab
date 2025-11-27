# chatgpt → sidebar memo (Corrected & Final)

Local-Only File Editing • No Git Ops • Human-Push Workflow  
This memo replaces all prior instructions. It reflects the real Codex sandbox constraints and the human-managed Git model.

## 1. Environment (truth)
Allowed:
- Edit/create/delete repo files; run local shell commands; generate diffs; record summaries/logs; use JSON/YAML tools; validate syntax/structure; read git state.

Blocked (sandbox-level):
- git fetch/pull/push/checkout/merge/rebase; modifying .git/objects or .git/refs; outbound network; GitHub/API calls; SSH actions.

## 2. Git workflow (your role)
You may modify files in the working tree. git add/commit may fail and that’s fine. Do not run remote commands or change HEAD. Human will later run `git add -A && git commit -m "ai edits day <N>" && git push origin main`.

## 3. Stage 1 (Homelab Bring-Up) duties
- Maintain repo structure (infra manifests, scripts/harnesses, prox installers, ai mission/backlog/studio scaffolding).
- Produce clean, minimal diffs; avoid sprawling changes.
- Support continuous CLI loops: no missing dirs, malformed YAML, or dependency gaps.
- Use `ai/mission.md` as truth; Stage 1 only (homelab infra). Stage 2 (Biz2/Biz3) locked.

## 4. Needs-human signaling
- When stuck: update `ai/state/status.json` with `"needs_human": true` and `"question": "<precise question>"`.
- Add sentinel to final output: `NEEDS_HUMAN_INPUT: <question>`.
- Human replies in `ai/state/human_approvals.md`; read and clear on next run.

## 5. Logging & summaries
- End of run human summary:
  ```
  === Funoffshore CLI Loop Summary ===
  Run ID: <timestamp>
  Result: <success | partial_success | blocked_stage1 | needs_human>
  Actions completed:
    - <list>
  Where progress stopped:
    - <reason>
  Suggested next step:
    - <action>
  ```
- Machine summary JSON under `logs/ai/runs/` with run_id, status, actions, backlog snapshot, stuck_on, suggested_next_step.

## 6. Network/Git errors
- Sandbox errors on fetch/checkout/index updates mean “prohibited op,” not “network blocked.” Do not retry; continue local edits.

## 7. Core guideline
Modify files locally, keep repo stable for CLI, ask for human help when needed. No network, cluster, secrets, or remote GitHub.
