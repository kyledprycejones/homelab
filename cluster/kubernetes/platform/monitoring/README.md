# Monitoring platform
This overlay runs the canonical monitoring stack for the k3s cluster.

- `alertmanager/` manages Alertmanager to route cluster alerts.
- `prometheus/` deploys Prometheus with storage on Longhorn and additional scrape configs (including the OpenTelemetry Collector).
- `grafana/` hosts dashboards and datasources pointing at Prometheus and Loki, keeping metrics/logs consolidated.
- `otel-collector/` accepts OTLP and exports to Loki and Prometheus.
- `metrics-server/` keeps Kubernetes metrics up-to-date.
