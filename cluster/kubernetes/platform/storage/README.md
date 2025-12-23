# Storage platform
This overlay splits storage concerns into two HelmReleases:

- `longhorn/` (block storage with replication and Kubernetes CSI) for resilient PVCs and supporting PersistentVolumes.
- `nfs-subdir/` (Synology-backed provisioner) for large media/content pools that need RWX access.

Flux runs this overlay to ensure the StorageClasses and provisioners stay aligned with the Synology-backed k3s topology.
