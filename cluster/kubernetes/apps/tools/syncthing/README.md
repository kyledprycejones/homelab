# Syncthing peer sync
Syncthing syncs personal files between homelab devices.

Once you add manifests:
- Run it from the `tools` namespace with PVCs backed by `nfs-storage` so shared folders land on Synology.
- Keep the service private and expose only via the Cloudflare Tunnel to avoid public NodePorts.
- Leverage Grafana/Loki for logs in case bonding needs diagnostics.
