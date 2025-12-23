#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROBE_NAME="k3s"
KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/infrastructure/proxmox/k3s/kubeconfig}"

log_summary() {
  printf '[probe] %s: %s\n' "$PROBE_NAME" "$1"
}

evidence_line() {
  printf 'evidence: %s\n' "$1"
}

if ! command -v kubectl >/dev/null 2>&1; then
  log_summary "FAIL"
  printf 'reason: kubectl CLI unavailable\n'
  evidence_line "command not found"
  printf 'next: install kubectl or run cluster_bootstrap.sh k3s to bootstrap the toolchain\n'
  exit 2
fi

if [ ! -f "$KUBECONFIG_PATH" ]; then
  log_summary "FAIL"
  printf 'reason: kubeconfig missing at %s\n' "$KUBECONFIG_PATH"
  evidence_line "kubeconfig missing"
  printf 'next: run infrastructure/proxmox/cluster_bootstrap.sh k3s first\n'
  exit 2
fi

set +e
output=$(KUBECONFIG="$KUBECONFIG_PATH" kubectl get nodes -o wide 2>&1)
status=$?
set -e

if [ "$status" -ne 0 ]; then
  log_summary "FAIL"
  printf 'reason: kubectl get nodes failed (rc=%s)\n' "$status"
  evidence_line "$output"
  printf 'next: verify SSH connectivity and rerun infrastructure/proxmox/cluster_bootstrap.sh k3s\n'
  exit "$status"
fi

log_summary "PASS"
printf 'reason: k3s control plane reachable via kubeconfig\n'
if [ -n "$output" ]; then
  evidence_line "$output"
fi
