# AI Studio Architecture

This document anchors how the multi-agent studio should behave inside the homelab.

## Personas (Stage 2 default set)
- Planner: plans work, writes briefs, curates backlog, and defines acceptance criteria.
- Engineer (Codex Sidebar): edits repo content under guardrails, keeps manifests/code GitOps-safe.
- Executor (Codex CLI): executes commands against local hosts or cluster, captures logs/artifacts.
- Reviewer/Narrative: optional validation and summarization layers before merge or deploy.

## Message-Passing Model
1. Ticket/idea enters the studio (from ai/tasks or backlog).
2. Planner produces a plan and constraints; hands off to Engineer.
3. Engineer edits files, prepares scripts/manifests, and pushes execution instructions.
4. Executor runs on real infrastructure (or local simulation) and returns logs + status.
5. Reviewer validates outcomes and writes short reports; loop repeats until criteria met.

## Ticket Flow
- Source: ai/tasks/, ai/backlog.md, or external signals piped into ai/studio/backlog.md.
- Plan: Planner + Engineer co-author a scoped plan (stage-aware paths only).
- Implement: Engineer edits repo; commits to engineer/<slug>-YYYYMMDD branches when needed.
- Execute: Executor runs scripts (e.g., infrastructure/proxmox/cluster_bootstrap.sh, flux/kubectl) with logs stored.
- Close: Reviewer/Narrative documents results in ai/studio/reports/ and updates ai/state/.

## Memory and Logs
- ai/studio/memory/: transient artifacts from runs (prompt traces, decisions, snapshots).
- ai/state/: canonical run logs, stage flags, and last-known status; never store secrets.
- ui/studio/: future lightweight UI to render timelines, status, and memory indexes.

## Integration with CLI
- CLI persona is the only actor allowed to touch live hosts/clusters.
- Engineer produces explicit, step-by-step commands with expected outcomes for the Executor.
- All Talos/Flux/kubectl interactions should assume TALOS_KUBECONFIG from .talos/<cluster>/.

## Boundaries & Guardrails
- No secrets committed; sensitive values live only in config/env/ locally.
- Respect stage gates: Stage 1 (infra) before Stage 2 (studio) before Stage 3 (business tenants).
- Dangerous operations (disk wipe, node reset) must stay in clearly named scripts and require human approval.
- Prefer GitOps for steady-state changes; direct cluster edits should be temporary and documented.
