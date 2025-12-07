#!/usr/bin/env bash
set -euo pipefail

# ========= EDIT IF NEEDED =========
NFS_STORAGE_ID="synology-nfs"
ISO_FILE="talos-amd64.iso"   # only removed if REMOVE_ISO=true (used by infrastructure/proxmox/vms.sh)
TEMPLATE_VMID=9000
CLONE_BASE_VMID=101
CLONE_COUNT=3
CLOUD_IMG_LOCAL="/root/noble-server-cloudimg-amd64.img"

# Danger toggles (set true/false)
REMOVE_ISO="false"           # also delete ISO from /mnt/pve/<storage>/template/iso/
REMOVE_SNIPPETS="true"       # remove legacy GitOps user-data snippet(s)
REMOVE_LOCAL_CLOUD_IMG="false" # delete local /root/...cloudimg-amd64.img

# ========= DO NOT EDIT BELOW =========
require_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }; }

destroy_vm(){
  local id="$1"
  if qm status "$id" >/dev/null 2>&1; then
    echo "Stopping VM $id..."
    qm stop "$id" --skiplock || true
    echo "Destroying VM $id..."
    qm destroy "$id" --purge || true
  fi
}

main(){
  require_root
  echo "== Wiping clones =="
  for i in $(seq 1 "$CLONE_COUNT"); do
    destroy_vm $((CLONE_BASE_VMID+i-1))
  done

  echo "== Wiping template ${TEMPLATE_VMID} =="
  destroy_vm "$TEMPLATE_VMID"

  # Remove per-VM cloud-init disks if any linger (rare)
  for id in $(seq "$CLONE_BASE_VMID" $((CLONE_BASE_VMID+CLONE_COUNT-1))); do
    find "/mnt/pve/${NFS_STORAGE_ID}/images/${id}/" -maxdepth 1 -name "vm-${id}-cloudinit.qcow2" -print -exec rm -f {} \; 2>/dev/null || true
  done
  find "/mnt/pve/${NFS_STORAGE_ID}/images/${TEMPLATE_VMID}/" -maxdepth 1 -name "vm-${TEMPLATE_VMID}-cloudinit.qcow2" -print -exec rm -f {} \; 2>/dev/null || true

  if [[ "${REMOVE_SNIPPETS}" == "true" ]]; then
    echo "== Removing legacy GitOps snippets =="
    rm -f "/mnt/pve/${NFS_STORAGE_ID}/snippets/"*gitops-userdata.yaml 2>/dev/null || true
    rm -f "/mnt/pve/${NFS_STORAGE_ID}/snippets/legacy-gitops.yaml" 2>/dev/null || true
    # remove any per-VM hostname/userdata snippets you might have added:
    rm -f /mnt/pve/${NFS_STORAGE_ID}/snippets/ci-chatgpt-build*.yaml 2>/dev/null || true
  fi

  if [[ "${REMOVE_ISO}" == "true" ]]; then
    echo "== Removing ISO =="
    rm -f "/mnt/pve/${NFS_STORAGE_ID}/template/iso/${ISO_FILE}" 2>/dev/null || true
  fi

  if [[ "${REMOVE_LOCAL_CLOUD_IMG}" == "true" ]]; then
    echo "== Removing local cloud image =="
    rm -f "${CLOUD_IMG_LOCAL}" 2>/dev/null || true
  fi

  echo "✅ Wipe complete."
}

main "$@"
