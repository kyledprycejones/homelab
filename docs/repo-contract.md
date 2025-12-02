Repo Contract

This document defines how this repository is structured and what is allowed where.

The goal is:
	•	to keep infra, cluster, and apps cleanly separated,
	•	to make it easy for humans and AI tools to understand the layout,
	•	and to ensure everything can be managed via GitOps (Flux) and Talos.

If you add or change anything, it must respect this contract.

⸻

1. High-Level Principles
	1.	Monorepo
	•	This repo is the single source of truth for:
	•	Proxmox + host bootstrap
	•	Talos cluster config
	•	Kubernetes platform components
	•	Apps running on the cluster
	•	AI harness and automation scripts
	2.	GitOps First
	•	All Kubernetes state is declared here and reconciled by Flux.
	•	No manual kubectl apply long-term; ad-hoc changes must be back-ported into Git.
	3.	Layered Design
	•	Infrastructure (Proxmox, Synology, Terraform, etc.) lives below the cluster.
	•	Cluster (Talos + K8s) is the platform.
	•	Apps and AI tooling sit on top.
	4.	No Secrets in Plaintext
	•	Any real secret (Cloudflare tokens, registry creds, app passwords, etc.) is stored via SOPS + age.
	•	Talos machine secrets and age keys are stored locally, not in git.

⸻

2. Directory Layout & Responsibilities

.
├─ cluster/                # Talos + Kubernetes GitOps entrypoint
│  ├─ kubernetes/
│  │  ├─ apps/            # Workloads and their namespaces
│  │  ├─ flux/            # Flux system + Kustomizations
│  │  └─ platform/        # Ingress, storage, monitoring, dns, certs, mesh, etc.
│  └─ talos/              # Talos cluster + machine configs/patches
├─ infrastructure/
│  ├─ proxmox/            # Proxmox VM bootstrap, templates, helper scripts
│  ├─ terraform/          # (future) Infra as code (Cloud, DNS, etc.)
│  └─ ansible/            # (optional) Host/bootstrap automation
├─ config/
│  ├─ clusters/           # High-level cluster definitions (e.g. prox-n100.yaml)
│  └─ env/                # .env-style configs for scripts and harness
├─ scripts/                # Glue scripts and local tooling
├─ synology/               # NAS exports, NFS/SMB config, backup jobs
├─ ai/                     # AI harness, task descriptions, design docs
├─ logs/                   # Execution logs from bootstrap / harness
└─ docs/                   # Architecture diagrams, notes, this Repo Contract

2.1 cluster/ – Talos & Kubernetes

Purpose:
Everything that defines the running cluster and its workloads.

cluster/talos/
	•	Contains:
	•	talconfig.yaml / equivalent Talos config definitions
	•	controlplane.yaml, worker*.yaml machine configs or patches
	•	Any Kustomize overlays for Talos if used
	•	Rules:
	•	Only Talos-related YAML lives here.
	•	No Kubernetes manifests or app configs in this directory.
	•	Talos machine secrets are referenced, not inlined, when possible.

cluster/kubernetes/
This is what Flux watches.
	•	Rules for this tree:
	•	Every manifest here is intended to be reconciled by Flux.
	•	All manifests are valid, apply-able, and idempotent.
	•	No host/proxmox logic here; pure K8s.

cluster/kubernetes/flux/
	•	Flux controllers, GitRepository, Kustomization, HelmRelease that manage:
	•	platform/
	•	apps/
	•	Bootstrap entrypoint for GitOps.
	•	Rule:
	•	If Flux doesn’t know about it here, the cluster shouldn’t be running it.

cluster/kubernetes/platform/
Platform and “day-0 / day-1” components, e.g.:
	•	CNI (if applicable)
	•	Ingress controller
	•	Storage layer (NFS provisioner, Longhorn, etc.)
	•	DNS, cert-manager, external-dns, cloudflared tunnel
	•	Monitoring (Prometheus, Grafana, metrics-server)
	•	Logging (Loki, Promtail, etc.)
	•	Security baseline (PSPs, PSS, Gatekeeper/Kyverno, etc.)

Rules:
	•	Only cluster-wide platform services live here.
	•	Each platform concern gets its own folder, e.g.:

platform/
  ingress/
  storage/
  monitoring/
  logging/
  dns/
  certs/
  security/


	•	Namespaces for platform components should be created here too.

cluster/kubernetes/apps/
Actual workloads and homelab apps.
	•	Per-app folders, e.g.:

apps/
  jellyfin/
  nextcloud/
  ai-studio/
  demo-game/


	•	Each app folder owns:
	•	Its namespace
	•	HelmRelease or raw manifests
	•	App-specific ConfigMaps, Secrets (SOPS-encrypted), Ingress, Service, etc.

Rules:
	•	One app = one folder = one namespace (usually).
	•	No platform-wide components in apps/.
	•	App Secrets must be SOPS-encrypted where applicable.

⸻

3. infrastructure/ – Below the Cluster

infrastructure/proxmox/
	•	Host and VM level tooling, e.g.:
	•	cluster_bootstrap.sh (Talos + Flux bootstrap)
	•	proxmox_bootstrap_nocluster.sh
	•	wipe_proxmox.sh
	•	VM template docs/specs
	•	Rules:
	•	Shell scripts here assume Proxmox context, not K8s context.
	•	Scripts can read from config/ but never directly manage manifests in cluster/.

infrastructure/terraform/ (future)
	•	Terraform modules for:
	•	DNS records (Cloudflare, etc.)
	•	Cloud buckets / object storage
	•	Remote backup targets, etc.
	•	Rules:
	•	Terraform code must not drift from what the cluster expects; any DNS/ingress assumptions are documented in docs/architecture.md.

infrastructure/ansible/ (optional/future)
	•	Ansible playbooks/roles for:
	•	Bootstrapping Proxmox host
	•	Configuring PiKVM (if applicable)
	•	Synology or other hardware config

⸻

4. config/ – Cluster & Environment Config

config/clusters/
	•	Cluster definitions, e.g.:

config/clusters/prox-n100.yaml


	•	Contains high-level, declarative cluster metadata, such as:
	•	Cluster name
	•	Number and role of nodes
	•	IP address plan
	•	Talos version and config options
	•	Which Git repo/branch Flux should track

Rules:
	•	No secrets here.
	•	This is “source of truth” for scripts that generate Talos configs or derive env vars.

config/env/
	•	.env-style files for scripts and local tooling, e.g.:

config/env/prox-n100.env


	•	Typical contents:
	•	CLUSTER_NAME=prox-n100
	•	CTRL_IP=...
	•	WORKER_IPS=...
	•	FLUX_REPO_URL=...

Rules:
	•	No secrets here either (tokens, passwords, keys all go to SOPS).
	•	Values should be stable and reflect config/clusters/*.yaml.

⸻

5. scripts/ – Glue & Local Tooling
	•	Small utilities and helpers:
	•	ai_harness.sh
	•	host_bootstrap.sh
	•	Possibly wrapper scripts like ./scripts/bootstrap_cluster.sh or ./scripts/check_cluster.sh

Rules:
	•	Scripts here orchestrate other tools but do not embed cluster manifests.
	•	If a script needs cluster definition, it reads from config/.
	•	If it needs to apply manifests, it delegates to Flux or documented Talos workflows, not kubectl apply with raw YAML.

⸻

6. synology/ – NAS / External Storage
	•	Contains:
	•	Export definitions (NFS shares, SMB shares)
	•	Notes on how these exports are used by:
	•	Longhorn backup targets
	•	NFS provisioner
	•	Rules:
	•	No Kubernetes manifests here.
	•	This describes external storage behavior that the cluster depends on.

⸻

7. ai/ – AI Harness & Automation
	•	Design docs (design.md, tasks.md)
	•	Task specs for AI agents (Planner / Engineer / Executor)
	•	Any code/scripts specifically for AI-powered workflows

Rules:
	•	AI tools treat this repo contract as law.
	•	AI components may write to:
	•	cluster/kubernetes/* for manifests
	•	config/* for cluster definitions
	•	infrastructure/* for bootstrap scripts
	•	They must not:
	•	Put secrets in plaintext
	•	Create new top-level directories without updating this contract.

⸻

8. logs/ – Execution Logs
	•	Stores output from:
	•	cluster_bootstrap.sh
	•	Host/bootstrap runs
	•	AI harness tasks

Rules:
	•	No source code or manifests here.
	•	Safe to .gitignore most logs, but you may keep sample logs for documentation/debugging if they don’t include secrets.

⸻

9. docs/ – Documentation
	•	docs/architecture.md – hardware + topology overview.
	•	docs/repo-contract.md – this file.
	•	Any other diagrams and explanations.

Rules:
	•	Docs should always match reality; drift must be corrected in the next PR.
	•	Diagrams must be high-level enough that they survive small implementation changes.

⸻

10. Secrets & SOPS Contract
	•	Secrets must be:
	•	Encrypted with SOPS (age backend).
	•	Configured via `.sops.yaml` at repo root; age public keys live locally only.
	•	Stored alongside the resources that consume them, e.g.:
	•	cluster/kubernetes/platform/dns/secret.yaml (SOPS)
	•	cluster/kubernetes/apps/ai-studio/secret.yaml (SOPS)
	•	age keys:
	•	Stored locally on your workstation / N100 only.
	•	Never committed to git.
	•	Talos machine secrets:
	•	Managed via Talos tooling, not as raw YAML in git.
	•	Any references in git must be non-sensitive (IDs, not private keys).

⸻

11. Change Process (for Humans & AI)

When making changes:
	1.	Pick the correct layer:
	•	Host/VM change → infrastructure/
	•	Talos/K8s platform change → cluster/talos/ or cluster/kubernetes/platform/
	•	App change → cluster/kubernetes/apps/
	•	Config/env wiring → config/
	2.	Update docs if necessary:
	•	If a design or topology assumption changes, update docs/architecture.md and/or this Repo Contract.
	3.	Let Flux converge:
	•	For Kubernetes changes, commit + push and let Flux reconcile.
	4.	Keep things idempotent:
	•	Scripts and manifests must be safe to re-run.
	•	No one-off “snowflake” commands hidden in your shell history.
