# Proxmox Bootstrap

Opinionated helpers for provisioning Talos-ready VMs on the N100 Proxmox host and wiring Flux GitOps.

## Contents
- `check_cluster.sh` – quick health/dependencies check against the Talos cluster (Talos + Flux objects).
- `vms.sh` – idempotent builder that clones the controller/worker VMs using the expected naming/IP layout.
- `cluster_bootstrap.sh` – the canonical Talos bootstrap pipeline (see “Bootstrap stages” below).
- `proxmox_bootstrap_nocluster.sh` – archived, Ubuntu-focused helper (kept for reference only).
- `wipe_proxmox.sh` – destructive cleanup that removes the Talos VMs, legacy snippets, and optionally the Talos ISO.

Scripts read values from `config/env/<cluster>.env` (when present) and from `config/clusters/<cluster>.yaml`. Keep secrets out of git; Talos configs live under `.talos/` locally.

## Bootstrap stages
`cluster_bootstrap.sh` drives the Talos control plane, infrastructure, and GitOps deployment. It understands the following stages:

- `precheck` / `preflight`: install host tools, print the effective config, and verify SSH reachability.
- `diagnose`: run the same precheck steps and dump cluster diagnostics (nodes, Flux objects, pods, events).
- `talos`: boot the Talos control plane/worker VMs, generate/apply configs, and wait for nodes. This stage also provisions the VMs via `vms.sh`.
- `infra`: deploy the minimal Synology-backed NFS provisioner and mark `nfs-storage` default; Vault/monitoring/logging/cloudflared are now left to Flux in `cluster/kubernetes`.
- `apps` / `gitops`: install Flux and sync `cluster/kubernetes/` (platform + apps).
- `postcheck`: summarize node health, Flux status, and cloudflared pods.
- `all`: run the stages in order.

The script now routes everything through Flux as the single GitOps path for the Talos runtime.

## Running the bootstrap
Always run from the repo root on the Proxmox host (N100). Do not run Talos stages from your laptop. For example:

```
# On the N100 Proxmox host
cd /Users/kyle/Documents/repos/homelab
./infrastructure/proxmox/cluster_bootstrap.sh talos
```

Capture output with `tee` if you want to save logs:

```
./infrastructure/proxmox/cluster_bootstrap.sh talos | tee logs/bootstrap-tal-${USER}-$(date +%s).log
```

Tip: From your workstation, you can trigger the run remotely on the N100:

```
ssh kyle@<n100-ip> '
  cd /Users/kyle/Documents/repos/homelab && \
  ./infrastructure/proxmox/cluster_bootstrap.sh talos
'
```

## Legacy cleanup
`wipe_proxmox.sh` still removes any legacy GitOps user-data snippets as part of the wipe, but the active stack is Talos + Flux only.
