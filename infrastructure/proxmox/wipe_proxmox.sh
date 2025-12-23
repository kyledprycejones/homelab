#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CONTROL_VMID="${CONTROL_VMID:-101}"
WORKER_VMIDS_STR="${WORKER_VMIDS:-102 103}"
read -r -a WORKER_VMIDS <<< "${WORKER_VMIDS_STR}"
STORAGE_ID="${STORAGE_ID:-synology-nfs}"
CLOUD_IMAGE_NAME="${CLOUD_IMAGE_NAME:-jammy-server-cloudimg-amd64.img}"
CLOUD_IMAGE_DIR="${CLOUD_IMAGE_DIR:-/mnt/pve/${STORAGE_ID}/template/cloudimg}"
REMOVE_IMAGE="${REMOVE_IMAGE:-false}"
REMOVE_KUBECONFIG_DIR="${REMOVE_KUBECONFIG_DIR:-true}"

require_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }; }

destroy_vm(){
  local id="$1"
  if qm status "$id" >/dev/null 2>&1; then
    echo "Stopping VM $id..."
    qm stop "$id" --skiplock --force >/dev/null 2>&1 || true
    echo "Destroying VM $id..."
    qm destroy "$id" --purge >/dev/null 2>&1 || true
  fi
}

main(){
  require_root
  echo "== Destroying control plane (VMID ${CONTROL_VMID}) =="
  destroy_vm "$CONTROL_VMID"

  echo "== Destroying worker VMs =="
  for id in "${WORKER_VMIDS[@]}"; do
    destroy_vm "$id"
  done

  echo "== Cleaning cloud-init metadata =="
  for id in "$CONTROL_VMID" "${WORKER_VMIDS[@]}"; do
    find "/mnt/pve/${STORAGE_ID}/images/${id}" -maxdepth 1 -name "vm-${id}-cloudinit.qcow2" -print -exec rm -f {} \; 2>/dev/null || true
  done

  if [[ "${REMOVE_IMAGE}" == "true" ]]; then
    echo "== Removing cached Ubuntu cloud image =="
    rm -f "${CLOUD_IMAGE_DIR}/${CLOUD_IMAGE_NAME}" 2>/dev/null || true
  fi

  if [[ "${REMOVE_KUBECONFIG_DIR}" == "true" ]]; then
    echo "== Removing local k3s bootstrap artifacts =="
    rm -rf "${REPO_ROOT}/infrastructure/proxmox/k3s" 2>/dev/null || true
  fi

  echo "✅ Wipe complete."
}

main "$@"
