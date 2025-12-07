# Minecraft server overlay
This directory owns the Flux-managed Minecraft deployment, service, PVC, and namespace.

Current layout:
- `deployment.yaml` references the `minecraft` image and should mount a Longhorn-backed PVC (`pvc.yaml`) for the world data.
- `service.yaml` exposes the standard TCP port internally; keep it ClusterIP and extend access via ingress or Cloudflare Tunnel if needed.
- `namespace.yaml` ensures the `games` namespace exists for this workload.

Feel free to add Grafana dashboards, Prometheus scraping annotations, or extra ConfigMaps here as the server evolves.
