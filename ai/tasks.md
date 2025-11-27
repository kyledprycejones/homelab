# AI Tasks

## High Priority
- Keep `cluster_bootstrap.sh` focused on:
  - preflight, k3s, infra (NFS + helm repos), gitops, postcheck
  - no direct app installs
- Refine `ai_harness.sh` to support more clusters and stages.
- Move Vault, ArgoCD, monitoring, logging, tunnels, and apps into infra/ with Flux Kustomizations/HelmReleases.

## Future
- Add Wasm runtime manifests under infra/wasm.
- Add systemd/Quadlet unit templates and a host_bootstrap.sh for non-K8s workloads.
- Add docs in ai/design.md explaining the multi-runtime architecture.
