# Funoffshore Homelab - Master Architecture Memo

This document defines the canonical Stage 1 architecture for the Funoffshore Homelab. It is the source of truth for what the homelab must become. The orchestrator drives the repository toward this specification.

**This file is protected and should only be modified by humans.**

---

## Overview

The Funoffshore Homelab is a self-hosted Kubernetes environment running on Proxmox virtualization. It follows a GitOps model using Flux CD for continuous delivery.

### Core Principles

1. **GitOps First** - All configuration lives in Git. Changes flow through pull requests.
2. **Immutable Infrastructure** - Talos Linux provides an immutable, API-driven OS.
3. **Declarative Configuration** - Kubernetes manifests define desired state.
4. **Observable by Default** - Full metrics, logs, and traces from day one.
5. **Secure by Default** - Secrets managed externally, minimal attack surface.

---

## Proxmox

The hypervisor layer runs on bare metal N100 mini-PCs.

### Hardware

- **Nodes**: 1-3 N100 mini-PCs
- **RAM**: 16GB per node
- **Storage**: NVMe SSD + Synology NAS via NFS

### Virtual Machines

| VM | Role | vCPU | RAM | Disk |
|----|------|------|-----|------|
| talos-cp-1 | Control Plane | 2 | 8GB | 40GB |
| talos-w-1 | Worker | 2 | 4GB | 32GB |
| talos-w-2 | Worker | 2 | 4GB | 32GB |

### Networking

- **Bridge**: `vmbr0` for VM networking
- **VLAN**: Optional segmentation for management traffic
- **DHCP**: Static leases for Talos nodes

---

## Talos

Talos Linux is the Kubernetes distribution. It provides:
- Immutable, API-driven OS
- No SSH, no shell - all management via `talosctl`
- Automatic updates and security patches

### Cluster Configuration

- **Cluster Name**: `prox-n100`
- **Kubernetes Version**: Latest stable (1.29+)
- **Control Plane**: 1 node (HA optional for future)
- **Workers**: 2 nodes

### Key Files

| File | Purpose |
|------|---------|
| `cluster/talos/talconfig.yaml` | Talhelper configuration |
| `cluster/talos/controlplane.yaml` | Control plane machine config |
| `cluster/talos/worker.yaml` | Worker machine config |

### Bootstrap Flow

1. VMs boot from Talos ISO
2. `talosctl gen config` creates machine configs
3. `talosctl apply-config` pushes configs to nodes
4. `talosctl bootstrap` initializes etcd on control plane
5. `talosctl kubeconfig` retrieves cluster access

---

## Kubernetes

The cluster runs standard Kubernetes with GitOps-managed workloads.

### Namespaces

| Namespace | Purpose |
|-----------|---------|
| `flux-system` | Flux CD controllers |
| `kube-system` | Core Kubernetes components |
| `longhorn-system` | Longhorn storage |
| `nfs-provisioner` | NFS dynamic provisioner |
| `ingress-nginx` | Ingress controller |
| `cloudflared` | Cloudflare tunnel |
| `monitoring` | Prometheus, Grafana, Alertmanager |
| `apps` | User applications |

### Storage

Two storage classes are available:

1. **Longhorn** (`longhorn`) - Block storage with replication
   - Replicas: 2
   - Reclaim: Delete
   - Use for: Databases, stateful apps

2. **NFS** (`nfs-storage`) - File storage on Synology
   - Default StorageClass
   - Reclaim: Retain
   - Use for: Media, backups, shared data

---

## Flux

Flux CD provides GitOps capabilities.

### Repository Structure

```
cluster/kubernetes/
├── flux/
│   ├── gotk-components.yaml  # Flux controllers
│   ├── gotk-sync.yaml        # GitRepository + root Kustomization
│   └── apps.yaml             # Apps Kustomization
├── platform/
│   ├── kustomization.yaml
│   ├── storage/              # Longhorn, NFS
│   ├── ingress/              # ingress-nginx, cloudflared
│   ├── monitoring/           # Prometheus, Grafana
│   └── certs/                # cert-manager (future)
└── apps/
    └── (user applications)
```

### Kustomizations

| Name | Path | Dependencies |
|------|------|--------------|
| `flux-system` | `cluster/kubernetes/flux` | None |
| `platform` | `cluster/kubernetes/platform` | flux-system |
| `apps` | `cluster/kubernetes/apps` | platform |

### Reconciliation

- **Interval**: 5 minutes
- **Pruning**: Enabled (removes orphaned resources)
- **Health Checks**: Enabled

---

## Ingress

External access is provided via Cloudflare Tunnel.

### Components

1. **ingress-nginx** - Kubernetes ingress controller
   - Handles routing within the cluster
   - Terminates internal TLS (optional)

2. **cloudflared** - Cloudflare tunnel client
   - Connects to Cloudflare edge
   - No inbound ports required
   - Automatic TLS at edge

### DNS

- **Domain**: `funoffshore.com`
- **Records**: Managed by Cloudflare
- **Subdomains**: Point to tunnel

---

## Observability

Full observability stack for metrics, logs, and traces.

### Metrics

- **Prometheus** - Metric collection and alerting
- **Grafana** - Visualization dashboards
- **Alertmanager** - Alert routing and notification

### Logging

- **Loki** - Log aggregation (future)
- **Promtail** - Log collection (future)

### Dashboards

Default dashboards include:
- Talos node overview
- Kubernetes cluster overview
- Flux reconciliation status
- Longhorn storage health

---

## Security

### Secrets Management

- Kubernetes Secrets for runtime credentials
- SOPS encryption for Git-stored secrets (future)
- External secrets operator for Vault integration (future)

### Network Policies

- Default deny in sensitive namespaces (future)
- Allow lists for known traffic patterns

### RBAC

- Minimal service account permissions
- No cluster-admin for applications

---

## Disaster Recovery

### Backup Strategy

1. **etcd** - Talos automatic snapshots
2. **Longhorn** - Scheduled volume backups to NFS
3. **Git** - All configuration versioned

### Recovery Procedure

1. Provision new VMs
2. Apply Talos configs
3. Bootstrap cluster
4. Restore etcd snapshot (if needed)
5. Flux reconciles workloads from Git

---

## Stage 1 Scope

Stage 1 includes:
- ✅ Proxmox + Talos Kubernetes
- ✅ GitOps (Flux)
- ✅ Longhorn + NFS storage
- ✅ Ingress (nginx + Cloudflare)
- ✅ Observability (Prometheus/Grafana)
- ✅ Core homelab apps

Stage 1 excludes:
- ❌ AI Studio (Stage 2)
- ❌ Multi-business automation (Stage 3)
- ❌ Advanced HA configurations
- ❌ Multi-cluster federation

---

## Operational Invariants

These rules must always hold:

1. **No direct kubectl edits** - All changes via Git
2. **No manual secrets** - Use sealed secrets or external operators
3. **No orphaned resources** - Flux prunes what Git doesn't define
4. **Logs are preserved** - All orchestrator actions logged
5. **Changes are reversible** - Git history enables rollback

---

*This memo is maintained by the human operator and defines the target state for the Funoffshore Homelab Stage 1.*
