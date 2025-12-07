# Logging platform
This overlay deploys Grafana Loki + Promtail.

- `loki/` (HelmRelease) stores logs in Longhorn-backed volumes and exposes the API to Promtail.
- `promtail/` (DaemonSet + RBAC) tailers the host logs and ships them to Loki via the cluster DNS.

Any additional logging components should land inside this directory so Flux keeps the stack in sync.
