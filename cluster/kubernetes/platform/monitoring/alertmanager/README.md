# Alertmanager overlay
Alertmanager receives rules from Prometheus and routes them via the default receiver.

Add additional receivers or routing configuration here as your alerting policy evolves. Keep the HelmRelease values aligned with the Prometheus config so they stay aware of the same namespace/name combination.
