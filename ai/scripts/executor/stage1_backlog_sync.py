#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
BACKLOG_PATH = REPO_ROOT / "ai" / "backlog.yaml"

BASE_ENTRY = {
    "id": "S1-001-RUN",
    "stage": 1,
    "persona": "executor",
    "summary": "Run Stage 1 bootstrap for prox-n100",
    "detail": "Execute infrastructure/proxmox/cluster_bootstrap.sh against the prox-n100 controller, capture logs, and stop on failure.",
    "target": "infrastructure/proxmox/cluster_bootstrap.sh",
    "status": "pending",
    "attempts": 0,
    "max_attempts": 1,
    "depends_on": [],
    "note": "executor pending",
}


def yaml_safe_load() -> list[dict[str, Any]]:
    import yaml

    if not BACKLOG_PATH.exists():
        return []
    data = yaml.safe_load(BACKLOG_PATH.read_text() or "[]") or []
    if not isinstance(data, list):
        return []
    return data


def yaml_safe_dump(entries: list[dict[str, Any]]) -> None:
    import yaml

    tmp_path = BACKLOG_PATH.with_suffix(".tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        yaml.safe_dump(entries, f, sort_keys=False)
    os.replace(tmp_path, BACKLOG_PATH)


def normalize(entry: dict[str, Any]) -> None:
    entry.setdefault("note", "")
    entry.setdefault("detail", "")
    entry.setdefault("target", "")
    entry.setdefault("attempts", 0)
    entry.setdefault("max_attempts", 3)
    entry.setdefault("depends_on", [])
    if entry.setdefault("status", "pending") not in {
        "pending",
        "running",
        "success",
        "failed",
        "blocked",
        "waiting_retry",
    }:
        entry["status"] = "pending"


def ensure_entry(entries: list[dict[str, Any]], payload: dict[str, Any]) -> bool:
    for entry in entries:
        if entry.get("id") == payload.get("id"):
            return False
    entry = {**payload}
    normalize(entry)
    entries.append(entry)
    return True


def sync() -> None:
    backlog = yaml_safe_load()
    changed = False
    for entry in backlog:
        normalize(entry)
    if ensure_entry(backlog, BASE_ENTRY):
        changed = True
    if changed:
        backlog.sort(key=lambda e: (int(e.get("stage", 0)), str(e.get("id", ""))))
        yaml_safe_dump(backlog)
        print("SYNC: changed; ensured stage 1 bootstrap task")


def main() -> None:
    sync()


if __name__ == "__main__":
    main()
