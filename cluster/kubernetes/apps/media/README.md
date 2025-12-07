# Media workloads
Each subdirectory owns a Flux-friendly overlay for a specific media service that lives in the `media` namespace (`namespace.yaml`).

Shared expectations:
- Large libraries and downloads should consume `nfs-storage` (from `platform/storage/nfs-subdir/`) so the Synology share backs media files.
- Ingress and TLS are provided by `platform/ingress/ingress-nginx/` plus the Cloudflare Tunnel configuration.
- Observability can re-use the centralized Loki/Prometheus stack under `platform/logging/` and `platform/monitoring/`.

Subdirectories:
- `jellyfin`: primary media server.
- `jellyseer`: search/metadata helper for Jellyfin.
- `radarr`/`sonarr`: movie/TV download managers.
- `prowlarr`: indexer proxy for Radarr/Sonarr.
- `qbittorrent`: torrent client with NFS-backed storage for torrents and completed downloads.
- `bazarr`: automatic subtitle sync tied into Radarr/Sonarr workflows.
