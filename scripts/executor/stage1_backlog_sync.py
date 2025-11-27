#!/usr/bin/env python3
"""
Auto-maintain the Stage 1 backlog based on repo state.

- Ensures Stage 1 tasks are present under "Stage 1 – Homelab Bring-Up".
- Marks tasks as done only when clearly satisfied; otherwise leaves them open.
- Preserves Stage 2/Biz2/Biz3 section but keeps it locked.

This runs locally inside the sandbox; git operations are out of scope.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

REPO_ROOT = Path(__file__).resolve().parents[2]
BACKLOG_PATH = REPO_ROOT / "ai" / "backlog.md"


def has_files(path: Path, pattern: str = "*.yaml") -> bool:
    if not path.exists():
        return False
    for child in path.rglob(pattern):
        if child.name != ".gitkeep":
            return True
    return False


def has_more_than_keep(path: Path) -> bool:
    if not path.exists():
        return False
    for child in path.rglob("*"):
        if child.is_file() and child.name != ".gitkeep":
            return True
    return False


@dataclass
class Stage1Task:
    key: str
    line: str

    def auto_done(self, root: Path) -> bool:
        # Lightweight heuristics to detect clearly satisfied scaffolding.
        if self.key == "cloudflared":
            base = root / "infra" / "k8s" / "cloudflared"
            return all((base / name).exists() for name in ("config.yaml", "deployment.yaml", "kustomization.yaml", "namespace.yaml"))
        if self.key == "ingress":
            return has_files(root / "infra" / "k8s" / "ingress")
        if self.key == "monitoring":
            mon = root / "infra" / "k8s" / "monitoring"
            return has_files(mon) and has_more_than_keep(mon)
        if self.key == "media-apps":
            media = root / "infra" / "apps" / "media"
            return has_more_than_keep(media)
        if self.key == "logging":
            log = root / "infra" / "k8s" / "logging"
            return has_files(log) and has_more_than_keep(log)
        if self.key == "authentik":
            auth = root / "infra" / "apps" / "tools" / "authentik"
            return has_more_than_keep(auth)
        return False


TASKS: List[Stage1Task] = [
    Stage1Task("cloudflared", "Cloudflared tunnel manifests (ConfigMap/Deployment kustomization)"),
    Stage1Task("ingress", "Ingress / Traefik wiring for sample apps"),
    Stage1Task("monitoring", "Monitoring stack (Prometheus / Grafana / Loki) scaffolding"),
    Stage1Task("media-apps", "Sample media apps (Arrs, Jellyfin, qBittorrent, etc.) manifests"),
    Stage1Task("logging", "Observability/logging stability for CLI loops"),
    Stage1Task("authentik", "Authentik ingress and SSO wiring"),
]


def parse_existing_stage(lines: List[str], header: str) -> List[str]:
    start = None
    for idx, line in enumerate(lines):
        if line.strip().lower().startswith(header.lower()):
            start = idx
            break
    if start is None:
        return []
    end = len(lines)
    for idx in range(start + 1, len(lines)):
        if lines[idx].startswith("## "):
            end = idx
            break
    return lines[start:end]


def extract_status_map(stage_lines: List[str]) -> Dict[str, bool]:
    status: Dict[str, bool] = {}
    for line in stage_lines:
        m = re.match(r"- \[( |x)\] (.+)", line.strip())
        if m:
            status[m.group(2).strip()] = m.group(1) == "x"
    return status


def render_stage1(existing: Dict[str, bool]) -> List[str]:
    out = ["## Stage 1 – Homelab Bring-Up"]
    out.append("<!-- Auto-managed by stage1_backlog_sync.py; edit task text with care. -->")
    for task in TASKS:
        auto_done = task.auto_done(REPO_ROOT)
        done = existing.get(task.line, None)
        if done is None:
            done = auto_done
        checkbox = "x" if done else " "
        out.append(f"- [{checkbox}] {task.line}")
    return out


def render_stage2(stage2_lines: List[str]) -> List[str]:
    out = ["## Stage 2 – Biz2/Biz3 (Locked)"]
    kept = []
    for line in stage2_lines:
        if line.startswith("## "):
            continue
        if line.strip():
            kept.append(line.rstrip())
    if kept:
        out.extend(kept)
    else:
        out.extend(
            [
                "- [ ] Biz2 R&D pipeline",
                "- [ ] Biz3 Research / DevRel division",
            ]
        )
    return out


def main() -> None:
    if not BACKLOG_PATH.exists():
        raise SystemExit(f"Missing backlog at {BACKLOG_PATH}")

    lines = BACKLOG_PATH.read_text().splitlines()
    stage1_lines = parse_existing_stage(lines, "## Stage 1")
    stage2_lines = parse_existing_stage(lines, "## Stage 2")
    existing_status = extract_status_map(stage1_lines)

    new_lines: List[str] = ["# Backlog", ""]
    new_lines.extend(render_stage1(existing_status))
    new_lines.append("")
    new_lines.extend(render_stage2(stage2_lines))
    new_lines.append("")

    BACKLOG_PATH.write_text("\n".join(new_lines))


if __name__ == "__main__":
    main()
