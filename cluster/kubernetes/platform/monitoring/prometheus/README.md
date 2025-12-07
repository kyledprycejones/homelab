# Prometheus Helm overlay
The HelmRelease in this directory deploys Prometheus with the following customizations:
- Persistent storage on Longhorn and an additional scrape job for the OpenTelemetry Collector.
- A reference to Alertmanager (`monitoring-alertmanager`) so alerts are routed internally.
- Additional resource requests to keep the control-plane metrics collector stable.

Add rules into `rules/` (see `node-readiness.yaml`) and reference them via `kustomization.yaml` as needed.
