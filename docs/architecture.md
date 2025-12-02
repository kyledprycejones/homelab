# Homelab Architecture

## Hardware & Base Layer
- N100 Proxmox host running Talos VMs (control plane + workers).
- Synology NAS exporting NFS for shared storage; potential Longhorn disks per node.
- MacBook (control node) used by automation for talosctl/flux operations.

## Talos Cluster Overview
- Talos-first Kubernetes cluster; configs generated/applied via `infrastructure/proxmox/cluster_bootstrap.sh`.
- Flux reconciles `cluster/kubernetes/` (platform + apps) from Git.
- Talos artifacts (.talos/) stay local; non-secret templates live under `cluster/talos/`.

## Network Topology
- Proxmox bridges expose VMs on the LAN (default control plane: 192.168.1.151; workers: 192.168.1.152/153).
- Cloudflare Tunnel + (future) external-dns manage external reachability; ingress-nginx handles HTTP inside the cluster.
- Update `infrastructure/proxmox/network-layout.md` with VLAN/bridge specifics.

## Storage Layout
- Default: NFS dynamic provisioning via `platform/storage/nfs-subdir/` (nfs-storage default StorageClass).
- Optional: Longhorn HelmRelease stub (suspended) under `platform/storage/longhorn/` for local disk replication.
- Synology also serves as potential backup target for Longhorn snapshots.

## GitOps Surface
- Flux controllers installed by bootstrap scripts.
- GitRepository + Kustomizations defined in `cluster/kubernetes/flux/` point to platform and apps trees.
- Platform concerns split into ingress, storage, monitoring, logging, dns, certs, security.
