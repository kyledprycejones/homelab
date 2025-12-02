# Proxmox Bootstrap

Helper scripts for provisioning Talos-ready VMs on the N100 host.

## Contents
- `cluster_bootstrap.sh` – runs Talos gen/apply, bootstraps etcd, installs Flux, and wires GitOps.
- `proxmox_bootstrap_nocluster.sh` – host prep/VM creation helper.
- `wipe_proxmox.sh` – dangerous wipe helper (documented only).
- `vm-spec.md` – expected VM shape for controller/workers.
- `network-layout.md` – IP plan and VLAN/bridge notes.

Scripts read values from `config/env/<cluster>.env` (when present) and from `config/clusters/<cluster>.yaml`. Keep secrets out of git; Talos configs live under `.talos/` locally.
