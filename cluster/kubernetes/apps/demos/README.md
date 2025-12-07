# Demo workloads
This namespace hosts lightweight demos used for testing Flux, ingress, or networking changes.

Each folder in `cluster/kubernetes/apps/demos/` should:
- Declare its own manifests within the `demos` namespace defined by `namespace.yaml`.
- Avoid exposing traffic outside the cluster unless it flows through the shared ingress stack.
- Be instrumented with Loki logs and Prometheus metrics so the observability stack exercises the full path.
