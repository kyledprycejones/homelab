# Radarr movie manager
Radarr orchestrates movie downloads and tags metadata consumed by Jellyfin.

Implementation notes:
- Keep the deployment/HelmRelease in the `media` namespace and point Radarr to `qbittorrent`/`prowlarr` services inside the cluster.
- Store metadata and config on the Synology-backed `nfs-storage` PVC so it survives redeployments.
- Connect to Grafana via provided datasources and label logs for Loki.
- When ready, expose the UI via `ingress-nginx` + Cloudflare Tunnel.
