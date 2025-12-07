# Security platform
Reserve this directory for policy, AdmissionControl, or tooling manifests that harden the cluster.

Until additional security automation is introduced, keep this folder structured so Flux can reconcile namespace-scoped policies (PodSecurityPolicy, Kyverno, etc.) without major refactors.
