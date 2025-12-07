# Sonarr TV manager
Sonarr controls TV series downloads and works in tandem with Radarr.

When you expand this folder:
- Target the `media` namespace and consume `nfs-storage` for completed episodes and metadata.
- Wire Sonarr into the same indexer stack (Prowlarr) and torrent client (qBittorrent) residing in the cluster.
- Plan for ingress exposure via `ingress-nginx` once the UI should be reachable.
