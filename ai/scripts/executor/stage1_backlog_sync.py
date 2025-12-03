#!/usr/bin/env python3
"""
Auto-sync Stage 1 backlog tasks inside ai/backlog.yaml.

Goal: keep Stage 1 focused on the bootstrap run + escalations, and park everything else.
"""
from __future__ import annotations

import yaml
from pathlib import Path
from typing import List, Optional

REPO_ROOT = Path(__file__).resolve().parents[3]
BACKLOG_PATH = REPO_ROOT / "ai" / "backlog.yaml"


def load_backlog() -> List[dict]:
    if not BACKLOG_PATH.exists():
        return []
    try:
        return yaml.safe_load(BACKLOG_PATH.read_text()) or []
    except Exception:
        return []


def write_backlog(entries: List[dict]) -> None:
    BACKLOG_PATH.write_text(yaml.safe_dump(entries, sort_keys=False))


def find_entry(entries: List[dict], task_id: str) -> Optional[dict]:
    for entry in entries:
        if entry.get("task_id") == task_id:
            return entry
    return None


def upsert(entries: List[dict], payload: dict, preserve_status: bool = True) -> bool:
    existing = find_entry(entries, payload["task_id"])
    if existing is None:
        entries.append(payload)
        return True

    before = yaml.safe_dump(existing, sort_keys=True)
    status = existing.get("status") if preserve_status else payload.get("status", "pending")
    existing.update(payload)
    if preserve_status and status:
        existing["status"] = status
    changed = yaml.safe_dump(existing, sort_keys=True) != before
    return changed


def main() -> None:
    backlog = load_backlog()
    changed = False
    actions: list[str] = []

    active = {
        "task_id": "S1-001-RUN",
        "type": "run",
        "persona": "executor",
        "target": "infrastructure/proxmox/cluster_bootstrap.sh",
        "description": "Run Stage 1 bootstrap for prox-n100; stop on first failure and log.",
        "status": "pending",
        "metadata": {"stage": 1, "cluster": "prox-n100"},
        "note": "executor pending",
      }
    parked = [
        {
            "task_id": "S1-authentik",
            "type": "run",
            "persona": "executor",
            "target": "",
            "description": "Authentik ingress and SSO wiring",
            "status": "blocked",
            "metadata": {"stage": 2},
            "note": "parked until bootstrap is stable",
        },
        {
            "task_id": "S1-cloudflared",
            "type": "run",
            "persona": "executor",
            "target": "",
            "description": "Cloudflared tunnel manifests (ConfigMap/Deployment kustomization)",
            "status": "blocked",
            "metadata": {"stage": 2},
            "note": "parked until bootstrap is stable",
        },
        {
            "task_id": "S1-ingress",
            "type": "run",
            "persona": "executor",
            "target": "",
            "description": "Ingress / Traefik wiring for sample apps",
            "status": "blocked",
            "metadata": {"stage": 2},
            "note": "parked until bootstrap is stable",
        },
        {
            "task_id": "S1-logging",
            "type": "run",
            "persona": "executor",
            "target": "",
            "description": "Observability/logging stability for CLI loops",
            "status": "blocked",
            "metadata": {"stage": 2},
            "note": "parked until bootstrap is stable",
        },
        {
            "task_id": "S1-media-apps",
            "type": "run",
            "persona": "executor",
            "target": "",
            "description": "Sample media apps (Arrs, Jellyfin, qBittorrent, etc.) manifests",
            "status": "blocked",
            "metadata": {"stage": 2},
            "note": "parked until bootstrap is stable",
        },
        {
            "task_id": "S1-monitoring",
            "type": "run",
            "persona": "executor",
            "target": "",
            "description": "Monitoring stack (Prometheus / Grafana / Loki) scaffolding",
            "status": "blocked",
            "metadata": {"stage": 2},
            "note": "parked until bootstrap is stable",
        },
    ]

    if upsert(backlog, active, preserve_status=True):
        changed = True
        actions.append("upserted S1-001-RUN")

    for payload in parked:
        if upsert(backlog, payload, preserve_status=False):
            changed = True
            actions.append(f"parked {payload['task_id']}")

    if changed:
        backlog.sort(key=lambda e: (int(e.get("metadata", {}).get("stage", 1)), e.get("task_id", "")))
        write_backlog(backlog)
        summary = "; ".join(actions) or "updated backlog"
        print(f"SYNC: changed; {summary}")


if __name__ == "__main__":
    main()
