# Funoffshore Homelab & Multi-Biz AI Engine

*Tagline: A self-maintaining homelab that incubates multiple AI-driven businesses.*

This repository is the canonical source of truth for the Funoffshore homelab and its AI-assisted business engine. It describes:

- The current reality of the cluster
- The target architecture
- The long-term vision for running a portfolio of businesses on top of a single, reproducible control plane

This document is written as a tech brief plus architectural manifesto. It should be readable by humans (Kyle, future collaborators, auditors) and the AI orchestrator (Planner / Engineer / Executor personas) and used as the primary narrative input when generating backlogs, roadmaps, and automation plans.

---

## 📚 Table of Contents

1. [Overview](#overview)
2. [Vision](#vision)
3. [Stage Progress Snapshot](#stage-progress-snapshot)
4. [Architecture Summary](#architecture-summary)
5. [High-Level Architecture Diagram](#high-level-architecture-diagram)
6. [Stage 1 – Homelab Platform](#stage-1--homelab-platform)
7. [Stage 2 – AI Studio](#stage-2--ai-studio)
8. [Stage 3 – Multi-Biz Engine](#stage-3--multi-biz-engine)
9. [Stage 4 – Control-Plane-in-a-Box (CPiaB) Horizon](#stage-4--control-plane-in-a-box-cpiab-horizon)
10. [Business Units (Biz2A / Biz2B / Biz2C)](#business-units-biz2a--biz2b--biz2c)
11. [Operational Personas (Business Roles)](#operational-personas-business-roles)
12. [Orchestrator Personas (Planner / Engineer / Executor)](#orchestrator-personas-planner--engineer--executor)
13. [High-Level Architecture Sketch](#high-level-architecture-sketch)
14. [Repository Layout](#repository-layout)
15. [Branching Rules & Canonical Branch](#branching-rules--canonical-branch)
16. [Secrets & Safety](#secrets--safety)
17. [How the Orchestrator Should Use This Document](#how-the-orchestrator-should-use-this-document)
18. [Quickstart](#quickstart)
19. [Roadmap & Status](#roadmap--status)
20. [Wishlist and Backlog Seeds](#wishlist-and-backlog-seeds)
21. [Current Status Snapshot](#current-status-snapshot)

---

## Overview

Funoffshore is building a fully automated, self-maintaining homelab cluster that can power multiple AI-assisted businesses.

---

## Vision

Core principles:

- **Reproducibility** – The entire stack, from bare metal to apps, can be rebuilt from this repository.
- **GitOps-first** – Configuration lives in Git; the cluster converges to match Git, not the other way around.
- **Multi-tenant by design** – One homelab, many businesses (Biz2A/B/C, Biz3, and future units).
- **Agent-driven evolution** – AI personas propose, implement, and test changes under strict guardrails.
- **Portability** – The control plane can be moved, replicated, or shipped as an artifact (see CPiaB).

---

## Stage Progress Snapshot

The project is organized into stages. Each stage has an unlock condition that protects focus.

- **Stage 1 – Homelab Bring-Up**  
  Scope: Proxmox + Talos-managed Kubernetes + Flux; ingress, tunnel, basic monitoring, storage, sample apps.  
  Status: Active (in progress).  
  Unlock condition: GitOps manifests for all Stage 1 requirements; post-check marks `stage_1_complete`; cluster is reproducible from this repo via the bootstrap script.

- **Stage 2 – AI Studio**  
  Scope: AI Studio workflows, multi-persona engineering surface, repo-editing agents, orchestrator execution.  
  Status: Locked.  
  Unlock condition: Stage 1 is marked complete and stable; Talos cluster can be brought up reproducibly via `cluster_bootstrap.sh` without manual fixes.

- **Stage 3 – Multi-Biz Engine (Biz2 / Biz3)**  
  Scope: Biz incubators, multi-agent experiments, multi-tenant app stacks.  
  Status: Locked.  
  Unlock condition: Stage 2 AI Studio can deliver non-trivial repo changes end-to-end under guardrails.

- **Stage 4 / Horizon – CPiaB**  
  Scope: Control-Plane-in-a-Box: a portable control plane that can bootstrap itself in other environments.  
  Status: Vision only (R&D).  
  Unlock condition: Homelab and AI Studio are mature and stable enough to treat CPiaB as a product track.

Stage details and checklists live in `ai/mission.md`. The active backlog lives in `ai/backlog.md` (Stage 1 items may be auto-synced by scripts).

---

## Architecture Summary

The homelab is built in layers:

1. **Physical and virtualization layer**
   - N100 mini PC running Proxmox as primary compute
   - Synology DiskStation providing NFS storage
   - Local MacBook as a Wi‑Fi-connected control node for development and orchestration
2. **Kubernetes platform layer**
   - Talos OS managing control plane and worker nodes running on Proxmox VMs
   - Upstream Kubernetes managed by Talos
   - FluxCD as the GitOps engine
   - Ingress controller (ingress-nginx)
   - Cloudflared tunnel for secure external access
   - Basic monitoring stack using open source tools (Prometheus / Grafana / Loki) in Stage 1
3. **AI Studio layer (Stage 2)**
   - AI Studio services running in the cluster
   - Orchestrator flows built with LangGraph / LangChain to model Planner / Engineer / Executor loops
   - Telemetry and tracing via an OpenTelemetry-based pipeline in Stage 2 (for AI Studio and workloads)
4. **Multi-Biz layer (Stage 3)**
   - Biz2/Biz3 namespaces and overlays
   - Per-business backlogs, services, and dashboards
   - AI agents acting as PM, SRE, Security, Engineering, Research, and Marketing personas
5. **Horizon layer (Stage 4 CPiaB)**
   - The homelab’s control-plane patterns evolve into a sealed “control-plane-in-a-box” artifact.

---

## High-Level Architecture Diagram

```text
┌──────────────────────────────────────────────────────────┐
│                    Funoffshore Homelab                   │
│                                                          │
│  ┌──────────────┐    ┌──────────────────────────────┐   │
│  │   Proxmox    │    │        Synology NAS          │   │
│  └──────┬───────┘    └──────────────┬───────────────┘   │
│         │                            │                   │
│   ┌─────▼────────────────────────────▼───────┐           │
│   │         Talos-Managed Kubernetes         │           │
│   │  (FluxCD, Traefik, Cloudflared, Apps)   │           │
│   └─────┬────────────────────────────────────┘           │
│         │                                                │
│   ┌─────▼────────┐     ┌──────────────────────────────┐ │
│   │ AI Orches.   │     │     Multi-Biz Engine (Biz2)  │ │
│   │ ChatGPT Desk │     │  Biz2A / Biz2B / Biz2C       │ │
│   │ Codex Side   │     │  Biz3 (brand + market)       │ │
│   │ Codex CLI    │     └──────────────────────────────┘ │
│   └──────────────┘                                      │
└──────────────────────────────────────────────────────────┘
```

---

## Stage 1 – Homelab Platform

Goal: Build a solid, reproducible homelab that everything else rests on.

**Hardware and base layer**

- Proxmox on the N100 mini PC as the primary compute node
- Synology DiskStation providing NFS-backed storage
- Local MacBook as the main operator and AI client

**Kubernetes and core components**

- Talos: OS and Kubernetes lifecycle manager for control plane and workers; Proxmox VMs boot Talos and are configured via machine configs from this repo
- Kubernetes: upstream cluster running on Talos nodes
- FluxCD: reconciles the contents of `cluster/kubernetes/` into the running cluster; ensures Git is the source of truth
- Ingress controller: ingress-nginx managing HTTP/S traffic into services
- Cloudflared tunnel: outbound tunnel from homelab to Cloudflare; no direct inbound ports required on the home network
- Monitoring (Stage 1 scope): basic Prometheus / Grafana / Loki deployment to see node and cluster health and inspect logs
- Secrets management (early placeholder): Vault or SOPS-based workflows planned; real secrets never enter this repo

**Storage and networking**

- Synology NFS exports mounted into the cluster as persistent volumes
- Storage classes provided by an NFS provisioner for stateful workloads
- Network kept simple initially, with multi-AZ or multi-cluster patterns as a future optimization

**Stage 1 outcome**

- Talos-managed Kubernetes cluster on Proxmox
- GitOps convergence via Flux
- NFS-backed storage
- At least one sample app available via ingress and Cloudflared
- Basic metrics and logs visible in Grafana and Loki
- Reproducible bring-up via `cluster_bootstrap.sh` and GitOps

---

## Stage 2 – AI Studio

The AI Studio is the internal AI-driven engineering environment that sits on top of the homelab.

Its purpose is to:

- Turn English instructions into code, manifests, and documentation
- Manage Planner / Engineer / Executor loops as structured flows
- Provide a UI and logs so humans can inspect and guide the system

Core ideas:

- **Multi-persona orchestrator** – Planner, Engineer, Executor personas collaborate to plan work, propose changes, and run controlled actions.
- **LangGraph / LangChain** – Graph-based orchestration stack to model multi-step, stateful flows, including tool calls, code edits, and validation steps.
- **Hybrid models** – Calls local LLMs (for example via Ollama) and cloud models, depending on task type and cost.
- **Observability for AI** – Stage 2 introduces an OpenTelemetry-based pipeline focused on AI Studio and key workloads: traces of orchestrator runs; metrics on run duration, success, and error types; logs and events fed into the same monitoring stack.

Key components and directories:

- `ai/studio/` – Architecture notes, design documents, and configuration for AI Studio.
- `ai/agents/` – Definitions and prompts for AI personas used by the orchestrator.
- `ai/state/` – Run logs, last-run markers, stage flags, and other orchestrator state.
- `ui/studio/` (future) – Minimal web UI for viewing runs, tasks, and backlog links.

**Stage 2 outcome:** A working AI Studio that can take a ticket from `ai/backlog.md`, produce a plan, generate code or manifests, and propose commands for the operator, all under guardrails.

---

## Stage 3 – Multi-Biz Engine

Stage 3 focuses on running multiple AI-assisted businesses on top of the platform and the AI Studio.

Each business is treated as a tenant with:

- Its own namespace or overlays
- Its own backlog and lifecycle
- Its own AI personas working through a structured pipeline

Structure:

- `biz/`
- `biz2/`
- `biz3/`

Biz2 and Biz3 are “families” of businesses; inside them, business units like Biz2A/B/C represent specific tracks (rapid prototyping, technical depth, commercialization).

**Stage 3 outcome:** Multiple business units running in parallel on the homelab; backlogs, services, dashboards, and reports generated and maintained with help from AI Studio; a repeatable pattern for spinning up new business lines.

---

## Stage 4 – Control-Plane-in-a-Box (CPiaB) Horizon

Control-Plane-in-a-Box (CPiaB) is the long-term horizon: a sealed, portable Kubernetes control plane capable of bootstrapping itself inside another organization’s infrastructure.

High-level goals:

- Self-contained Talos/Kubernetes + Flux bundle, reproducible and air-gap friendly
- Automated discovery of hardware and network resources in a new environment
- Zero-trust node onboarding and identity management
- Declarative expansion of workloads from a canonical Git repository
- “Cluster-as-cargo” deployments suitable for regulated industries

In this homelab, CPiaB serves as:

1. A concrete technical North Star for how the control plane should be structured
2. A potential future product line once the homelab and AI Studio are robust

---

## Business Units (Biz2A / Biz2B / Biz2C)

Funoffshore treats business exploration as a multi-lane engine rather than a single startup.

- **Biz2A – Rapid Prototyping Unit**  
  24–72 hour prototypes; lightweight frontends and mock integrations; fast PM → Planner → Engineer loops; market-signal testing with minimal investment; high idea volume, low cost of failure.

- **Biz2B – Technical Depth Unit**  
  Real services (APIs, backend systems, infrastructure components); systems design documents and architecture diagrams; homelab-native workloads (microservices, operators, pipelines); research-driven technical evaluations and spike solutions.

- **Biz2C – Commercialization Unit**  
  Focus on real users and adoption; positioning, branding, messaging, pricing; SRE and Security sign-off; SLA-aware deployment and observability; produces internal MVPs ready to become independent products or Biz3 offerings.

---

## Operational Personas (Business Roles)

Each business line is mirrored by personas corresponding to real operational roles; personas may be human, AI, or both.

- **Product Management (PM)** – Defines customer problems and opportunities; writes briefs, acceptance criteria, and experiment scopes; prioritizes the business backlog.
- **SRE (Site Reliability Engineering)** – Ensures services are observable, reliable, and scalable; designs SLOs and alerts; validates deployment health using the homelab observability stack.
- **Security** – Performs threat modeling and reviews secret handling; ensures secure defaults and safe patterns for AI-generated code; oversees supply-chain and dependency concerns.
- **Engineering** – Writes implementation plans, code, manifests, and tests; builds prototypes, services, and data pipelines; hands off to SRE and Security for validation.
- **Research** – Tracks external news, tech trends, and data sources; produces comparative analyses and technical evaluations; informs PM and Engineering prioritization.
- **Marketing** – Packages Engineering outputs into assets: blurbs, landing pages, visuals; helps shape positioning and messaging; prepares artifacts for Biz3 and eventual public release.

The combination of these personas forms a closed-loop, multi-agent pipeline to explore, validate, and operationalize new ideas.

---

## Orchestrator Personas (Planner / Engineer / Executor)

At the repo level, an AI orchestrator manages work through three internal personas:

- **Planner** – Reads mission and backlog (`ai/mission.md` and `ai/backlog.md`); proposes high-level plans and decomposes goals into tasks; prioritizes which tasks to attempt in a given loop.
- **Engineer** – Translates tasks into concrete code and configuration changes; edits files in the repository following directory and stage constraints; proposes diffs, tests, and validation steps.
- **Executor** – Proposes or runs the necessary commands to apply changes (for example running scripts, triggering GitOps sync, or verifying cluster state); captures logs and outcomes into `ai/state/` and external log files; reports success or failure back to Planner and Engineer.

Implementation detail: The orchestrator is implemented on top of external LLM systems and tools (such as ChatGPT clients, code editors, and local scripts), but this document treats them abstractly as Planner / Engineer / Executor. A human operator remains in the loop to review diffs and confirm actions. This separation keeps the system safe, auditable, and recoverable, even as automation becomes more capable.

---

## High-Level Architecture Sketch

Conceptual text diagram, not exact wiring:

- Funoffshore Homelab
  - Proxmox (N100)
  - Talos VMs (control plane + workers)
  - Kubernetes cluster
  - Synology NAS with NFS exports and persistent volumes
- Talos-Managed Kubernetes
  - FluxCD GitOps
  - Ingress-nginx
  - Cloudflared tunnel
  - Basic monitoring stack (Prom / Graf / Loki)
- AI Studio services (Stage 2)
- Multi-biz workloads (Stage 3)
- AI Orchestrator
  - Planner / Engineer / Executor flows via LangGraph / LangChain
  - Reads/writes repo and coordinates with the operator
- Multi-Biz Engine
  - Biz2A / Biz2B / Biz2C experiments and services
  - Biz3 branding and external-facing assets

---

## Repository Layout

High-level directory map:

- `cluster/` – Talos templates and Kubernetes GitOps tree (for example: `kubernetes/flux`, `kubernetes/platform`, `kubernetes/apps`).
- `infrastructure/` – Proxmox VM bootstrap scripts (`infrastructure/proxmox/`) and room for future Terraform/Ansible.
- `config/` – Cluster definitions and environment files (`config/clusters/`, `config/env/`). No real secrets live here.
- `scripts/` – Local helper scripts such as `bootstrap_cluster.sh`, `check_cluster.sh`, `host_bootstrap.sh`, and other orchestration helpers.
- `synology/` – NAS and NFS/SMB configuration scripts or notes.
- `ai/` – Mission, backlog, persona prompts, AI Studio scaffolding, orchestrator state.
- `logs/` – Execution logs (gitignored); bootstrap scripts write timestamped logs here.
- `docs/` – Architecture documents and repo contract descriptions (for example `docs/architecture.md`, `docs/repo-contract.md`).

Secrets remain local or are stored using encryption tools such as SOPS. The `.talos/` directory remains untracked except for non-secret templates.

---

## Branching Rules & Canonical Branch

(The exact Git workflow can be tuned later; this section describes the intent.)

- The canonical branch for the cluster is the branch that Flux follows (for example `main`).
- Changes to infrastructure or apps should be made in feature branches and merged via review.
- The orchestrator should assume that only the canonical branch represents the desired cluster state.
- Experimental AI-driven edits can live in staging branches or forks and be merged only after human review.

---

## Secrets & Safety

- Real secrets (API keys, tokens, passwords) never live in this repository.
- Secrets are provided via local environment files, vaults, or encrypted mechanisms.
- The orchestrator personas must not create, print, or exfiltrate secrets.
- The human operator is always in the loop: reviews diffs; decides when to run scripts or apply manifests; can roll back via Git or restore from backups.

This project is experimental and intended for a single homelab. It is not hardened for production use in critical environments.

---

## How the Orchestrator Should Use This Document

The orchestrator should treat this document as the canonical narrative of “what we are trying to build.”

In each loop:

1. Read the current mission and stage from `ai/mission.md`.
2. Use the Stage Progress Snapshot and Roadmap sections to determine which stage is active.
3. Only generate tasks and plans that are valid for the current stage.
4. Use this document to understand target architecture, identify safe components to modify, and respect guardrails around secrets and safety.

The orchestrator must not jump ahead to Stage 2 or Stage 3 work while Stage 1 is incomplete, even if it technically could.

---

## Quickstart

### Quickstart A – Bootstrap the homelab cluster

1. Prepare hardware:
   - Proxmox installed and reachable
   - Synology NAS available with NFS exports
   - Local operator machine with necessary tools installed
2. Clone this repository to the operator machine.
3. Configure cluster and environment:
   - Copy and edit files in `config/clusters/` and `config/env/` for your N100 / Talos cluster.
   - Ensure addresses, node counts, and storage settings match your Proxmox and Synology setup.
4. Run the cluster bootstrap script from the appropriate directory, for example:
   - `infrastructure/proxmox/cluster_bootstrap.sh` creates or updates Proxmox VMs for control plane and workers, injects Talos machine configs, waits for the Kubernetes control plane to become reachable, installs Flux, and points it at `cluster/kubernetes/`.
5. Verify the cluster:
   - Confirm kubeconfig exists locally (for example `.talos/<cluster>/kubeconfig`).
   - Run `kubectl get nodes` and check nodes are Ready.
   - Confirm Flux is reconciling the GitOps tree.

### Quickstart B – Run the orchestrator loop (high-level)

1. Ensure Stage 1 is at least partially running and the repo is cloned locally.
2. Configure AI and tool credentials (OpenAI keys, local model endpoints, etc.) according to the harness scripts you use.
3. From the repo root, run the orchestrator harness script with the desired target, for example a script that:
   - Reads `ai/mission.md` and `ai/backlog.md`
   - Invokes Planner / Engineer / Executor loops
   - Proposes diffs or changes
   - Writes logs into `ai/state/` and `logs/`
4. Review proposed diffs and commands as a human operator:
   - Accept or reject changes
   - Run the safe commands to apply changes (for example applying manifests, restarting Flux, etc.)
5. Observe effects on the cluster using the monitoring stack and adjust `ai/mission.md` and `ai/backlog.md` as needed.

---

## Roadmap & Status

### Stage 1 – Homelab Platform

Goal: A stable, observable, GitOps-managed Talos/Kubernetes cluster on Proxmox with Synology-backed storage and Cloudflared ingress.

Milestones:

- Proxmox base configuration finalized
- Talos control plane and workers bootstrapped via `infrastructure/proxmox/cluster_bootstrap.sh`
- FluxCD installed and reconciling `cluster/kubernetes/`
- Ingress controller routing traffic for at least one sample app
- Cloudflared tunnel configured with DNS entries for public endpoints
- NFS storage from Synology mounted and used by at least one stateful workload
- Basic Prometheus / Grafana / Loki stack scraping cluster metrics

### Stage 2 – AI Studio and Biz2/Biz3 Engine

Goal: Use the homelab and AI Studio to incubate multiple AI-assisted business lines.

Milestones:

- AI Studio services deployed to the cluster
- Orchestrator flows implemented with LangGraph / LangChain
- OTel-based telemetry for AI Studio runs and key workloads
- Biz2A rapid-prototyping loop operational
- Biz2B technical depth track producing reusable services
- Biz2C commercialization track with at least one internal MVP
- Biz3 (or equivalent) handling branding / marketing assets

### Stage 4 – CPiaB (Horizon)

Goal: Turn the homelab control plane into a portable, sealed artifact that can bootstrap itself inside other environments.

Milestones (conceptual):

- CPiaB spec written (footprint, dependencies, expectations)
- Prototype image or bundle that can run in isolation on clean Proxmox or similar
- Automated environment discovery and node onboarding flows
- End-to-end story for migrating workloads between “banks” or other regulated environments

---

## Wishlist and Backlog Seeds

Directional ideas for future planning (not commitments).

**Homelab and Infrastructure**

- Full monitoring stack with dashboards for cluster health, node capacity, and app SLOs
- Centralized logging with retention tuned for homelab hardware
- Vault or SOPS-based secrets management wired into workload manifests
- Tailscale or WireGuard integration for secure remote access
- Multi-node expansion once the N100 cluster is fully stable

**CPiaB**

- CPiaB architecture design document under `ai/reports/`
- Prototype CPiaB “cluster-as-cargo” image
- Air-gapped reconciliation flow (no external network required)
- Reference exercise: migration between two fictional banks

**Biz2 / Biz3**

- Formal scoring system for Biz2A/B/C ideas (market size, feasibility, personal interest)
- Automated weekly Biz2 digest generated into `ai/reports/`
- Candidate product lines (for example: homelab tooling, infra safety tools, CPiaB consulting patterns)
- Basic public-facing site for Funoffshore hosted on the homelab

**Automation and Agents**

- Richer orchestrator logging and visualizations under a simple UI
- Guardrail tests that validate AI-generated manifests before they hit the cluster
- “Simulation mode” for orchestrator flows that never touch real infrastructure

---

## Current Status Snapshot

- **Stage 1 (Homelab):** In progress. Core scripts and structural layout exist; convergence and observability are still being hardened.
- **Stage 2 (AI Studio):** Locked until Stage 1 is reproducibly stable. Design ideas exist in `ai/studio/` and this document.
- **Stage 3 (Biz2/Biz3):** Concept defined, folders scaffolded; implementation depends on AI Studio maturity.
- **Stage 4 (CPiaB):** Concept defined; implementation deferred until the base platform is robust.
