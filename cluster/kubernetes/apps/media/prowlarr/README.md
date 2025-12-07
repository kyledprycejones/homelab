# Prowlarr indexer proxy
Prowlarr aggregates indexers for Radarr, Sonarr, and other download managers.

Make sure any future manifest:
- Runs in the `media` namespace so it can talk to `radarr`/`sonarr` via the cluster DNS.
- Persists config (indexer credentials) on the Synology-backed `nfs-storage` StorageClass.
- Exposes a service that can be published through `ingress-nginx` and the Cloudflare Tunnel.
- Is observed through the Loki/Prometheus stack for troubleshooting.
