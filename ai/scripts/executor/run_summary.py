#!/usr/bin/env python3
"""
Generate a concise run summary (human + JSON) for Codex/CLI loops.

Inputs:
- run_id: ISO8601-ish timestamp for this loop (used in JSON + filenames)
- log_file: primary log to scan for summary nuggets
- target: cluster/host name (optional)
- component: orchestrator, ai_harness, etc. (optional, defaults to orchestrator)
- exit_code: numeric exit status (defaults to 0/success)
- status_file: ai/state/status.json (optional hint for last_exit_reason)
    - backlog_file: ai/backlog.yaml (for backlog snapshot)
- last_run_file: ai/state/last_run.log (optional; overwritten with the human summary)

Outputs:
- logs/ai/runs/run-<run_label>.json (machine-readable summary)
- logs/ai/runs/run-<run_label>.txt (human-readable summary)
- ai/state/last_run.log (updated with the same human summary when provided)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Sequence
import yaml


REPO_ROOT = Path(__file__).resolve().parents[3]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Emit a run summary for CLI loops.")
    parser.add_argument("--run-id", required=False, help="ISO-like run identifier. Defaults to current UTC time.")
    parser.add_argument("--run-label", required=False, help="Label used in filenames; defaults to timestamp compact form.")
    parser.add_argument("--log-file", required=True, help="Primary log file for this loop.")
    parser.add_argument("--target", default="unknown", help="Target cluster/host name.")
    parser.add_argument("--component", default="orchestrator", help="Component producing the log (orchestrator, ai_harness, etc.).")
    parser.add_argument("--stage", default=None, help="Stage identifier (e.g., stage_1). Defaults from status.json or stage_1.")
    parser.add_argument("--tasks-attempted", action="append", default=None, help="Tasks attempted this run (can repeat).")
    parser.add_argument("--tasks-completed", action="append", default=None, help="Tasks completed this run (can repeat).")
    parser.add_argument("--exit-code", type=int, default=0, help="Exit code from the loop runner.")
    parser.add_argument("--status-file", default="ai/state/status.json", help="Optional status.json for hints.")
    parser.add_argument("--backlog-file", default="ai/backlog.yaml", help="Backlog YAML to snapshot.")
    parser.add_argument("--last-run-file", default="ai/state/last_run.log", help="Where to write the human summary; empty to skip.")
    parser.add_argument("--summary-limit", type=int, default=5, help="Max items to keep in summary/backlog snapshots.")
    return parser.parse_args()


def load_status(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def parse_backlog(path: Path, limit: int) -> List[dict]:
    items: List[dict] = []
    if not path.exists():
        return items
    try:
        entries = yaml.safe_load(path.read_text()) or []
    except Exception:
        return items
    for entry in entries:
        if len(items) >= limit:
            break
        task_id = entry.get("task_id", "unknown")
        status = entry.get("status", "pending")
        desc = entry.get("description", "").strip()
        line = f"- [{status}] {task_id}: {desc}"
        checked = status not in {"pending", "waiting_retry", "running"}
        items.append({"line": line, "checked": checked})
    return items


def extract_summary_lines(lines: Sequence[str], limit: int) -> List[str]:
    bullets: List[str] = []
    # Prefer explicit SUMMARY bullets.
    for idx, line in enumerate(lines):
        if line.strip().upper().startswith("SUMMARY"):
            for follow in lines[idx + 1 :]:
                if follow.strip().startswith("-"):
                    bullets.append(follow.strip().lstrip("- ").strip())
                elif bullets and follow.strip():
                    break
                elif not follow.strip():
                    if bullets:
                        break
            if bullets:
                return bullets[:limit]
    # Fall back to FILE lines for quick change notes.
    for line in lines:
        if line.startswith("FILE "):
            bullets.append(line.split("FILE ", 1)[1].strip())
        if len(bullets) >= limit:
            return bullets
    # As a last resort, pick notable RES failures.
    for line in lines:
        if line.startswith("RES ") and any(w in line.lower() for w in ("fail", "error", "blocked")):
            bullets.append(line.strip())
        if len(bullets) >= limit:
            break
    return bullets[:limit]


def detect_stuck_on(lines: Sequence[str]) -> str:
    for line in reversed(lines):
        lower = line.lower()
        if any(word in lower for word in ("fail", "error", "blocked", "missing", "timeout", "denied")):
            return line.strip()
    return ""


def detect_next_step(lines: Sequence[str]) -> str:
    for line in lines:
        if "next step" in line.lower() or "next steps" in line.lower():
            return line.strip("- ").strip()
    return ""


def gather_logs(primary: Path) -> List[str]:
    logs = [str(primary)]
    stamp = None
    m = re.search(r"(20\d{6}-\d{6})", primary.name)
    if m:
        stamp = m.group(1)
    if stamp:
        sibling_dir = primary.parent
        for candidate in sorted(sibling_dir.glob(f"*{stamp}*.log")):
            if candidate != primary and candidate.is_file():
                logs.append(str(candidate))
    return logs


def determine_status(exit_code: int, state: dict) -> str:
    reason = (state.get("last_exit_reason") or "").lower()
    mapping = {
        "success": "success",
        "ok": "success",
        "in_progress": "partial_success",
        "partial": "partial_success",
        "blocked": "failed",
        "blocked_stage1": "blocked_stage1",
        "failed": "failed",
        "error": "failed",
    }
    if reason in mapping:
        return mapping[reason]
    return "success" if exit_code == 0 else "failed"


@dataclass
class RunSummary:
    run_id: str
    run_label: str
    target: str
    component: str
    status: str
    stage: str
    tasks_attempted: List[str] = field(default_factory=list)
    tasks_completed: List[str] = field(default_factory=list)
    backlog_snapshot: List[dict] = field(default_factory=list)
    changes_summary: List[str] = field(default_factory=list)
    stuck_on: str = ""
    suggested_next_step: str = ""
    log_files: List[str] = field(default_factory=list)

    def to_json(self) -> str:
        return json.dumps(
            {
                "run_id": self.run_id,
                "target": self.target,
                "component": self.component,
                "stage": self.stage,
                "status": self.status,
                "tasks_attempted": self.tasks_attempted,
                "tasks_completed": self.tasks_completed,
                "backlog_snapshot": self.backlog_snapshot,
                "changes_summary": self.changes_summary,
                "stuck_on": self.stuck_on,
                "suggested_next_step": self.suggested_next_step,
                "log_files": self.log_files,
            },
            indent=2,
        )

    def to_text(self) -> str:
        lines = [
            "=== Funoffshore CLI Loop Summary ===",
            f"Run ID: {self.run_id}",
            f"Target: {self.target}",
            f"Stage: {self.stage}",
        ]
        if self.tasks_attempted:
            lines.append("Tasks attempted:")
            for t in self.tasks_attempted:
                lines.append(f"  - {t}")
        if self.tasks_completed:
            lines.append("Tasks completed:")
            for t in self.tasks_completed:
                lines.append(f"  - {t}")
        lines.append("Backlog items:")
        if self.backlog_snapshot:
            for item in self.backlog_snapshot:
                lines.append(f"  {item.get('line')}")
        else:
            lines.append("  (none found)")
        lines.append(f"Result: {self.status}")
        lines.append("What was done:")
        if self.changes_summary:
            for change in self.changes_summary:
                lines.append(f"  - {change}")
        else:
            lines.append("  - See logs for details.")
        lines.append("Where it got stuck:")
        lines.append(f"  - {self.stuck_on or 'n/a'}")
        lines.append("Suggested next step:")
        lines.append(f"  - {self.suggested_next_step or 'Review backlog and rerun if needed.'}")
        if self.log_files:
            lines.append(f"Logs: {', '.join(self.log_files)}")
        return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    os.chdir(REPO_ROOT)

    run_id = args.run_id
    if not run_id:
        run_id = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    run_label = args.run_label
    if not run_label:
        run_label = re.sub(r"[^0-9A-Za-zT]", "", run_id)

    log_file = Path(args.log_file)
    if not log_file.exists():
        print(f"ERROR: log file not found: {log_file}", file=sys.stderr)
        return 1

    log_lines = log_file.read_text(errors="ignore").splitlines()
    state = load_status(Path(args.status_file))
    status = determine_status(args.exit_code, state)
    stage = args.stage or state.get("stage") or "stage_1"
    tasks_attempted = args.tasks_attempted or []
    tasks_completed = args.tasks_completed or []
    if not tasks_attempted and state.get("task"):
        tasks_attempted = [state["task"]]
    if not tasks_completed and state.get("task") and status == "success":
        tasks_completed = [state["task"]]
    backlog_snapshot = parse_backlog(Path(args.backlog_file), args.summary_limit)
    changes_summary = extract_summary_lines(log_lines, args.summary_limit)
    stuck_on = detect_stuck_on(log_lines)
    suggested_next_step = detect_next_step(log_lines) or ("Check log and rerun." if stuck_on else "")
    log_files = gather_logs(log_file)

    if status == "blocked_stage1":
        default_blocker = "Advanced backlog entries are locked until Stage 1 is confirmed complete."
        if not stuck_on:
            stuck_on = default_blocker
        if not suggested_next_step:
            suggested_next_step = "Pick a Stage 1 backlog item (cloudflared, monitoring, ingress, sample apps) and advance that instead of staking future stages."

    summary = RunSummary(
        run_id=run_id,
        run_label=run_label,
        target=args.target,
        component=args.component,
        status=status,
        stage=stage,
        tasks_attempted=tasks_attempted,
        tasks_completed=tasks_completed,
        backlog_snapshot=backlog_snapshot,
        changes_summary=changes_summary,
        stuck_on=stuck_on,
        suggested_next_step=suggested_next_step,
        log_files=log_files,
    )

    runs_dir = REPO_ROOT / "logs" / "ai" / "runs"
    runs_dir.mkdir(parents=True, exist_ok=True)
    json_path = runs_dir / f"run-{run_label}.json"
    text_path = runs_dir / f"run-{run_label}.txt"
    json_path.write_text(summary.to_json())
    text_path.write_text(summary.to_text())

    if args.last_run_file:
        Path(args.last_run_file).write_text(summary.to_text())

    # Print human summary to stdout.
    sys.stdout.write(summary.to_text())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
