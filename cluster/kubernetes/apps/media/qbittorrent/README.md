# qBittorrent client
qBittorrent handles the actual torrent downloads for the media pipelines.

Guidance for this directory:
- Use the `media` namespace and prefer `nfs-storage` for both downloads and configuration so the Synology NAS holds the torrent data.
- Map a PVC for the completed downloads folder, and attach annotations so Promtail can label the logs by namespace/pod.
- Plan an ingress route via `ingress-nginx` once the UI is ready for remote access.
