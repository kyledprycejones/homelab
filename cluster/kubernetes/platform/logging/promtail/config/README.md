# Promtail config assets
Place Promtail scrape/service discovery tweaks here (for example, TLS config or extra scrape jobs) so the ConfigMap can stay tidy.
The deployed ConfigMap in `promtail/configmap.yaml` already loads a baseline scrape for pods and streams them to Loki; add extra files here and reference them in the ConfigMap when you need to split configuration out.
