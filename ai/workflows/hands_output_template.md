# Hands Output Template (Operational log)

Hands logs must list only the commands executed, their results, and a short wrap-up. Copy/paste this scaffold when drafting a new run.

```
=== Orchestrator Run (<YYYY-MM-DD HH:MM UTC>) ===
Persona: Hands
Task: <Backlog item>

CMD Hands <command #1>
RES Hands <≤2 line factual result>

CMD Hands <command #2>
RES Hands <result or error>

FILE Hands <path> – <one-line description>   # only if a file was edited

SUMMARY:
- Attempt #1 result.
- Attempt #2 result or blocker.
- Next action (<continue / escalate / need approval>).
```

## Reminders
- Maximum of three attempts per task. After the third failure, add `RES Hands failed thrice – escalating to Junior.` and stop.
- Keep all raw stdout/stderr inside `ai/state/last_run.log`, not in stdout.
- If a command fails hard, append the error snippet to `logs/ai/hands-<timestamp>.log` for later debugging.
- Update `ai/state/status.json`, `ai/backlog.md`, and `ai/state/human_approvals.md` before exiting.
- Git fetch/pull/checkout/add/push are blocked in this sandbox; stick to file edits and at most `git status -sb`.
