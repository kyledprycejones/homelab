# Game workloads
This folder collects playful workloads that extend the homelab beyond utilities.

Currently `minecraft/` contains the active deployment; add more directories as you expand the fun stack.

Keep these principles in mind:
- Each game namespace should be declared in `cluster/kubernetes/apps/namespace.yaml` (if needed) and kept inside the `games` namespace defined in this tree.
- Use `longhorn` volumes for world data and optionally mirror backups to the Synology NFS share.
- Publish ingress routes via `ingress-nginx` and Cloudflare Tunnel when the service needs to be exposed.
