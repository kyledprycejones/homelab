# Grafana overlay
Grafana is deployed via Helm in this directory and uses the Longhorn StorageClass for persistence.

Datasources are declared inline (Prometheus + Loki) and dashboards land under `dashboards/`. Use the sidecar to keep dashboards in sync with Flux.
