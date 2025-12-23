#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
BACKLOG_PATH = REPO_ROOT / "ai" / "backlog.yaml"

BASE_ENTRIES = [
    {
        "id": "S1-PREFLIGHT-HOST",
        "stage": 1,
        "persona": "executor",
        "summary": "PREFLIGHT: verify control-plane environment",
        "detail": "Run ai/preflight/preflight_tools.sh to verify required tools and connectivity before Stage 1.",
        "target": "ai/preflight/preflight_tools.sh",
        "status": "pending",
        "attempts": 0,
        "max_attempts": 1,
        "depends_on": [],
        "note": "Ensure host ready before lint/apply",
    },
    {
        "id": "S1-LINT-BACKLOG",
        "stage": 1,
        "persona": "executor",
        "summary": "LINT: validate backlog and targets",
        "detail": "Execute ai/scripts/lint_backlog.sh to confirm backlog schema, task ids, and target paths before apply.",
        "target": "ai/scripts/lint_backlog.sh",
        "status": "pending",
        "attempts": 0,
        "max_attempts": 1,
        "depends_on": ["S1-PREFLIGHT-HOST"],
        "note": "",
    },
    {
        "id": "S1-APPLY-BOOTSTRAP",
        "stage": 1,
        "persona": "executor",
        "summary": "APPLY: bootstrap infrastructure",
        "detail": "Run infrastructure/proxmox/cluster_bootstrap.sh for Stage 1 apply.",
        "target": "infrastructure/proxmox/cluster_bootstrap.sh",
        "status": "pending",
        "attempts": 0,
        "max_attempts": 3,
        "depends_on": ["S1-LINT-BACKLOG"],
        "note": "",
    },
    {
        "id": "S1-VALIDATE-BOOTSTRAP",
        "stage": 1,
        "persona": "executor",
        "summary": "VALIDATE: verify bootstrap results",
        "detail": "Validate cluster state after apply using infrastructure/proxmox/check_cluster.sh.",
        "target": "infrastructure/proxmox/check_cluster.sh",
        "status": "pending",
        "attempts": 0,
        "max_attempts": 3,
        "depends_on": ["S1-APPLY-BOOTSTRAP"],
        "note": "",
    },
]


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
    allowed_statuses = {"pending", "running", "review", "blocked", "success", "failed"}
    if entry.setdefault("status", "pending") not in allowed_statuses:
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
    for template in BASE_ENTRIES:
        if ensure_entry(backlog, template):
            changed = True
    if changed:
        backlog.sort(key=lambda e: (int(e.get("stage", 0)), str(e.get("id", ""))))
        yaml_safe_dump(backlog)
        print("SYNC: changed; ensured stage 1 backlog entries")


def main() -> None:
    sync()


if __name__ == "__main__":
    main()
