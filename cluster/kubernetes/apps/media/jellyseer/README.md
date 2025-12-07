# Jellyseer metadata helper
Jellyseer keeps Jellyfin metadata, collections, and search helpers tidy.

Future implementations should:
- Declare a Flux-ready overlay or HelmRelease under this directory and attach it to `media` namespace.
- Store any cache/state on either `nfs-storage` or the `longhorn` StorageClass plus backup the metadata blob to Synology if needed.
- Use internal DNS (e.g., `jellyfin.media.svc.cluster.local`) to integrate with the rest of the media stack.
