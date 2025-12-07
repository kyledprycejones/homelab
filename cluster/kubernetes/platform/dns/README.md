# DNS platform
This overlay reconciles DNS automation via Flux.

- `external-dns/` installs the Cloudflare-backed HelmRelease.
- Extend this directory with additional DNS automation (e.g., aliasing internal services) by adding Kustomizations below.
