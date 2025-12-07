#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_ENV="${CONFIG_ENV:-${REPO_ROOT}/config/env/prox-n100.env}"

if [ -f "${CONFIG_ENV}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${CONFIG_ENV}"
  set +a
fi

CTRL_IP="${CTRL_IP:-192.168.1.151}"
TALOS_CLUSTER_NAME="${TALOS_CLUSTER_NAME:-prox-n100}"
TALOS_CONFIG_DIR="${TALOS_CONFIG_DIR:-${REPO_ROOT}/.talos/${TALOS_CLUSTER_NAME}}"
TALOSCONFIG="${TALOSCONFIG:-${TALOS_CONFIG_DIR}/talosconfig}"
TALOS_KUBECONFIG="${TALOS_KUBECONFIG:-${TALOS_CONFIG_DIR}/kubeconfig}"

set +e
if command -v talosctl >/dev/null 2>&1 && [ -f "${TALOSCONFIG}" ]; then
  echo "talosctl get nodes"
  talosctl --talosconfig "${TALOSCONFIG}" --endpoints "${CTRL_IP:-}" get nodes || true
else
  echo "talosctl not available or talosconfig missing; skipping Talos check"
fi

echo "kubectl get nodes"
KUBECONFIG="${TALOS_KUBECONFIG}" kubectl get nodes -o wide || true

echo "flux get kustomizations"
if command -v flux >/dev/null 2>&1; then
  KUBECONFIG="${TALOS_KUBECONFIG}" flux get kustomizations -A || true
else
  KUBECONFIG="${TALOS_KUBECONFIG}" kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A || true
fi
set -e

# PLANNER S1-003-EXECUTOR-ENGINEER-FIX Fix failure in S1-003-EXECUTOR-CHECK
# Detail: Executor failed with error_class=ERR_UNKNOWN. Engineer must produce minimal diffs only.
# applied at 2025-12-04T02:11:10Z
