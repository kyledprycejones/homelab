# Jellyfin media server
Jellyfin streams the household media library. A proper manifest should:
- Live in the `media` namespace defined by `namespace.yaml`.
- Mount the Synology share via a PVC bound to `nfs-storage`, ensuring media, metadata, and config survive pod restarts.
- Reuse the `longhorn` StorageClass from `platform/storage/longhorn/` for any additional state (e.g., database files or backups) if high availability is desired.
- Announce its service through `platform/ingress/ingress-nginx/` and add a Cloudflare Tunnel route when it is ready for remote browsing.
- Have Prometheus and Loki annotations so Grafana dashboards can pick up server and streaming metrics.
