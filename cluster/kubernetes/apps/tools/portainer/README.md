# Portainer management UI
Portainer exposes a web UI that can touch longhorn state and inspect other namespaces when necessary.

Key requirements:
- Deploy into the `tools` namespace and rely on the `longhorn` StorageClass for any stateful webhook data.
- Protect the API by keeping the service ClusterIP-only and routing access through `ingress-nginx` + Cloudflare Tunnel.
- Annotate pods with tracing/metrics pointing at the OTel Collector for future observability.
