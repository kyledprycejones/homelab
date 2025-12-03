# Stage 1 Talos Overview

This note captures the Talos-first bring-up flow for the homelab.

## Node Lifecycle
- Proxmox provisions VMs for control plane and optional workers with attached install disks.
- Talos images boot on each VM; control-plane and worker configs are pushed via `talosctl apply-config`.
- Etcd is bootstrapped on the control-plane node; workers simply join once configs are applied.
- Talos generates and serves the Kubernetes API and kubeconfig; long-term drift handled by GitOps.

## Proxmox → Talos Flow
1. Create/refresh VMs on the N100 Proxmox host with correct networking and disks.
2. Boot Talos ISO/pxe; ensure SSH reachability for initial commands.
3. Run `talosctl gen config` locally to produce controlplane.yaml and worker.yaml into `.talos/<cluster>/`.
4. Apply control-plane config to the controller IP, then apply worker configs to each worker IP (best-effort).
5. Bootstrap etcd via the controller endpoint and fetch kubeconfig for ongoing operations.

## `cluster_bootstrap.sh` Execution Model
- Run from a trusted host with access to the Proxmox VMs.
- Stages: `precheck` (tools + connectivity) → `k3s` (Talos bootstrap) → `infra` (NFS + defaults) → `apps` (Flux GitOps) → `postcheck` (report).
- Uses Talos variables (`TALOS_CLUSTER_NAME`, `TALOS_CONFIG_DIR`, `TALOS_KUBECONFIG`) and local helpers `kctl`/`helmctl` to target the generated kubeconfig.
- Worker join stage is a semantic no-op; Talos worker configs are already applied during bootstrap.

## GitOps Bootstrap Flow
- Optional local Git snapshot served from the controller (git daemon) when `USE_LOCAL_GIT_SNAPSHOT=1`.
- Flux installed locally into `flux-system`, pointing at `${GIT_REPO}@${GIT_BRANCH}` and syncing `./infra`.
- Core infra (ingress, storage, tunnels, monitoring) should converge via Flux rather than ad-hoc applies.

## Stage 1 Exit Criteria
- `.talos/<cluster>/kubeconfig` present and functional for `kubectl get nodes`.
- All control/worker nodes report Ready and use the nfs-storage default StorageClass.
- Flux GitRepository + Kustomization in `flux-system` are Healthy.
- NFS dynamic provisioning validated (PVC binds in nfs-provisioner namespace).
- Postcheck logs captured and archived under `ai/state/` for review.
