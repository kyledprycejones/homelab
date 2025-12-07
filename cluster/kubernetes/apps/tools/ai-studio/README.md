# AI Studio placeholder
AI Studio is a future Stage 2 workspace that will share tooling with Stage 1 but is currently dormant.

When the feature becomes active:
- It should live under the `tools` namespace so GitOps handles it alongside the rest of the management apps.
- Storage should use Longhorn volumes for IDE/stateful caches and optionally NFS for shared project data.
- All ingress traffic must flow through `ingress-nginx` and Cloudflare Tunnel routes, keeping private services off NodePorts.
- Observability pipelines (Loki/OTel) should ingest traces and logs as this folder is populated.
