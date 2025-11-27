# Design Notes

- Thin bootstrapper only handles k3s install, minimal storage, Flux GitOps wiring, and smoke checks.
- All platform and app stacks should live under `infra/` (Kustomizations/HelmReleases) and sync via Flux from the Git repo.
- Cluster/env config lives in `config/` with secrets supplied via `.env` files that stay out of git.
- `scripts/ai_harness.sh` is the dev loop driver: load config/env, push `cluster_bootstrap.sh`, run a stage, collect logs.
- Future: document multi-runtime support (Kubernetes + systemd/Quadlet/wasm) once manifests exist.
