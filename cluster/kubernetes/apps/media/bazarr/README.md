# Bazarr media helper
Bazarr keeps subtitles in sync for the movie and TV pipelines.

When you wire up this folder, publish a kustomization or HelmRelease that lives in the `media` namespace and consumes the `nfs-storage` StorageClass so subtitle caches land on Synology.

Recommended integrations:
- talk to the Radarr/Sonarr APIs via the internal DNS names `radarr.media.svc.cluster.local` and `sonarr.media.svc.cluster.local`.
- expose HTTP through `ingress-nginx` with Cloudflare Tunnel entries added to `platform/ingress/cloudflared/config.yaml`.
- add Grafana/Loki dashboards under `platform/monitoring/grafana/dashboards/` and `platform/logging/loki/` as you need insights.
