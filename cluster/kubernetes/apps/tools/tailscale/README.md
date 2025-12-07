# Tailscale access appliance
Expose the internal cluster through Tailscale headscale when required for secure admin access.

Implementation notes:
- Keep the deployment in the `tools` namespace and do not expose a public NodePort.
- Any config secrets (Tailscale auth keys) must stay in SOPS-encrypted manifests outside of this repo.
- Use the central logging/metrics stack for observability.
