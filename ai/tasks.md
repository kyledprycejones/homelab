# AI Tasks

## High Priority
- Keep `cluster_bootstrap.sh` focused on:
  - preflight, Talos/K8s bring-up, core infra (NFS + helm repos), gitops, postcheck
  - no direct app installs
- Refine `ai_harness.sh` to support more clusters and stages.
- Move Vault, ArgoCD, monitoring, logging, tunnels, and apps into `cluster/kubernetes/platform/` and `cluster/kubernetes/apps/` with Flux Kustomizations/HelmReleases.

## Future
- Add Wasm runtime manifests under `cluster/kubernetes/apps/wasm` (or similar).
- Add systemd/Quadlet unit templates and a host_bootstrap.sh for non-K8s workloads.
- Add docs in ai/design.md explaining the multi-runtime architecture.
