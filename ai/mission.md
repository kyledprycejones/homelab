Funoffshore Mission Statement (v1)

Core Purpose

Funoffshore exists to build two pillars:
	1.	A stable, fully automated homelab cluster
powering compute, storage, apps, user services, and operational tooling.
	2.	A multi-agent business incubator (Biz2/Biz3)
using local + cloud models to prototype product ideas, generate artifacts, analyze markets, and run experiments.

All agents must stay aligned to this document.
The system should never scope-creep beyond the active stage.

Stage 1 — Homelab Completion & Sample Applications

Goal: A fully reproducible and stable Kubernetes/Proxmox-based cluster.
Business experimentation is not allowed until Stage 1 is completed.

- [ ] Stage 1 complete (set by human/CLI when GitOps manifests + postcheck succeed)

Stage 1 Requirements

1. Cluster Foundation
	•	Proxmox host with controller + worker VMs
	•	Automated K3s bootstrap script
	•	GitOps (Flux or ArgoCD) fully operational
	•	Networking + DNS + TLS:
	•	Tailscale
	•	Cloudflare Tunnel (k3s Deployment + ConfigMap ingress)
	•	Reverse proxy
	•	Cert-manager / Origin CA

Cloudflare Tunnel Architecture (Stage 1 Scope):
	•	Secrets (CF_API_TOKEN, CF_TUNNEL_TOKEN, etc.) live only inside `config/env/<cluster>.env` and are never exposed to AI personas.
	•	Bootstrap/scripts render a Kubernetes Secret (`cloudflared-token`) from `${CF_TUNNEL_TOKEN}`; it is not tracked in Git.
	•	AI personas may only edit `infra/k8s/cloudflared/config.yaml` (ConfigMap) to add/update ingress routes when asked.
	•	`infra/k8s/cloudflared/deployment.yaml` and any other manifests remain human-authored; AI must not modify them.
	•	DNS entries are managed manually or via human-run scripts; AI never touches DNS or Cloudflare APIs.

2. Storage
	•	Synology NFS
	•	PVC provisioning
	•	VM + media backup strategy

3. Security & Identity
	•	Authentik for SSO
	•	Centralized OAuth for sample apps
	•	Secrets via SOPS or Vault

4. Observability
	•	Prometheus
	•	Grafana
	•	Loki + Alertmanager
	•	Dashboards for cluster, nodes, Arrs, networking

5. Sample Apps (Validation Layer)
	•	Jellyfin
	•	Jellyseerr
	•	Sonarr, Radarr, Prowlarr
	•	qBittorrent
	•	Bazarr
	•	Tailscale
	•	Cloudflare Tunnel (optional)
	•	Syncthing or backups
	•	Optional Dev Tools (Portainer, VSCode Server)

Rule:
All Stage 1 infrastructure must deploy end-to-end using GitOps and bootstrap scripts without manual intervention.

Stage 2 — Multi-Agent Biz Engine (Biz2/Biz3)

Unlocked only when Stage 1 is complete.

- [ ] Stage 2 unlocked (set by human after verifying Stage 1 completion)

Stage 2 Goals
	•	Multi-agent runtime inside ai/studio
	•	Workflow system (daily digest, prototype loop, opportunity scans)
	•	Biz2: research + prototyping
	•	Biz3: packaging + publishing
	•	Data stored under ai/studio/memory, reports, news_digest

Stage gating rule:
The Orchestrator cannot initiate Biz2/Biz3 workflows until Stage 1 completion is confirmed (presence of all Stage 1 GitOps components and a cluster health check) and marked via the Stage 1 checkbox or `stage_1_complete` flag in `ai/state/status.json`.

END OF MISSION STATEMENT
