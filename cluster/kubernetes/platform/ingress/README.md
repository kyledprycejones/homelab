# Ingress platform
`platform/ingress/` houses the ingress-nginx controller and the Cloudflare Tunnel agent.

- `ingress-nginx/` deploys the controller via Helm and marks the `nginx` ingress class as default inside the cluster.
- `cloudflared/` runs the Cloudflare Tunnel deployment/ConfigMap and should be updated whenever new hostnames need to be published.
