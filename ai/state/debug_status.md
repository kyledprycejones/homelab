**Current Stage:** k3s

**Problem:** `cluster_bootstrap.sh k3s` previously failed before the nodes completed joining; logs live in `logs/stages/k3s/` or under `logs/stages/all` when the orchestrator runs the full pipeline.

**Root Cause:** Node reachability or SSH key issues block the k3s bootstrap (the stage deploys k3s server/agents via SSH and needs `curl` on each node). Run `infrastructure/proxmox/check_cluster.sh` to confirm the nodes respond before rerunning the bootstrap.

**Recovery steps:**
- Ensure the Proxmox VMs exist (`provision_vms.sh` completed) and that `config/clusters/prox-n100.yaml` lists their static IPs.
- Confirm SSH access as the `ubuntu` user with your public key (the bootstrap script injects it via cloud-init).
- Run `./infrastructure/proxmox/cluster_bootstrap.sh preflight` to validate the environment, then `./infrastructure/proxmox/cluster_bootstrap.sh k3s` to reinstall k3s.
- After a successful k3s stage, use `infrastructure/proxmox/cluster_bootstrap.sh postcheck` and `infrastructure/proxmox/check_cluster.sh` to inspect node status and Flux.

**Last log reference:** `logs/stages/k3s/k3s_<timestamp>.log` (or the latest `logs/stages/all/*.log` entry for the orchestrated bootstrap run).
