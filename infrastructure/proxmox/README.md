# Proxmox Bootstrap

Opinionated helpers for bootstrapping Ubuntu Server VMs on the N100 Proxmox host and arriving at a k3s + Flux cluster.

## Contents
- `provision_vms.sh` – idempotent builder that downloads an Ubuntu Server cloud image, creates the control-plane and worker VMs, and injects cloud-init data (static IPs + SSH key).
- `cluster_bootstrap.sh` – the new Stage 1 harness with `preflight`, `k3s`, and `postcheck` stages that install k3s, distribute agents, grab the kubeconfig, and verify node health.
- `check_cluster.sh` – lightweight health check that uses the repo-local kubeconfig produced by the bootstrap stage to inspect nodes, core DNS pods, and Flux.
- `wipe_proxmox.sh` – destructive cleanup that removes the k3s VMs, cached cloud image, and any generated kubeconfig/token artifacts.

Scripts read configuration from `config/clusters/prox-n100.yaml` (controller IP + worker IPs) and from `config/env/prox-n100.env` for sensitive overrides (SSH user/key, Git branch, etc.).

## Provisioning Ubuntu VMs

`provision_vms.sh` now provisions Ubuntu Server (minimal) VMs using the cloud image from `https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img` by default. It expects:

1. `controller.ip` and the `workers` list inside `config/clusters/prox-n100.yaml` for the static IP layout.
2. A public SSH key at `${HOME}/.ssh/id_ed25519.pub` or `SSH_PUBLIC_KEY_FILE` if overridden in `config/env/prox-n100.env` or your shell.
3. `PROXMOX_STORAGE` pointing at a storage pool with image/content support (it auto-detects Synology NFS if not set).

The script:

- downloads the cloud image into `/mnt/pve/<storage>/template/cloudimg/` (or `$HOME/.cache/homelab_ubuntu` when running in stub mode);
- creates VMs with default CPU/memory/disk specs, attaches a qcow2 disk from the cloud image, and resizes the disk to the configured size;
- injects cloud-init configuration (user, SSH key, hostname, static IP, nameserver) via the built-in Proxmox cloudinit disk;
- starts each VM when the configuration is applied.

Override defaults via env variables such as `CTRL_VMID`, `WORKER_VMIDS`, `WORKER_NAMES`, `WORKER_CPU`, and `NETWORK_GATEWAY`. The script prints the assigned IPs and reminds you to run `cluster_bootstrap.sh k3s` next.

## Bootstrapping k3s (Stage 1)

`cluster_bootstrap.sh` replaces the legacy bootstrap workflow. It exports `preflight`, `k3s`, and `postcheck` stages. Use `./cluster_bootstrap.sh <stage>` from the repo root on the Proxmox host or another machine with SSH access to the VMs.

- `preflight` installs `kubectl` locally and checks SSH/TCP connectivity against the controller and worker IPs defined in the cluster config.
- `k3s` ensures `curl` exists on every node, installs the k3s server on the control plane, installs agents on each worker, copies the kubeconfig back to `infrastructure/proxmox/k3s/kubeconfig`, and stores the node token alongside it.
- `postcheck` uses the repo-local kubeconfig to wait for all nodes to report `Ready`, lists kube-system pods, and prints node/pod status for quick debugging.

By default, `./cluster_bootstrap.sh all` runs the three stages in order. Passing `k3s` alone still runs `preflight` first so prerequisites are satisfied.

k3s installs leave swap enabled on every node (per the Stage 1 architecture), so no `swapoff` or kubelet swap checks are injected during the bootstrap.

The kubeconfig lives under `infrastructure/proxmox/k3s/kubeconfig`. Export it with `export KUBECONFIG=infrastructure/proxmox/k3s/kubeconfig` before running further `kubectl` commands outside the bootstrap script.

## Health Checks and Cleanup

- `check_cluster.sh` reads `infrastructure/proxmox/k3s/kubeconfig` (overridable via `KUBECONFIG_PATH`) and reports `kubectl get nodes`, DNS pods, and Flux kustomizations.
- `wipe_proxmox.sh` destroys the control-plane and worker VM IDs, removes the cached Ubuntu image, and optionally deletes `infrastructure/proxmox/k3s/` artifacts so you can start fresh.

Run `wipe_proxmox.sh` as root on the Proxmox host when you want to tear down the Stage 1 environment and rebuild it from scratch.
