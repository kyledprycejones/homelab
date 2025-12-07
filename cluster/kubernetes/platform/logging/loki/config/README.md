# Loki custom config
Drop supplemental Loki ConfigMaps or overrides here when you need per-environment tweaks.
Currently the HelmRelease in this directory uses `values-longhorn.yaml` for persistence and schema settings, but you can add files such as `loki-ingress.yaml` or custom scrape configs here and reference them via `kustomization` as needed.
