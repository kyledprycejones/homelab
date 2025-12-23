#!/usr/bin/env python3
"""
Orchestrator v7 Drift Engine

Responsibilities:
- Extracts claims from architecture memos
- Evaluates claims against repository state
- Computes drift (set of FAIL claims) per lane (structural/operational)
- Persists drift state to ai/state/drift.json
- Ranks claims by safety and impact (proposes selection)

Does NOT:
- Generate patches
- Execute changes
- Make problem-solving decisions
- Apply attempt policy (Orchestrator responsibility)
"""

import hashlib
import json
import os
import re
import sys
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone, timedelta
from enum import Enum
from pathlib import Path
from typing import Optional, List


class ClaimType(str, Enum):
    STRUCTURAL = "structural"
    OPERATIONAL = "operational"


class ClaimStatus(str, Enum):
    PASS = "PASS"
    FAIL = "FAIL"
    UNKNOWN = "UNKNOWN"
    BLOCKED = "BLOCKED"


class EvaluationMethod(str, Enum):
    FILE_EXISTS = "file_exists"
    FILE_CONTENT = "file_content"
    DIR_EXISTS = "dir_exists"
    SCRIPT_BEHAVIOR = "script_behavior"
    TEST_EXISTS = "test_exists"
    # v7 P0: Stronger evaluators for gating claims
    FILE_NONEMPTY = "file_nonempty"  # File exists AND has content (>0 bytes)
    YAML_PARSEABLE = "yaml_parseable"  # File is valid YAML
    JSON_PARSEABLE = "json_parseable"  # File is valid JSON
    CONTAINS_KEY = "contains_key"  # JSON/YAML file contains a specific key with non-null value
    COMMAND_SUCCEEDS = "command_succeeds"  # Bounded command runs and exits 0
    ARTIFACT_VALID = "artifact_valid"  # Check artifacts.json for validity


class ClaimPriority(str, Enum):
    """Claim priority for selection ordering."""
    GATING = "gating"  # Must pass before stage can complete
    STRUCTURAL = "structural"  # Standard structural claims
    OPERATIONAL = "operational"  # Runtime behavior claims


@dataclass
class ClaimEvaluation:
    method: str
    target: str
    expected: Optional[str] = None
    pattern: Optional[str] = None
    # v7 P0: Additional parameters for stronger evaluators
    key_path: Optional[str] = None  # JSON/YAML key path for contains_key (e.g., "ctrl_ip" or "kubeconfig.valid")
    command: Optional[str] = None  # Command for command_succeeds
    timeout: int = 10  # Timeout in seconds for command_succeeds
    artifact_name: Optional[str] = None  # Artifact name for artifact_valid


@dataclass
class Claim:
    id: str
    type: ClaimType
    source: str
    section: str
    text: str
    evaluation: ClaimEvaluation
    status: ClaimStatus = ClaimStatus.UNKNOWN
    last_evaluated: Optional[str] = None
    evidence: Optional[str] = None
    episode: Optional[str] = None
    attempts: int = 0
    blocked_until: Optional[str] = None
    # v7: Infrastructure deferral (distinct from BLOCKED which is for failed solutions)
    defer_until: Optional[str] = None
    defer_reason: Optional[str] = None
    safety_score: float = 0.0
    impact_score: float = 0.0
    # v7 P0: Gating priority - gating claims must pass for stage completion
    priority: str = "structural"  # "gating", "structural", "operational"
    stage: Optional[str] = None  # Which stage this claim belongs to

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "type": self.type.value if isinstance(self.type, ClaimType) else self.type,
            "source": self.source,
            "section": self.section,
            "text": self.text,
            "evaluation": {
                "method": self.evaluation.method,
                "target": self.evaluation.target,
                "expected": self.evaluation.expected,
                "pattern": self.evaluation.pattern,
                "key_path": self.evaluation.key_path,
                "command": self.evaluation.command,
                "timeout": self.evaluation.timeout,
                "artifact_name": self.evaluation.artifact_name,
            },
            "status": self.status.value if isinstance(self.status, ClaimStatus) else self.status,
            "last_evaluated": self.last_evaluated,
            "evidence": self.evidence,
            "episode": self.episode,
            "attempts": self.attempts,
            "blocked_until": self.blocked_until,
            "defer_until": self.defer_until,
            "defer_reason": self.defer_reason,
            "safety_score": self.safety_score,
            "impact_score": self.impact_score,
            "priority": self.priority,
            "stage": self.stage,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "Claim":
        eval_data = data.get("evaluation", {})
        return cls(
            id=data["id"],
            type=ClaimType(data["type"]) if data.get("type") else ClaimType.STRUCTURAL,
            source=data.get("source", ""),
            section=data.get("section", ""),
            text=data.get("text", ""),
            evaluation=ClaimEvaluation(
                method=eval_data.get("method", "file_exists"),
                target=eval_data.get("target", ""),
                expected=eval_data.get("expected"),
                pattern=eval_data.get("pattern"),
                key_path=eval_data.get("key_path"),
                command=eval_data.get("command"),
                timeout=eval_data.get("timeout", 10),
                artifact_name=eval_data.get("artifact_name"),
            ),
            status=ClaimStatus(data.get("status", "UNKNOWN")),
            last_evaluated=data.get("last_evaluated"),
            evidence=data.get("evidence"),
            episode=data.get("episode"),
            attempts=data.get("attempts", 0),
            blocked_until=data.get("blocked_until"),
            defer_until=data.get("defer_until"),
            defer_reason=data.get("defer_reason"),
            safety_score=data.get("safety_score", 0.0),
            impact_score=data.get("impact_score", 0.0),
            priority=data.get("priority", "structural"),
            stage=data.get("stage"),
        )


@dataclass
class DriftLane:
    total_claims: int = 0
    pass_claims: int = 0
    fail_claims: int = 0
    unknown_claims: int = 0
    blocked_claims: int = 0
    score: float = 0.0

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class DriftState:
    memo: str
    memo_hash: str
    episode: str
    total_claims: int = 0
    pass_claims: int = 0
    fail_claims: int = 0
    unknown_claims: int = 0
    blocked_claims: int = 0
    drift_score: float = 0.0
    structural_drift: DriftLane = field(default_factory=DriftLane)
    operational_drift: DriftLane = field(default_factory=DriftLane)
    last_measured: Optional[str] = None
    claims: list = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "memo": self.memo,
            "memo_hash": self.memo_hash,
            "episode": self.episode,
            "total_claims": self.total_claims,
            "pass_claims": self.pass_claims,
            "fail_claims": self.fail_claims,
            "unknown_claims": self.unknown_claims,
            "blocked_claims": self.blocked_claims,
            "drift_score": self.drift_score,
            "structural_drift": self.structural_drift.to_dict(),
            "operational_drift": self.operational_drift.to_dict(),
            "last_measured": self.last_measured,
            "claims": [c.to_dict() if isinstance(c, Claim) else c for c in self.claims],
        }


class DriftEngine:
    """
    v7 Drift Engine - Core claims extraction and evaluation component.
    """

    def __init__(self, repo_root: str, state_dir: str = "ai/state"):
        self.repo_root = Path(repo_root)
        self.state_dir = self.repo_root / state_dir
        self.drift_file = self.state_dir / "drift.json"
        self.now_file = self.state_dir / "now.json"
        self.timeline_file = self.state_dir / "timeline.json"
        self.stage_contracts_file = self.repo_root / "ai/config/stage_contracts.yaml"
        self.cluster_identity_file = self.state_dir / "cluster_identity.json"
        self.artifacts_file = self.state_dir / "artifacts.json"

        # Protected files that patches cannot modify (v7 canonical list)
        # Source of truth: ai/config/config.yaml (protected_files)
        # Keep in sync with bootstrap_loop.sh
        self.protected_files = [
            "docs/master_memo.txt",
            "docs/master_memo.md",
            "ai/context_map.yaml",
            "ai/bootstrap_loop.sh",
            "ai/drift_engine.py",
            "infrastructure/proxmox/wipe_proxmox.sh",
        ]

        # Ensure state directory exists
        self.state_dir.mkdir(parents=True, exist_ok=True)

    def compute_memo_hash(self, memo_path: str) -> str:
        """Compute SHA-256 hash of memo file."""
        full_path = self.repo_root / memo_path
        if not full_path.exists():
            return ""
        content = full_path.read_text()
        return hashlib.sha256(content.encode()).hexdigest()[:16]

    def compute_claim_id(self, memo_hash: str, claim_text: str, target: str) -> str:
        """Compute stable, hash-based claim ID."""
        composite = f"{memo_hash}:{claim_text}:{target}"
        hash_val = hashlib.sha256(composite.encode()).hexdigest()[:16]
        return f"claim_{hash_val}"

    def generate_episode_id(self) -> str:
        """Generate episode identifier from current timestamp."""
        now = datetime.now(timezone.utc)
        return f"episode_{now.strftime('%Y%m%d_%H%M%S')}"

    def load_drift_state(self) -> Optional[DriftState]:
        """Load current drift state from file."""
        if not self.drift_file.exists():
            return None
        try:
            with open(self.drift_file) as f:
                data = json.load(f)
            claims = [Claim.from_dict(c) for c in data.get("claims", [])]
            return DriftState(
                memo=data.get("memo", ""),
                memo_hash=data.get("memo_hash", ""),
                episode=data.get("episode", ""),
                total_claims=data.get("total_claims", 0),
                pass_claims=data.get("pass_claims", 0),
                fail_claims=data.get("fail_claims", 0),
                unknown_claims=data.get("unknown_claims", 0),
                blocked_claims=data.get("blocked_claims", 0),
                drift_score=data.get("drift_score", 0.0),
                structural_drift=DriftLane(**data.get("structural_drift", {})),
                operational_drift=DriftLane(**data.get("operational_drift", {})),
                last_measured=data.get("last_measured"),
                claims=claims,
            )
        except (json.JSONDecodeError, KeyError) as e:
            print(f"[drift-engine] Warning: Failed to load drift state: {e}", file=sys.stderr)
            return None

    def save_drift_state(self, state: DriftState) -> None:
        """Save drift state to file atomically."""
        temp_file = self.drift_file.with_suffix(".tmp")
        with open(temp_file, "w") as f:
            json.dump(state.to_dict(), f, indent=2)
        temp_file.rename(self.drift_file)

    def append_timeline(self, state: DriftState, claim_id: Optional[str] = None,
                        patch_applied: bool = False, drift_delta: float = 0.0) -> None:
        """Append entry to timeline.json."""
        timeline = []
        if self.timeline_file.exists():
            try:
                with open(self.timeline_file) as f:
                    timeline = json.load(f)
            except json.JSONDecodeError:
                timeline = []

        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "episode": state.episode,
            "drift_score": state.drift_score,
            "structural_drift": {"score": state.structural_drift.score},
            "operational_drift": {"score": state.operational_drift.score},
            "claim_id": claim_id,
            "patch_applied": patch_applied,
            "drift_delta": drift_delta,
        }
        timeline.append(entry)

        with open(self.timeline_file, "w") as f:
            json.dump(timeline, f, indent=2)

    def update_now_state(self, active_claim: Optional[str] = None,
                         last_patch: Optional[str] = None,
                         attempt_count: int = 0,
                         bootstrap_window: bool = False,
                         provider_assignments: Optional[dict] = None) -> None:
        """Update current convergence state in now.json."""
        now_state = {
            "active_claim": active_claim,
            "last_patch": last_patch,
            "attempt_count": attempt_count,
            "bootstrap_window": bootstrap_window,
            "provider_assignments": provider_assignments or {},
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
        with open(self.now_file, "w") as f:
            json.dump(now_state, f, indent=2)

    def extract_claims_from_memo(self, memo_path: str, memo_hash: str, episode: str) -> list[Claim]:
        """
        Extract measurable claims from architecture memo.

        This is a heuristic extraction that looks for patterns like:
        - "X directory contains Y"
        - "X file exists"
        - "X.yaml sets Y to Z"
        - Directory structure descriptions

        For production, this would be enhanced with LLM-based extraction.
        """
        full_path = self.repo_root / memo_path
        if not full_path.exists():
            print(f"[drift-engine] Memo not found: {memo_path}", file=sys.stderr)
            return []

        content = full_path.read_text()
        claims = []
        current_section = "General"

        # Pattern-based claim extraction
        lines = content.split("\n")

        for i, line in enumerate(lines):
            # Track section headers
            if line.startswith("#") or (line.strip() and i > 0 and
                                         lines[i-1].strip() == "" and
                                         not line.startswith(" ") and
                                         len(line) < 80):
                current_section = line.strip("#").strip()[:50]

            # Extract file/directory existence claims
            # Pattern: "X/ directory" or "X.yaml" or "cluster/X"
            # Note: File patterns with extensions (.sh, .yaml, etc.) should use file_exists
            file_patterns = [
                # Explicit file extensions - file_exists
                (r'`?([a-zA-Z0-9_\-/]+\.ya?ml)`?', 'file_exists'),
                (r'`?([a-zA-Z0-9_\-/]+\.sh)`?', 'file_exists'),
                (r'`?([a-zA-Z0-9_\-/]+\.py)`?', 'file_exists'),
                (r'`?([a-zA-Z0-9_\-/]+\.json)`?', 'file_exists'),
                (r'`?([a-zA-Z0-9_\-/]+\.env)`?', 'file_exists'),
                (r'`?([a-zA-Z0-9_\-/]+\.md)`?', 'file_exists'),
                # Explicit directory patterns
                (r'`?([a-zA-Z0-9_\-/]+/)`?\s+(?:directory|folder)', 'dir_exists'),
                (r'(?:under|in)\s+`?([a-zA-Z0-9_\-/]+/)`?', 'dir_exists'),
                # Paths without extensions - assume directory
                (r'`?(cluster/[a-zA-Z0-9_\-/]+)`?(?![.\w])', 'dir_exists'),
                (r'`?(infrastructure/[a-zA-Z0-9_\-/]+)`?(?![.\w])', 'dir_exists'),
            ]

            for pattern, method in file_patterns:
                matches = re.findall(pattern, line, re.IGNORECASE)
                for match in matches:
                    target = match.strip("`").rstrip("/")
                    if target and len(target) > 3 and "/" in target:
                        claim_text = f"Path exists: {target}"
                        claim_id = self.compute_claim_id(memo_hash, claim_text, target)

                        # Determine claim type
                        claim_type = ClaimType.STRUCTURAL

                        claims.append(Claim(
                            id=claim_id,
                            type=claim_type,
                            source=memo_path,
                            section=current_section,
                            text=claim_text,
                            evaluation=ClaimEvaluation(
                                method=method,
                                target=target,
                            ),
                            episode=episode,
                        ))

        # Add some canonical structural claims based on the memo structure
        canonical_paths = [
            ("cluster/kubernetes", "dir_exists", "Kubernetes manifests directory exists"),
            ("infrastructure/proxmox", "dir_exists", "Proxmox infrastructure directory exists"),
            ("config/clusters/prox-n100.yaml", "file_exists", "Stage 1 cluster config exists"),
            ("config/env/prox-n100.env", "file_exists", "Environment overrides exist"),
            ("infrastructure/proxmox/k3s/kubeconfig", "file_exists", "k3s kubeconfig artifact exists"),
        ]

        for target, method, text in canonical_paths:
            claim_id = self.compute_claim_id(memo_hash, text, target)
            # Skip if already extracted
            if any(c.id == claim_id for c in claims):
                continue
            claims.append(Claim(
                id=claim_id,
                type=ClaimType.STRUCTURAL,
                source=memo_path,
                section="Canonical Structure",
                text=text,
                evaluation=ClaimEvaluation(method=method, target=target),
                episode=episode,
            ))

        # Deduplicate by claim ID
        seen = set()
        unique_claims = []
        for claim in claims:
            if claim.id not in seen:
                seen.add(claim.id)
                unique_claims.append(claim)

        return unique_claims

    def evaluate_claim(self, claim: Claim) -> Claim:
        """Evaluate a single claim against repository state."""
        claim.last_evaluated = datetime.now(timezone.utc).isoformat()

        try:
            method = claim.evaluation.method
            target = claim.evaluation.target
            full_path = self.repo_root / target

            if method == "file_exists":
                if full_path.is_file():
                    claim.status = ClaimStatus.PASS
                    claim.evidence = f"File exists: {target}"
                else:
                    claim.status = ClaimStatus.FAIL
                    claim.evidence = f"File not found: {target}"

            elif method == "dir_exists":
                if full_path.is_dir():
                    claim.status = ClaimStatus.PASS
                    claim.evidence = f"Directory exists: {target}"
                else:
                    claim.status = ClaimStatus.FAIL
                    claim.evidence = f"Directory not found: {target}"

            elif method == "file_content":
                if full_path.is_file():
                    content = full_path.read_text()
                    pattern = claim.evaluation.pattern
                    expected = claim.evaluation.expected

                    if pattern and re.search(pattern, content):
                        claim.status = ClaimStatus.PASS
                        claim.evidence = f"Pattern matched in {target}"
                    elif expected and expected in content:
                        claim.status = ClaimStatus.PASS
                        claim.evidence = f"Expected content found in {target}"
                    else:
                        claim.status = ClaimStatus.FAIL
                        claim.evidence = f"Content not matched in {target}"
                else:
                    claim.status = ClaimStatus.FAIL
                    claim.evidence = f"File not found: {target}"

            elif method in ("script_behavior", "test_exists"):
                # Operational claims - best-effort evaluation
                if full_path.exists():
                    claim.status = ClaimStatus.PASS
                    claim.evidence = f"Script/test exists: {target}"
                else:
                    claim.status = ClaimStatus.UNKNOWN
                    claim.evidence = f"Cannot evaluate operational claim: {target}"

            # v7 P0: Stronger evaluators for gating claims
            elif method == "file_nonempty":
                if full_path.is_file():
                    size = full_path.stat().st_size
                    if size > 0:
                        claim.status = ClaimStatus.PASS
                        claim.evidence = f"File exists and is non-empty ({size} bytes): {target}"
                    else:
                        claim.status = ClaimStatus.FAIL
                        claim.evidence = f"File exists but is EMPTY (0 bytes): {target}"
                else:
                    claim.status = ClaimStatus.FAIL
                    claim.evidence = f"File not found: {target}"

            elif method == "yaml_parseable":
                if full_path.is_file():
                    try:
                        import yaml
                        content = full_path.read_text()
                        if not content.strip():
                            claim.status = ClaimStatus.FAIL
                            claim.evidence = f"YAML file is empty: {target}"
                        else:
                            yaml.safe_load(content)
                            claim.status = ClaimStatus.PASS
                            claim.evidence = f"YAML file is valid and parseable: {target}"
                    except yaml.YAMLError as e:
                        claim.status = ClaimStatus.FAIL
                        claim.evidence = f"YAML parse error in {target}: {str(e)[:100]}"
                else:
                    claim.status = ClaimStatus.FAIL
                    claim.evidence = f"YAML file not found: {target}"

            elif method == "json_parseable":
                if full_path.is_file():
                    try:
                        content = full_path.read_text()
                        if not content.strip():
                            claim.status = ClaimStatus.FAIL
                            claim.evidence = f"JSON file is empty: {target}"
                        else:
                            json.loads(content)
                            claim.status = ClaimStatus.PASS
                            claim.evidence = f"JSON file is valid and parseable: {target}"
                    except json.JSONDecodeError as e:
                        claim.status = ClaimStatus.FAIL
                        claim.evidence = f"JSON parse error in {target}: {str(e)[:100]}"
                else:
                    claim.status = ClaimStatus.FAIL
                    claim.evidence = f"JSON file not found: {target}"

            elif method == "contains_key":
                key_path = claim.evaluation.key_path
                if not key_path:
                    claim.status = ClaimStatus.FAIL
                    claim.evidence = "contains_key requires key_path parameter"
                elif full_path.is_file():
                    try:
                        content = full_path.read_text()
                        # Try JSON first, then YAML
                        data = None
                        try:
                            data = json.loads(content)
                        except json.JSONDecodeError:
                            try:
                                import yaml
                                data = yaml.safe_load(content)
                            except:
                                pass

                        if data is None:
                            claim.status = ClaimStatus.FAIL
                            claim.evidence = f"Cannot parse file as JSON or YAML: {target}"
                        else:
                            # Navigate key path (supports "foo.bar.baz")
                            value = data
                            for key in key_path.split("."):
                                if isinstance(value, dict) and key in value:
                                    value = value[key]
                                else:
                                    value = None
                                    break

                            if value is not None:
                                claim.status = ClaimStatus.PASS
                                claim.evidence = f"Key '{key_path}' found with non-null value in {target}"
                            else:
                                claim.status = ClaimStatus.FAIL
                                claim.evidence = f"Key '{key_path}' is missing or null in {target}"
                    except Exception as e:
                        claim.status = ClaimStatus.FAIL
                        claim.evidence = f"Error checking key in {target}: {str(e)[:100]}"
                else:
                    claim.status = ClaimStatus.FAIL
                    claim.evidence = f"File not found: {target}"

            elif method == "command_succeeds":
                command = claim.evaluation.command
                timeout = claim.evaluation.timeout or 10
                if not command:
                    claim.status = ClaimStatus.FAIL
                    claim.evidence = "command_succeeds requires command parameter"
                else:
                    try:
                        import subprocess
                        result = subprocess.run(
                            command,
                            shell=True,
                            capture_output=True,
                            timeout=timeout,
                            cwd=str(self.repo_root)
                        )
                        if result.returncode == 0:
                            claim.status = ClaimStatus.PASS
                            claim.evidence = f"Command succeeded (rc=0): {command[:50]}"
                        else:
                            stderr = result.stderr.decode()[:200] if result.stderr else ""
                            claim.status = ClaimStatus.FAIL
                            claim.evidence = f"Command failed (rc={result.returncode}): {stderr}"
                    except subprocess.TimeoutExpired:
                        claim.status = ClaimStatus.FAIL
                        claim.evidence = f"Command timed out after {timeout}s: {command[:50]}"
                    except Exception as e:
                        claim.status = ClaimStatus.FAIL
                        claim.evidence = f"Command error: {str(e)[:100]}"

            elif method == "artifact_valid":
                artifact_name = claim.evaluation.artifact_name
                if not artifact_name:
                    claim.status = ClaimStatus.FAIL
                    claim.evidence = "artifact_valid requires artifact_name parameter"
                else:
                    artifacts_file = self.state_dir / "artifacts.json"
                    if artifacts_file.is_file():
                        try:
                            artifacts = json.loads(artifacts_file.read_text())
                            artifact = artifacts.get(artifact_name, {})
                            if artifact.get("valid", False):
                                claim.status = ClaimStatus.PASS
                                claim.evidence = f"Artifact '{artifact_name}' is marked valid"
                            else:
                                claim.status = ClaimStatus.FAIL
                                claim.evidence = f"Artifact '{artifact_name}' is not valid or missing"
                        except Exception as e:
                            claim.status = ClaimStatus.FAIL
                            claim.evidence = f"Error reading artifacts.json: {str(e)[:100]}"
                    else:
                        claim.status = ClaimStatus.FAIL
                        claim.evidence = "artifacts.json not found"

            else:
                claim.status = ClaimStatus.UNKNOWN
                claim.evidence = f"Unknown evaluation method: {method}"

        except Exception as e:
            claim.status = ClaimStatus.UNKNOWN
            claim.evidence = f"Evaluation error: {str(e)}"

        return claim

    # =========================================================================
    # v7 P0: Stage Contracts and Gating Claims
    # =========================================================================

    def load_stage_contracts(self) -> dict:
        """Load stage contracts from YAML configuration."""
        if not self.stage_contracts_file.is_file():
            return {}
        try:
            import yaml
            return yaml.safe_load(self.stage_contracts_file.read_text()) or {}
        except Exception:
            return {}

    def get_stage_gating_claims(self, stage: str, episode: str) -> List[Claim]:
        """
        Get gating claims for a specific stage.
        These claims MUST pass before the stage can be marked complete.
        """
        contracts = self.load_stage_contracts()
        stages = contracts.get("stages", {})
        stage_config = stages.get(stage, {})
        gating_claim_configs = stage_config.get("gating_claims", [])

        claims = []
        for cfg in gating_claim_configs:
            eval_cfg = cfg.get("evaluation", {})
            claim = Claim(
                id=cfg.get("id", f"{stage}_gating_{len(claims)}"),
                type=ClaimType.STRUCTURAL,
                source="stage_contracts.yaml",
                section=f"Stage: {stage}",
                text=cfg.get("text", ""),
                evaluation=ClaimEvaluation(
                    method=eval_cfg.get("method", "file_exists"),
                    target=eval_cfg.get("target", ""),
                    expected=eval_cfg.get("expected"),
                    pattern=eval_cfg.get("pattern"),
                    key_path=eval_cfg.get("key_path"),
                    command=eval_cfg.get("command"),
                    timeout=eval_cfg.get("timeout", 10),
                    artifact_name=eval_cfg.get("artifact_name"),
                ),
                episode=episode,
                priority="gating",
                stage=stage,
            )
            claims.append(claim)

        return claims

    def check_stage_gating(self, stage: str, episode: str) -> dict:
        """
        Check if all gating claims for a stage pass.
        Returns a detailed report with pass/fail status and evidence.
        """
        gating_claims = self.get_stage_gating_claims(stage, episode)

        if not gating_claims:
            return {
                "stage": stage,
                "gating_pass": True,
                "reason": "No gating claims defined",
                "claims": [],
                "failing_claims": [],
            }

        evaluated = []
        failing = []

        for claim in gating_claims:
            claim = self.evaluate_claim(claim)
            evaluated.append(claim)
            if claim.status != ClaimStatus.PASS:
                failing.append(claim)

        all_pass = len(failing) == 0

        return {
            "stage": stage,
            "gating_pass": all_pass,
            "total_gating_claims": len(gating_claims),
            "passing_claims": len(gating_claims) - len(failing),
            "failing_claims_count": len(failing),
            "claims": [c.to_dict() for c in evaluated],
            "failing_claims": [
                {
                    "id": c.id,
                    "text": c.text,
                    "evidence": c.evidence,
                    "method": c.evaluation.method,
                    "target": c.evaluation.target,
                }
                for c in failing
            ],
            "reason": (
                "All gating claims pass"
                if all_pass
                else f"{len(failing)} gating claim(s) failed"
            ),
        }

    def update_cluster_identity(self, updates: dict) -> bool:
        """
        Update cluster_identity.json with new values.
        Preserves existing values unless explicitly overwritten.
        """
        try:
            # Load existing
            if self.cluster_identity_file.is_file():
                identity = json.loads(self.cluster_identity_file.read_text())
            else:
                identity = {}

            # Update with new values (skip None values)
            for key, value in updates.items():
                if value is not None:
                    identity[key] = value

            # Update metadata
            identity["last_updated"] = datetime.now(timezone.utc).isoformat()

            # Write back
            self.cluster_identity_file.write_text(json.dumps(identity, indent=2))
            return True
        except Exception:
            return False

    def update_artifact(self, artifact_name: str, updates: dict) -> bool:
        """
        Update a specific artifact in artifacts.json.
        """
        try:
            # Load existing
            if self.artifacts_file.is_file():
                artifacts = json.loads(self.artifacts_file.read_text())
            else:
                artifacts = {}

            # Get or create artifact entry
            if artifact_name not in artifacts:
                artifacts[artifact_name] = {}

            # Update with new values
            for key, value in updates.items():
                if value is not None:
                    artifacts[artifact_name][key] = value

            # Update metadata
            artifacts["last_updated"] = datetime.now(timezone.utc).isoformat()

            # Write back
            self.artifacts_file.write_text(json.dumps(artifacts, indent=2))
            return True
        except Exception:
            return False

    def get_stage_evidence_capsule(self, stage: str, error_log_path: Optional[str] = None) -> dict:
        """
        Generate an evidence capsule for give_up that includes all required info.
        This prevents "Logs: unknown" scenarios.
        """
        episode = self.generate_episode_id()
        gating_result = self.check_stage_gating(stage, episode)

        # Find the most relevant failing claim
        failing_claim = None
        if gating_result["failing_claims"]:
            failing_claim = gating_result["failing_claims"][0]

        # Read error excerpt if log exists
        error_excerpt = ""
        if error_log_path:
            log_path = Path(error_log_path)
            if log_path.is_file():
                try:
                    content = log_path.read_text()
                    # Get last 500 chars or find first error
                    lines = content.split("\n")
                    error_lines = [l for l in lines if "error" in l.lower() or "fatal" in l.lower() or "failed" in l.lower()]
                    if error_lines:
                        error_excerpt = "\n".join(error_lines[:5])[:500]
                    else:
                        error_excerpt = content[-500:]
                except Exception:
                    error_excerpt = "[Could not read log file]"

        # Determine suggested next action based on failing claim
        suggested_action = "Review logs and manually fix the issue"
        if failing_claim:
            method = failing_claim.get("method", "")
            target = failing_claim.get("target", "")
            if method == "file_nonempty":
                suggested_action = f"Ensure {target} is created and non-empty"
            elif method == "yaml_parseable":
                suggested_action = f"Fix YAML syntax errors in {target}"
            elif method == "contains_key":
                suggested_action = f"Populate required key in {target}"
            elif method == "command_succeeds":
                suggested_action = f"Debug why command failed: {failing_claim.get('evidence', '')}"
            elif method == "artifact_valid":
                suggested_action = f"Mark artifact as valid after verification"

        return {
            "stage": stage,
            "log_path": error_log_path or "unknown",
            "evidence_excerpt": error_excerpt or "[No error excerpt available]",
            "failing_claim_id": failing_claim["id"] if failing_claim else None,
            "failing_claim_evidence": failing_claim["evidence"] if failing_claim else None,
            "suggested_next_action": suggested_action,
            "gating_status": gating_result,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }

    def compute_safety_score(self, claim: Claim) -> float:
        """
        Compute safety score for a claim (0.0 to 1.0).

        1.0: Single file, clear target, no dependencies, simple change
        0.7: Multiple files, some dependencies, moderate complexity
        0.4: Cross-cutting changes, unclear dependencies, high complexity
        0.0: Unsafe (touches protected files, exceeds size limits)
        """
        target = claim.evaluation.target

        # Check if target is in protected files
        for protected in self.protected_files:
            if target == protected or target.startswith(protected.rstrip("/")):
                return 0.0

        # Simple heuristics based on path depth and type
        parts = target.split("/")
        depth = len(parts)

        if claim.evaluation.method in ("file_exists", "file_content"):
            if depth <= 3:
                return 1.0
            elif depth <= 5:
                return 0.7
            else:
                return 0.4
        elif claim.evaluation.method == "dir_exists":
            if depth <= 2:
                return 1.0
            elif depth <= 4:
                return 0.7
            else:
                return 0.4
        else:
            # Operational claims
            return 0.4

    def compute_impact_score(self, claim: Claim, structural_drift: float, operational_drift: float) -> float:
        """
        Compute impact score for a claim (0.0 to 1.0).

        1.0: Reduces drift in both lanes
        0.7: Reduces drift in one lane significantly
        0.4: Reduces drift in one lane moderately
        0.1: Minimal drift reduction
        """
        if claim.type == ClaimType.STRUCTURAL:
            if structural_drift > 0.5:
                return 0.7  # Bootstrap window, structural claims are high priority
            else:
                return 0.4
        else:
            if operational_drift > 0.3:
                return 0.7
            else:
                return 0.4

    def compute_drift(self, claims: list[Claim]) -> DriftState:
        """Compute drift from evaluated claims."""
        structural = DriftLane()
        operational = DriftLane()

        for claim in claims:
            if claim.type == ClaimType.STRUCTURAL:
                structural.total_claims += 1
                if claim.status == ClaimStatus.PASS:
                    structural.pass_claims += 1
                elif claim.status == ClaimStatus.FAIL:
                    structural.fail_claims += 1
                elif claim.status == ClaimStatus.BLOCKED:
                    structural.blocked_claims += 1
                else:
                    structural.unknown_claims += 1
            else:
                operational.total_claims += 1
                if claim.status == ClaimStatus.PASS:
                    operational.pass_claims += 1
                elif claim.status == ClaimStatus.FAIL:
                    operational.fail_claims += 1
                elif claim.status == ClaimStatus.BLOCKED:
                    operational.blocked_claims += 1
                else:
                    operational.unknown_claims += 1

        # Compute scores (fail_claims / total_claims)
        if structural.total_claims > 0:
            structural.score = round(structural.fail_claims / structural.total_claims, 3)
        if operational.total_claims > 0:
            operational.score = round(operational.fail_claims / operational.total_claims, 3)

        total = len(claims)
        pass_count = sum(1 for c in claims if c.status == ClaimStatus.PASS)
        fail_count = sum(1 for c in claims if c.status == ClaimStatus.FAIL)
        unknown_count = sum(1 for c in claims if c.status == ClaimStatus.UNKNOWN)
        blocked_count = sum(1 for c in claims if c.status == ClaimStatus.BLOCKED)

        drift_score = round(fail_count / total, 3) if total > 0 else 0.0

        return DriftState(
            memo="",
            memo_hash="",
            episode="",
            total_claims=total,
            pass_claims=pass_count,
            fail_claims=fail_count,
            unknown_claims=unknown_count,
            blocked_claims=blocked_count,
            drift_score=drift_score,
            structural_drift=structural,
            operational_drift=operational,
            claims=claims,
        )

    def rank_claims(self, claims: list[Claim], structural_drift: float, operational_drift: float,
                    bootstrap_window: bool) -> list[Claim]:
        """
        Rank claims by safety and impact for selection.

        Selection algorithm per v7 spec:
        1. Filter to FAIL claims only
        2. Apply bootstrap window rules
        3. Compute safety and impact scores
        4. Sort by combined score
        5. Deterministic tie-breaking
        """
        # Filter to FAIL claims only (exclude PASS, UNKNOWN, BLOCKED)
        fail_claims = [c for c in claims if c.status == ClaimStatus.FAIL]

        # Apply bootstrap window
        if bootstrap_window:
            # Structural claims only during bootstrap
            fail_claims = [c for c in fail_claims if c.type == ClaimType.STRUCTURAL]

        # Compute scores for each claim
        for claim in fail_claims:
            claim.safety_score = self.compute_safety_score(claim)
            claim.impact_score = self.compute_impact_score(claim, structural_drift, operational_drift)

        # Sort by combined score (descending), then tie-breaking
        def sort_key(c: Claim):
            combined = c.safety_score * c.impact_score
            # Tie-breaking: structural before operational, lower ID, earlier evaluation
            type_priority = 0 if c.type == ClaimType.STRUCTURAL else 1
            return (-combined, type_priority, c.id, c.last_evaluated or "")

        fail_claims.sort(key=sort_key)

        return fail_claims

    def measure_drift(self, memo_path: str) -> DriftState:
        """
        Main entry point: measure drift against a memo.

        1. Check memo hash (if changed, start new episode)
        2. Extract or load claims
        3. Evaluate all claims
        4. Compute drift per lane
        5. Persist state
        """
        memo_hash = self.compute_memo_hash(memo_path)
        if not memo_hash:
            raise ValueError(f"Memo not found: {memo_path}")

        # Load existing state
        existing_state = self.load_drift_state()

        # Check if memo changed (new episode)
        if existing_state and existing_state.memo_hash == memo_hash:
            # Same episode, reuse claims
            episode = existing_state.episode
            claims = existing_state.claims
            print(f"[drift-engine] Continuing episode: {episode}", file=sys.stderr)
        else:
            # New episode
            episode = self.generate_episode_id()
            claims = self.extract_claims_from_memo(memo_path, memo_hash, episode)
            print(f"[drift-engine] New episode: {episode} ({len(claims)} claims extracted)", file=sys.stderr)

        # Evaluate all claims
        for i, claim in enumerate(claims):
            claims[i] = self.evaluate_claim(claim)

        # Compute drift
        state = self.compute_drift(claims)
        state.memo = memo_path
        state.memo_hash = memo_hash
        state.episode = episode
        state.last_measured = datetime.now(timezone.utc).isoformat()

        # Check bootstrap window
        bootstrap_window = state.structural_drift.score > 0.5

        # Rank claims
        ranked_claims = self.rank_claims(
            claims,
            state.structural_drift.score,
            state.operational_drift.score,
            bootstrap_window
        )

        # Update state with ranked claims
        state.claims = claims

        # Persist state
        self.save_drift_state(state)
        self.update_now_state(
            active_claim=ranked_claims[0].id if ranked_claims else None,
            bootstrap_window=bootstrap_window,
        )
        self.append_timeline(state)

        return state

    def select_next_claim(self) -> Optional[Claim]:
        """Select next claim to converge based on current drift state.

        v7: Skips claims that are:
        - BLOCKED (failed solution attempts)
        - Deferred (infra issues like architect_unavailable)
        """
        state = self.load_drift_state()
        if not state:
            return None

        bootstrap_window = state.structural_drift.score > 0.5
        ranked = self.rank_claims(
            state.claims,
            state.structural_drift.score,
            state.operational_drift.score,
            bootstrap_window
        )

        if not ranked:
            return None

        now = datetime.now(timezone.utc)

        # Return first claim with safety_score > 0 that is not deferred
        for claim in ranked:
            if claim.safety_score <= 0:
                continue
            # Skip claims that are deferred due to infra issues
            if claim.defer_until:
                try:
                    defer_dt = datetime.fromisoformat(claim.defer_until)
                    if defer_dt > now:
                        continue  # Still deferred
                except ValueError:
                    pass  # Invalid date, treat as not deferred
            return claim

        return None

    def mark_claim_blocked(self, claim_id: str) -> bool:
        """Mark a claim as BLOCKED."""
        state = self.load_drift_state()
        if not state:
            return False

        for claim in state.claims:
            if claim.id == claim_id:
                claim.status = ClaimStatus.BLOCKED
                claim.blocked_until = state.episode

        self.save_drift_state(state)
        return True

    def defer_claim(self, claim_id: str, reason: str, minutes: int = 60) -> Optional[str]:
        """Defer a claim for infrastructure issues (distinct from BLOCKED).

        v7: Infrastructure deferrals (architect_unavailable, etc.) do not count
        as claim failures. The claim remains FAIL but is temporarily skipped.

        Args:
            claim_id: The claim to defer
            reason: Why the claim is deferred (e.g., "architect_unavailable")
            minutes: How long to defer (default 60 minutes)

        Returns:
            The defer_until timestamp if successful, None otherwise
        """
        state = self.load_drift_state()
        if not state:
            return None

        defer_until = (datetime.now(timezone.utc) + timedelta(minutes=minutes)).isoformat()

        for claim in state.claims:
            if claim.id == claim_id:
                claim.defer_until = defer_until
                claim.defer_reason = reason
                self.save_drift_state(state)
                return defer_until

        return None

    def clear_claim_deferral(self, claim_id: str) -> bool:
        """Clear the deferral on a claim."""
        state = self.load_drift_state()
        if not state:
            return False

        for claim in state.claims:
            if claim.id == claim_id:
                claim.defer_until = None
                claim.defer_reason = None
                self.save_drift_state(state)
                return True

        return False

    def increment_claim_attempts(self, claim_id: str) -> int:
        """Increment attempt counter for a claim."""
        state = self.load_drift_state()
        if not state:
            return 0

        for claim in state.claims:
            if claim.id == claim_id:
                claim.attempts += 1
                if claim.attempts >= 3:
                    claim.status = ClaimStatus.BLOCKED
                    claim.blocked_until = state.episode
                self.save_drift_state(state)
                return claim.attempts

        return 0

    def all_fail_claims_blocked_or_deferred(self) -> tuple[bool, int, int]:
        """Check if all FAIL claims are BLOCKED or deferred.

        v7: Returns (all_blocked_or_deferred, blocked_count, deferred_count)
        to help the orchestrator decide on safe mode behavior.
        """
        state = self.load_drift_state()
        if not state:
            return False, 0, 0

        now = datetime.now(timezone.utc)
        fail_claims = [c for c in state.claims if c.status == ClaimStatus.FAIL]

        if not fail_claims:
            return True, 0, 0

        blocked_count = 0
        deferred_count = 0

        for claim in fail_claims:
            if claim.status == ClaimStatus.BLOCKED:
                blocked_count += 1
                continue
            if claim.defer_until:
                try:
                    defer_dt = datetime.fromisoformat(claim.defer_until)
                    if defer_dt > now:
                        deferred_count += 1
                        continue
                except ValueError:
                    pass

        actionable = len(fail_claims) - blocked_count - deferred_count
        return actionable == 0, blocked_count, deferred_count

    def all_fail_claims_blocked(self) -> bool:
        """Check if all FAIL claims are BLOCKED (legacy compatibility)."""
        all_blocked, _, _ = self.all_fail_claims_blocked_or_deferred()
        return all_blocked


def main():
    """CLI interface for drift engine."""
    import argparse

    parser = argparse.ArgumentParser(description="Orchestrator v7 Drift Engine")
    parser.add_argument("command", choices=[
        "measure", "select", "status", "block", "increment", "defer", "clear-defer",
        "check-gating", "evidence", "update-identity", "update-artifact"
    ])
    parser.add_argument("--memo", default="docs/master_memo.txt", help="Path to architecture memo")
    parser.add_argument("--repo-root", default=".", help="Repository root directory")
    parser.add_argument("--claim-id", help="Claim ID for block/increment/defer commands")
    parser.add_argument("--reason", default="architect_unavailable", help="Reason for deferral")
    parser.add_argument("--minutes", type=int, default=60, help="Deferral duration in minutes")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    # v7 P0: Stage gating arguments
    parser.add_argument("--stage", help="Stage name for gating checks (vms, k3s, infra, apps, ingress, obs)")
    parser.add_argument("--log-path", help="Path to error log for evidence capsule")
    # v7 P0: Artifact/identity update arguments
    parser.add_argument("--artifact", help="Artifact name (kubeconfig, etc.)")
    parser.add_argument("--key", help="Key to update")
    parser.add_argument("--value", help="Value to set")

    args = parser.parse_args()

    engine = DriftEngine(args.repo_root)

    if args.command == "measure":
        state = engine.measure_drift(args.memo)
        if args.json:
            print(json.dumps(state.to_dict(), indent=2))
        else:
            print(f"Episode: {state.episode}")
            print(f"Memo: {state.memo} (hash: {state.memo_hash})")
            print(f"Total claims: {state.total_claims}")
            print(f"  Pass: {state.pass_claims}, Fail: {state.fail_claims}, Unknown: {state.unknown_claims}, Blocked: {state.blocked_claims}")
            print(f"Drift score: {state.drift_score:.3f}")
            print(f"  Structural: {state.structural_drift.score:.3f} ({state.structural_drift.fail_claims}/{state.structural_drift.total_claims} fail)")
            print(f"  Operational: {state.operational_drift.score:.3f} ({state.operational_drift.fail_claims}/{state.operational_drift.total_claims} fail)")
            bootstrap = "active" if state.structural_drift.score > 0.5 else "inactive"
            print(f"Bootstrap window: {bootstrap}")

    elif args.command == "select":
        claim = engine.select_next_claim()
        if claim:
            if args.json:
                print(json.dumps(claim.to_dict(), indent=2))
            else:
                print(f"Selected claim: {claim.id}")
                print(f"  Type: {claim.type.value}")
                print(f"  Text: {claim.text}")
                print(f"  Target: {claim.evaluation.target}")
                print(f"  Safety: {claim.safety_score:.2f}, Impact: {claim.impact_score:.2f}")
        else:
            if args.json:
                print("null")
            else:
                print("No safe claim available for selection")
            sys.exit(1)

    elif args.command == "status":
        state = engine.load_drift_state()
        if state:
            if args.json:
                print(json.dumps(state.to_dict(), indent=2))
            else:
                print(f"Episode: {state.episode}")
                print(f"Drift: {state.drift_score:.3f}")
                print(f"Structural: {state.structural_drift.score:.3f}")
                print(f"Operational: {state.operational_drift.score:.3f}")
        else:
            print("No drift state found")
            sys.exit(1)

    elif args.command == "block":
        if not args.claim_id:
            print("Error: --claim-id required for block command", file=sys.stderr)
            sys.exit(1)
        if engine.mark_claim_blocked(args.claim_id):
            print(f"Claim {args.claim_id} marked as BLOCKED")
        else:
            print(f"Failed to block claim {args.claim_id}", file=sys.stderr)
            sys.exit(1)

    elif args.command == "increment":
        if not args.claim_id:
            print("Error: --claim-id required for increment command", file=sys.stderr)
            sys.exit(1)
        attempts = engine.increment_claim_attempts(args.claim_id)
        print(f"Claim {args.claim_id} attempts: {attempts}")

    elif args.command == "defer":
        if not args.claim_id:
            print("Error: --claim-id required for defer command", file=sys.stderr)
            sys.exit(1)
        defer_until = engine.defer_claim(args.claim_id, args.reason, args.minutes)
        if defer_until:
            if args.json:
                print(json.dumps({"claim_id": args.claim_id, "defer_until": defer_until, "reason": args.reason}))
            else:
                print(f"Claim {args.claim_id} deferred until {defer_until} (reason: {args.reason})")
        else:
            print(f"Failed to defer claim {args.claim_id}", file=sys.stderr)
            sys.exit(1)

    elif args.command == "clear-defer":
        if not args.claim_id:
            print("Error: --claim-id required for clear-defer command", file=sys.stderr)
            sys.exit(1)
        if engine.clear_claim_deferral(args.claim_id):
            print(f"Claim {args.claim_id} deferral cleared")
        else:
            print(f"Failed to clear deferral for claim {args.claim_id}", file=sys.stderr)
            sys.exit(1)

    # v7 P0: Gating checks
    elif args.command == "check-gating":
        if not args.stage:
            print("Error: --stage required for check-gating command", file=sys.stderr)
            sys.exit(1)
        episode = engine.generate_episode_id()
        result = engine.check_stage_gating(args.stage, episode)
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            print(f"Stage: {result['stage']}")
            print(f"Gating Pass: {result['gating_pass']}")
            print(f"Claims: {result.get('passing_claims', 0)}/{result.get('total_gating_claims', 0)} passing")
            if result['failing_claims']:
                print("Failing claims:")
                for fc in result['failing_claims']:
                    print(f"  - {fc['id']}: {fc['evidence']}")
        if not result['gating_pass']:
            sys.exit(1)

    elif args.command == "evidence":
        if not args.stage:
            print("Error: --stage required for evidence command", file=sys.stderr)
            sys.exit(1)
        capsule = engine.get_stage_evidence_capsule(args.stage, args.log_path)
        if args.json:
            print(json.dumps(capsule, indent=2))
        else:
            print(f"Stage: {capsule['stage']}")
            print(f"Log path: {capsule['log_path']}")
            if capsule['failing_claim_id']:
                print(f"Failing claim: {capsule['failing_claim_id']}")
                print(f"  Evidence: {capsule['failing_claim_evidence']}")
            print(f"Suggested action: {capsule['suggested_next_action']}")
            if capsule['evidence_excerpt']:
                print(f"\nError excerpt:\n{capsule['evidence_excerpt'][:300]}")

    elif args.command == "update-identity":
        if not args.key or not args.value:
            print("Error: --key and --value required for update-identity command", file=sys.stderr)
            sys.exit(1)
        # Parse value as JSON if possible, else use as string
        try:
            value = json.loads(args.value)
        except json.JSONDecodeError:
            value = args.value
        if engine.update_cluster_identity({args.key: value}):
            print(f"Updated cluster_identity.json: {args.key}={value}")
        else:
            print("Failed to update cluster_identity.json", file=sys.stderr)
            sys.exit(1)

    elif args.command == "update-artifact":
        if not args.artifact or not args.key or not args.value:
            print("Error: --artifact, --key, and --value required for update-artifact command", file=sys.stderr)
            sys.exit(1)
        # Parse value as JSON if possible, else use as string
        try:
            value = json.loads(args.value)
        except json.JSONDecodeError:
            value = args.value
        if engine.update_artifact(args.artifact, {args.key: value}):
            print(f"Updated artifacts.json [{args.artifact}]: {args.key}={value}")
        else:
            print("Failed to update artifacts.json", file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()
