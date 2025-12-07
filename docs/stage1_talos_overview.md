# Stage 1 Talos overview

## 1. Networking is defined by Talos, not Proxmox

- Provision VMs with a virtio NIC attached to `vmbr0` but **do not** inject IP information from Proxmox (`--ipconfig0` is gone). Talos picks up IPv4 via DHCP by default and that is the only supported networking configuration unless you embed static IPs inside `cluster/talos/*.yaml`.
- Keep `infrastructure/proxmox/vms.sh` (and the helper stub in `cli_loop.sh`) focused on CPU/memory/disk/ISO/boot order. The control-plane and worker VMs now boot with DHCP-only networking and the downstream Talos manifests or the router/DHCP lease determine their IPs.
- If you still need static addresses, bake them into `cluster/talos/controlplane.yaml`/`.../worker.yaml` under `machine.network.interfaces.addresses`. Do **not** try to assign them via Proxmox arguments.

## 2. Node discovery and Talos configuration

- Talos configs live under `${REPO_ROOT}/.talos/<cluster>`. The bootstrap script now exports `TALOSCONFIG="${TALOS_CONFIG_DIR}/talosconfig"` so every `talosctl` command on your Mac resolves to that concrete client certificate bundle.
- After VM creation, drop the DHCP-assigned node IPs into `${TALOS_CONFIG_DIR}/nodes.txt`. The file format is one IP per line, with the first line reserved for the control-plane and following lines for workers. Comments (`#`) and blank lines are ignored. Example:

  ```
  # control plane
  192.168.1.151
  # workers
  192.168.1.152
  192.168.1.153
  ```

- The bootstrap will load `${NODE_IP_FILE}` before it talks to any node. If you prefer a different location, set `NODE_IP_FILE` in your environment.
- `cluster/talos/talconfig.yaml` documents the expected node names and shows `<CONTROL_PLANE_IP>`/`<WORKER_*>` placeholders; keep that file in sync with the VM names created by `infrastructure/proxmox/vms.sh`.

## 3. talosctl workflow on the Mac

1. Ensure `talosctl` exists under your user (`/Users/kyle/.local/bin`) and that `$(talosctl version --short)` matches the Talos ISO you booted. The bootstrap script installs it if missing.
2. Generate configs locally with `talosctl gen config prox-n100 https://<CONTROL_PLANE_IP>:6443 --output-dir "${REPO_ROOT}/.talos/prox-n100" --force --install-disk /dev/sda --with-secrets`.
3. Export `TALOSCONFIG="${REPO_ROOT}/.talos/prox-n100/talosconfig"` before running other `talosctl` commands, or rely on the bootstrap to do so automatically.
4. Use `talosctl --nodes "<node-ip>" --insecure dmesg` and `... service status` (also `talosctl health`) to wait for the Talos API to report healthy kernels. The script now loops with those checks instead of assuming static addresses.
5. Apply the generated `controlplane.yaml`/`worker.yaml` configs with `talosctl apply-config --insecure --nodes <ip> --file ...` and bootstrap etcd with `talosctl bootstrap --nodes <cp> --endpoints <endpoint>`.
6. Fetch the kubeconfig with `talosctl kubeconfig --nodes <cp> --endpoints <endpoint> "${REPO_ROOT}/.talos/prox-n100/kubeconfig"`. The script already retries these steps.

## 4. Canonical stage order

1. Provision VMs (`infrastructure/proxmox/vms.sh` or the helper stub in `cli_loop.sh`). They are now agnostic of IPs.
2. Wait for the Talos kernel and API to come online via DHCP. Talos health is checked with `talosctl --nodes <node> --insecure version`, `dmesg`, and `service status` calls.
3. Push generated configs with `talosctl apply-config --insecure ...`.
4. Bootstrap etcd with `talosctl bootstrap ...`.
5. Fetch the kubeconfig and proceed with Flux/GitOps in later stages.

If any Talos API endpoint is unreachable, compare the DHCP leases on the router/Proxmox console, refresh `${NODE_IP_FILE}`, and rerun `bash infrastructure/proxmox/cluster_bootstrap.sh talos`.
