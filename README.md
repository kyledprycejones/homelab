# Funoffshore Homelab & Multi-Biz AI Engine

> **Tagline:** A self-maintaining homelab that incubates multiple AI-driven businesses.

This repository is the **canonical source of truth** for the Funoffshore homelab and its AI-assisted business engine.  
It describes:

- The **current reality** of the cluster  
- The **target architecture**  
- The **long-term vision** for running a portfolio of businesses on top of a single, reproducible control plane  

This README is intentionally written as an **Apple-style tech brief + architectural manifesto**. It should be readable by:

- Humans (Kyle, future collaborators, auditors)  
- AI personas (chatgpt, sidebar, cli, orchestrator agents)  

and used as the **primary narrative input** when generating backlogs, roadmaps, and automation plans.

---

## 📚 Table of Contents

0. [Stage Progress Snapshot (Backlog Seed)](#-stage-progress-snapshot-backlog-seed)  
1. [Vision](#-vision)  
2. [Stage 1 – Homelab Platform](#-stage-1--homelab-platform)  
3. [Control-Plane-in-a-Box (CPiaB)](#-control-plane-in-a-box-cpiab)  
4. [Stage 2 – Multi-Business Engine (Biz2 / Biz3)](#-stage-2--multi-business-engine-biz2--biz3)  
5. [Business Units (Biz2A / Biz2B / Biz2C)](#-business-units-biz2a--biz2b--biz2c)  
6. [Multi-Business Lines & Personas](#-multi-business-lines--personas)  
7. [Personas & Multi-Agent Orchestration](#-personas--multi-agent-orchestration)  
8. [High-Level Architecture Diagram](#-high-level-architecture-diagram)  
9. [Repository Layout](#-repository-layout)  
10. [Branching Rules & Canonical Branch](#-branching-rules--canonical-branch)  
11. [Secrets & Safety](#-secrets--safety)  
12. [How the Orchestrator Should Use This README](#-how-the-orchestrator-should-use-this-readme)  
13. [Roadmap & Status](#-roadmap--status)  
14. [Wishlist / Backlog Seeds](#-wishlist--backlog-seeds)  
15. [Current Status (High-Level)](#-current-status-high-level)

---

## 🚦 Stage Progress Snapshot (Backlog Seed)

| Stage | Scope | Status | Unlock Condition |
| --- | --- | --- | --- |
| **Stage 1 – Homelab Bring-Up** | Proxmox + k3s + Flux; ingress, tunnel, monitoring, storage, sample apps | Active (in progress) | GitOps manifests for every Stage 1 requirement + successful postcheck (`stage_1_complete` checkbox/flag) |
| **Stage 2 – Biz2/Biz3** | AI Studio workflows, Biz incubators, multi-agent experiments | Locked | Stage 1 marked complete and approved |

- Stage details + checkboxes: `ai/mission.md`.  
- Active backlog: `ai/backlog.md` (Stage 1 items auto-synced by scripts/executor/stage1_backlog_sync.py).  
- **Orchestrator directive:** Use this table and the Stage 1 requirements below to seed/refresh backlog items before each loop. Do not select Stage 2 work until Stage 1 is marked complete.

---

## 🎯 Vision

Funoffshore is building:

> **A fully automated, self-maintaining homelab cluster that can power multiple AI-assisted businesses.**

Core principles:

- **Reproducibility** – The entire stack (from bare metal to apps) can be rebuilt from this repo.  
- **GitOps-first** – Configuration lives in Git; the cluster converges to match Git, not the other way around.  
- **Multi-tenant by design** – One homelab, many businesses (Biz2A/B/C, Biz3, future units).  
- **Agent-driven evolution** – AI personas propose, implement, and test changes under strict guardrails.  
- **Portability** – The control plane can be moved, replicated, or shipped as an artifact (see CPiaB).

This README captures both **what exists now** and **where we want to go**, so the orchestrator can always answer:

- “What is the intended architecture?”  
- “What is safe to change next?”  
- “How do we turn this into a real business line?”

---

## 🛰 Stage 1 – Homelab Platform

Stage 1 is about building a **solid, reproducible homelab** that everything else rests on.

### Hardware & Base Layer

- **Proxmox** on the N100 mini-PC (primary compute node)  
- **Synology DiskStation** providing NFS-backed storage  
- **Local MacBook** as a high-powered, Wi-Fi-connected control node for AI and orchestration  

### Kubernetes & Core Components

The cluster is based on:

- **k3s** – Lightweight Kubernetes distribution for the control plane  
- **FluxCD** – GitOps engine that reconciles `infra/` into the running cluster  
- **Traefik** – Ingress controller managing HTTP/S traffic inside the cluster  
- **Cloudflared Tunnel** – Secure entry point from the public internet into select internal services  
- **Prometheus / Grafana / Loki** (planned) – Observability stack for metrics, dashboards, and logs  
- **Vault or similar secrets management** (planned) – Centralized handling of sensitive data  

### Storage & Networking

- **Synology NFS exports** mounted into the cluster for stateful workloads (media, databases, logs).  
- Internal networking starts simple, then evolves toward **multi-AZ / multi-cluster** patterns as needed.  
- **Cloudflared** provides an outbound-only tunnel so no direct inbound ports need to be opened on the homelab.

### Stage 1 Outcome

A **stable, observable, GitOps-managed platform** capable of running:

- Media and personal apps (Arr stack, Jellyfin, qBittorrent, etc.)  
- Utility services (VPN, DNS, tunnels)  
- AI Studio and Biz2/Biz3 workloads  

---

## 🧳 Control-Plane-in-a-Box (CPiaB)

Funoffshore is incubating a long-term initiative called **Control-Plane-in-a-Box (CPiaB)** — a fully sealed, **portable Kubernetes control plane** capable of bootstrapping itself *inside* another organization’s infrastructure.

This pattern has historical precedent in **high-security financial-sector migrations**, where a cluster from *Bank A* is deployed parasitically across the hardware stack of *Bank B*, gradually:

- Discovering resources  
- Onboarding nodes  
- Reconciling the entire environment back to a canonical GitOps repo  

### CPiaB Goals

CPiaB aims to deliver:

- A **self-contained k3s control plane** (sealed, reproducible, air-gap friendly)  
- **Automated discovery** of hardware, networks, and service endpoints  
- **Zero-trust node onboarding**, certificate minting, and identity propagation  
- **Declarative expansion** of workloads across the target infrastructure  
- **Full GitOps reconciliation** against a canonical repository (this one or a derivative)  
- **Cluster-as-Cargo deployments** suitable for regulated industries  
- **Migration pathways** for financial institutions, legacy datacenters, or cloud exits  

In the Funoffshore context, CPiaB is both:

1. A **concrete technical target** for the homelab architecture.  
2. A **future business unit** that could be productized once the system is reliable.  

This initiative is one of the active R&D lines under the Funoffshore homelab and will eventually form part of the **Stage 2+ multi-business engine** once the base platform reaches complete reproducibility.

---

## 🧵 Stage 2 – Multi-Business Engine (Biz2 / Biz3)

Once the homelab reaches stability, the repo activates **Biz2 / Biz3**, an AI-powered research and prototyping studio.

It uses:

- A local-first **AI Studio** (`ai/studio/`)  
- Multi-agent workflows (PM → Architect → Engineer → Researcher → Marketer)  
- Local LLMs via Ollama and optional cloud models  
- Experiment tracking via `ai/memory/`, `ai/reports/`, and automated news digests  

This allows the homelab to run **multiple AI-assisted business lines in parallel** — each incubated, evaluated, and promoted through a repeatable pipeline.

---

## 🏭 Business Units (Biz2A / Biz2B / Biz2C)

Funoffshore’s AI ecosystem is structured not as a single venture but as a **multi-unit R&D engine**.  
Each business unit is a lane of ideation, engineering, and validation — designed so the orchestrator can **autonomously generate, filter, and advance opportunities**.

### Biz2A — Rapid Prototyping Unit

A high-velocity experimentation track focused on:

- 24–72 hour prototypes  
- Market-signal testing  
- Lightweight frontends and mock integrations  
- Fast PM → Architect → Engineer loops  
- High idea volume, low cost of failure  

Biz2A is the **idea explosion pipeline** feeding the entire system.

### Biz2B — Technical Depth Unit

Where engineering rigor begins. Biz2B produces:

- Real services (Go / Python / Node)  
- Systems design artifacts  
- Research-driven technical evaluations  
- Early backend APIs  
- Homelab-native workloads (Kubernetes microservices, operators, pipelines)  

Biz2B creates the first **durable engineering assets** inside the incubator.

### Biz2C — Commercialization Unit

Only a small fraction of concepts graduate here. Biz2C focuses on:

- Real users and early adoption  
- Positioning, branding, and messaging  
- Product shaping & pricing  
- SLA-aware design, SRE & Security sign-off  
- Deployment & monitoring inside the Funoffshore cluster  

Biz2C is where a concept becomes a **minimum viable product**, ready for Biz3 and external exposure.

Each Biz unit mirrors real-world organizational structure — allowing the orchestrator to generate plans, backlogs, and multi-persona workflows with **clarity and repeatability**.

---

## 🏢 Multi-Business Lines & Personas

The Funoffshore platform is designed to incubate **multiple AI-assisted businesses in parallel**, each with its own lifecycle, metrics, and development pipeline.  
Biz2/Biz3 serve as the initial incubators, but the structure supports essentially **unlimited business lines**.

Each business is staffed by internal AI personas that mirror real operational roles:

### Product Management (PM)

- Defines market requirements and customer problems.  
- Writes opportunity briefs, acceptance criteria, and experiment scopes.  
- Prioritizes features through the Biz2 backlog.

### SRE (Site Reliability Engineering)

- Ensures each business’s infrastructure is observable, scalable, and fault-tolerant.  
- Works with monitoring stacks, alerting rules, service-level targets.  
- Validates deployment health through the homelab cluster.

### Security

- Hardens the homelab and all Biz projects.  
- Performs threat modeling, secret-flow analysis, and supply-chain checks.  
- Ensures all AI-generated code adheres to safe patterns.

### Engineering

- Writes implementation plans, code, manifests, and tests.  
- Builds prototypes, services, dashboards, and full product slices.  
- Hands deliverables to SRE + Security personas for validation.

### Research

- Scans external news, trends, and datasets.  
- Generates competitive analyses and technical evaluations.  
- Provides PM with insight for opportunity scoring.

### Marketing

- Packages the output of Engineering into materials for Biz3.  
- Writes product blurbs, landing pages, and positioning.  
- Prepares assets for future commercial rollout.

Each business line moves through these personas in sequence — forming a **closed-loop, multi-agent AI development pipeline** that can explore, validate, and operationalize new ideas at high speed.

---

## 🧠 Personas & Multi-Agent Orchestration

At the repo level, the system is managed via a **split-persona orchestration model**:

- **chatgpt (Architect / Strategist)**  
  Designs high-level plans, writes memos, updates this README, and defines mission stages.

- **sidebar (Engineer / Junior)**  
  Edits files, maintains repo structure, generates manifests, and manages branches.  
  Operates under strict directory and stage constraints.

- **cli (Hands / Executor)**  
  Runs scripts on the N100, applies manifests, performs flux/helm/kubectl operations, and reports logs back.

Key ideas:

- **Architect plans → sidebar implements → cli executes.**  
- Secrets are never exposed to sidebar or chatgpt; they live only in local env files.  
- Mission stages in `ai/mission.md` define which directories and business units are “open” for work.

This separation keeps the system **safe, auditable, and recoverable**, even as automation gets more aggressive.

---

## 🧩 High-Level Architecture Diagram

```text
┌──────────────────────────────────────────────────────────┐
│                    Funoffshore Homelab                   │
│                                                          │
│  ┌──────────────┐    ┌──────────────────────────────┐   │
│  │   Proxmox    │    │        Synology NAS          │   │
│  └──────┬───────┘    └──────────────┬───────────────┘   │
│         │                            │                   │
│   ┌─────▼────────────────────────────▼───────┐           │
│   │                k3s Cluster               │           │
│   │  (FluxCD, Traefik, Cloudflared, Apps)   │           │
│   └─────┬────────────────────────────────────┘           │
│         │                                                │
│   ┌─────▼────────┐     ┌──────────────────────────────┐ │
│   │ AI Orches.   │     │     Multi-Biz Engine (Biz2)  │ │
│   │ chatgpt      │     │  Biz2A / Biz2B / Biz2C       │ │
│   │ sidebar      │     │  Biz3 (brand + market)       │ │
│   │ cli          │     └──────────────────────────────┘ │
│   └──────────────┘                                        │
└──────────────────────────────────────────────────────────┘


⸻

📁 Repository Layout

High-level directory map:
	•	ai/ – Mission, backlog, persona prompts, orchestrator docs, AI studio scaffolding for Biz2/Biz3.
	•	config/ – Cluster configs and environment overrides.
👉 Secrets in config/env/ stay local and must never be committed.
	•	infra/ – Kubernetes/Flux manifests (cloudflared, monitoring, apps, ingress, storage, etc.).
	•	prox/ – Proxmox and bootstrap scripts (k3s installers, node prep, cluster helpers).
	•	scripts/ – Orchestration helpers (ai_harness.sh, host/bootstrap utilities, local helpers).
	•	logs/ – Runtime logs (gitignored). Summaries and views live under ui/logs/.
	•	synology/ – NAS and NFS configuration for the DiskStation.
	•	ui/ – Static log viewer and indexing tools.

The orchestrator should treat this layout as contractual: new work must respect these boundaries unless explicitly authorized by an updated plan.

⸻

🌳 Branching Rules & Canonical Branch
	•	main is the canonical branch and single source of truth.
	•	Always sync main before creating new work.

AI- or automation-generated branches use the pattern:

sidebar/<slug>-YYYYMMDD

Examples:
	•	sidebar/cloudflared-20251127
	•	sidebar/monitoring-stack-20251201

Branches should:
	•	Always be based on main.
	•	Contain focused, reviewable changes (one feature/bugfix per branch where possible).
	•	Be merged via standard Git workflows outside of automation.

Additional orchestration quick rules:
	•	Personas: Architect (planning), Junior (repo edits), Hands (commands), Narrative (optional summaries).
Definitions live in ai/agents/.
	•	Mission stages in ai/mission.md control what directories the AI may touch
(Stage 1 = homelab infra only; Stage 2 = Biz2/Biz3).
	•	Full workflow/branching rules are documented in CONTRIBUTING.md and ai/README.md.

⸻

🔒 Secrets & Safety

Non-negotiable rules:
	•	All secrets live exclusively in config/env/ and are never committed.
	•	sidebar may modify manifests and non-secret configs, but only cli interacts with the live cluster.
	•	Any script that could destroy data or reformat disks must:
	•	Live in a clearly named path (e.g., prox/wipe_*, scripts/dangerous_*).
	•	Be documented and never invoked by automation without explicit human approval.
	•	Cloudflared ingress routes live in infra/k8s/cloudflared/ and are the only tunnel-related files automation may edit.

If an agent is unsure whether an operation is safe, it should:
	1.	Propose the change in a plan or README / ai/ doc.
	2.	Wait for human approval before touching code or infra.

⸻

🤖 How the Orchestrator Should Use This README

This README is the source of truth for intent. Automation should:
	1.	Read this document first when planning work.
	2.	Use the sections above to infer:
	•	Current stage (1 vs 2)
	•	Which directories are in scope
	•	Which business units are active
	3.	Generate or update:
	•	ai/mission.md – high-level mission and stage definition
	•	ai/tasks.md or equivalent – concrete tasks and backlog items
	•	Branches under sidebar/* with focused commits
	4.	Avoid:
	•	Inventing new, undocumented architectures
	•	Touching secrets or env files
	•	Modifying dangerous scripts without explicit sign-off

In other words: this README is the north star.

If the code and README disagree, the orchestrator should either:
	•	Propose README updates to match reality, or
	•	Propose code changes to match the README — but never silently diverge.

⸻

🗺 Roadmap & Status

Stage 1 – Homelab Platform

Goal: A stable, observable, GitOps-managed k3s cluster on Proxmox with Synology-backed storage and Cloudflared ingress.

Core milestones:
	•	Proxmox base configuration finalized
	•	k3s cluster bootstrapped via cluster_bootstrap.sh
	•	FluxCD installed and reconciling infra/
	•	Traefik ingress routing traffic for at least one sample app
	•	Cloudflared tunnel configured with DNS entries for public endpoints
	•	NFS storage from Synology mounted and used by at least one stateful workload
	•	Monitoring stack (Prometheus / Grafana / Loki) deployed and scraping cluster metrics

Stage 2 – Biz2 / Biz3 Engine

Goal: Use the homelab to incubate multiple AI-assisted business lines.
	•	AI Studio wired into homelab (local + cloud LLMs)
	•	Biz2A rapid-prototyping loop operational
	•	Biz2B technical depth track producing reusable services
	•	Biz2C commercialization track with at least one internal MVP
	•	Biz3 handling branding/marketing artifacts for promising ideas

CPiaB – Control-Plane-in-a-Box

Goal: Turn the homelab control plane into a portable, sealed artifact that can bootstrap itself inside other environments (e.g., financial institutions).
	•	Define minimal CPiaB spec (footprint, dependencies, expectations)
	•	Package a k3s + Flux bundle that can run in isolation
	•	Automate environment discovery and secure node onboarding
	•	Document a reference “bank-to-bank migration” story and technical flow

⸻

📝 Wishlist / Backlog Seeds

This section exists primarily for the orchestrator and future planning.
These are not commitments, but strong directional ideas that can be turned into issues, branches, or experiments.

Homelab / Infra
	•	Full monitoring stack (Prometheus / Alertmanager / Grafana / Loki) with dashboards for:
	•	Cluster health
	•	Node capacity
	•	App SLOs
	•	Centralized logging with retention tuned for homelab hardware limits
	•	Vault or SOPS-based secret management integration (while keeping actual secrets out of Git)
	•	Tailscale or WireGuard integration for secure remote admin access
	•	Multi-node k3s expansion once the N100 cluster is stable

CPiaB
	•	CPiaB design doc under ai/reports/ explaining the full architecture
	•	Prototype CPiaB image that can be booted on a clean Proxmox node
	•	Air-gapped reconciliation flow (no external network required)
	•	Playbook for “cluster-as-cargo” deployment inside a mock financial environment

Biz2 / Biz3
	•	Formal scoring system for Biz2A/B/C ideas (market size, feasibility, personal interest)
	•	Automated weekly Biz2 digest generated into ai/reports/
	•	One or more candidate product lines (e.g., homelab tooling, infra safety tools, CPiaB consultancy)
	•	Basic public-facing site for Funoffshore (hosted on this homelab)

Automation & Agents
	•	Richer orchestrator logging and visualizations under ui/logs/
	•	Guardrail tests that validate AI-generated manifests before they hit the cluster
	•	Simulation mode: dry-run orchestration flows without touching real infra

⸻

📌 Current Status (High-Level)
	•	Stage 1 (Homelab): In progress – core scripts and infra structure exist, but convergence and observability are still being hardened.
	•	Stage 2 (Biz2/Biz3): Locked until Stage 1 reaches reproducible stability.
	•	CPiaB: Concept defined, early design ideas in place; implementation pending homelab maturity.

This repo is the homepage of the Funoffshore homelab:
a living architectural document, a planning surface for AI personas, and the launching pad for future businesses.
