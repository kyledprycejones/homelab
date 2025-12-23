#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG_ENV="${CONFIG_ENV:-${REPO_ROOT}/config/env/prox-n100.env}"
if [ -f "${CONFIG_ENV}" ]; then
  # shellcheck disable=SC1090
  source "${CONFIG_ENV}"
fi

say() {
  echo -e "\n== $* =="
}

abort() {
  echo "ERROR: $*" >&2
  exit 1
}

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${REPO_ROOT}/infrastructure/proxmox/k3s/kubeconfig}"
if [ ! -f "${KUBECONFIG_PATH}" ]; then
  abort "kubeconfig missing at ${KUBECONFIG_PATH}; run infrastructure/proxmox/cluster_bootstrap.sh k3s first"
fi

if ! command -v kubectl >/dev/null 2>&1; then
  abort "kubectl is required for cluster checks" 
fi

say "Using kubeconfig ${KUBECONFIG_PATH}"
KUBECONFIG="${KUBECONFIG_PATH}" kubectl get nodes -o wide
KUBECONFIG="${KUBECONFIG_PATH}" kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
KUBECONFIG="${KUBECONFIG_PATH}" kubectl -n kube-system get pods -l k8s-app=coredns -o wide
KUBECONFIG="${KUBECONFIG_PATH}" kubectl -n kube-system get pods -o wide | head -n 20

if command -v flux >/dev/null 2>&1; then
  say "Flux status"
  KUBECONFIG="${KUBECONFIG_PATH}" flux get kustomizations -A || true
else
  say "Flux CLI missing; showing kustomizations via kubectl"
  KUBECONFIG="${KUBECONFIG_PATH}" kubectl get kustomization.kustomize.toolkit.fluxcd.io -A || true
fi

say "Cluster check complete"
