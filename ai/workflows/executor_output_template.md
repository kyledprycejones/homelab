# Executor Output Template (Operational log)

Executor logs must list only the commands executed, their results, and a short wrap-up. Copy/paste this scaffold when drafting a new run.

```
=== Orchestrator Run (<YYYY-MM-DD HH:MM UTC>) ===
Persona: Executor
Task: <Backlog item>

CMD Executor <command #1>
RES Executor <≤2 line factual result>

CMD Executor <command #2>
RES Executor <result or error>

FILE Executor <path> – <one-line description>   # only if a file was edited

SUMMARY:
- Attempt #1 result.
- Attempt #2 result or blocker.
- Next action (<continue / escalate / need approval>).
```

## Reminders
- Maximum of three attempts per task. After the third failure, add `RES Executor failed thrice – escalating to Engineer.` and stop.
- Keep all raw stdout/stderr inside `ai/state/last_run.log`, not in stdout.
- If a command fails hard, append the error snippet to `logs/executor/executor-<timestamp>.log` for later debugging.
- Update `ai/state/status.json`, `ai/backlog.yaml`, and `ai/state/human_approvals.md` before exiting.
- Git fetch/pull/checkout/add/push are blocked in this sandbox; stick to file edits and at most `git status -sb`.
