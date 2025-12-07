# VS Code Server IDE
VS Code Server brings a browser-based IDE into the homelab.

Best practices:
- Launch inside the `tools` namespace and route storage to `longhorn` for workspace state.
- Keep the service behind `ingress-nginx` so access profiles are enforceable through Cloudflare Tunnel.
- Annotate the deployment so Promtail and the OTel Collector can pick up logs and traces.
