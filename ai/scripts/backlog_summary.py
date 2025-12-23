#!/usr/bin/env python3
"""Summarize backlog health without relying on yq."""

from __future__ import annotations

import argparse
from collections import Counter
from pathlib import Path
from typing import Any, Dict, Iterable, List

import yaml


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Summarize backlog status and runnable tasks.")
    parser.add_argument("backlog", nargs="?", default="ai/backlog.yaml", help="Path to backlog YAML.")
    return parser.parse_args()


def load_backlog(path: Path) -> List[Dict[str, Any]]:
    if not path.exists():
        return []
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or []
    except Exception:
        return []
    if isinstance(data, list):
        return data
    return []


def count_by(field: str, entries: Iterable[Dict[str, Any]]) -> Counter:
    counter: Counter = Counter()
    for entry in entries:
        value = entry.get(field, "unknown")
        counter[str(value)] += 1
    return counter


def deps_satisfied(entry: Dict[str, Any], id_map: Dict[str, Dict[str, Any]]) -> bool:
    deps = entry.get("depends_on") or []
    if not deps:
        return True
    for dep in deps:
        target = id_map.get(dep)
        if not target or target.get("status") != "success":
            return False
    return True


def format_counter(counter: Counter, preferred: List[str]) -> str:
    parts: List[str] = []
    for key in preferred:
        parts.append(f"{key}={counter.get(key, 0)}")
    extras = [key for key in sorted(counter.keys()) if key not in preferred]
    for key in extras:
        parts.append(f"{key}={counter.get(key, 0)}")
    return " ".join(parts)


def summarize(backlog_path: Path) -> str:
    entries = load_backlog(backlog_path)
    id_map = {entry.get("id"): entry for entry in entries if entry.get("id")}

    status_counts = count_by("status", entries)
    persona_counts = count_by("persona", entries)

    runnable = [
        entry
        for entry in entries
        if entry.get("persona") == "executor"
        and entry.get("status") == "pending"
        and deps_satisfied(entry, id_map)
    ]
    runnable.sort(key=lambda e: str(e.get("id", "")))

    blocked = [entry for entry in entries if entry.get("status") == "blocked"]
    blocked.sort(key=lambda e: str(e.get("id", "")))

    lines: List[str] = []
    lines.append(f"Backlog summary: {backlog_path}")
    lines.append(f"Total tasks: {len(entries)}")
    lines.append(
        "Status counts: "
        + format_counter(status_counts, ["pending", "running", "success", "failed", "blocked"])
    )
    lines.append("Persona counts: " + format_counter(persona_counts, ["executor", "planner"]))

    lines.append(f"Runnable executor tasks (pending, deps success): {len(runnable)}")
    for entry in runnable:
        task_id = entry.get("id", "unknown")
        summary = (entry.get("summary") or "").strip()
        if summary:
            lines.append(f"- {task_id}: {summary}")
        else:
            lines.append(f"- {task_id}")

    lines.append(f"Blocked tasks: {len(blocked)}")
    for entry in blocked:
        task_id = entry.get("id", "unknown")
        metadata = entry.get("metadata") or {}
        blocked_mode = metadata.get("blocked_mode", "unknown")
        note = " ".join((entry.get("note") or "").split())
        if note:
            lines.append(f"- {task_id} blocked_mode={blocked_mode} note={note}")
        else:
            lines.append(f"- {task_id} blocked_mode={blocked_mode}")

    return "\n".join(lines)


def main() -> None:
    args = parse_args()
    backlog_path = Path(args.backlog)
    print(summarize(backlog_path))


if __name__ == "__main__":
    main()
