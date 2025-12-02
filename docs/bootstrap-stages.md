# Bootstrap Stages (prox-n100)

- **precheck**: Validate local tools (`yq`, optional `sshpass`), load env, print config, check SSH reachability to controller/workers. Fatal on obvious connectivity/auth failures. Does not change remote state.
- **k3s** (alias: `cluster`): Prepare hosts, wipe stale known_hosts, generate/apply Talos configs, bootstrap etcd/control plane, wait for all nodes Ready. Fatal if nodes cannot join or the Kubernetes API is unreachable.
- **infra**: Ensure kubectl/helm/jq on controller, install NFS dynamic provisioner, mark `nfs-storage` as default, validate a test PVC. Fatal if provisioning cannot bind. Skips Vault/Argo/monitoring/logging/tunnel (handled later via GitOps).
- **apps** (alias: `gitops`): Install Flux CLI on the controller, bootstrap Flux controllers, create GitRepository and Kustomization pointing at `cluster/kubernetes/` for this repo/branch (`GIT_BRANCH` is the single source of truth). Fatal if Flux install/apply fails.
- **postcheck**: Summaries for nodes/pods/Flux objects plus machine-readable markers: `POSTCHECK_NODES_OK`, `POSTCHECK_FLUX_OK`, `POSTCHECK_TUNNEL_OK`. These markers are diagnostic only. Tunnel/cloudflared is optional; its failure should not block the run.
- **all**: Runs precheck → k3s → infra → apps → postcheck sequentially.

Fatal vs warnings:
- Fatal: SSH/auth/connectivity in precheck; Talos/Kubernetes API or node join failures; NFS provisioner/PVC failures; Flux install/apply failures.
- Warnings only: Tunnel/cloudflared health, missing optional namespaces, postcheck markers being 0 (log and iterate).
