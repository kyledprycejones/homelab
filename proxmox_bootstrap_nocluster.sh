#!/usr/bin/env bash
set -euo pipefail

### ====== CONFIG ======
NFS_STORAGE="synology-nfs"
NFS_MOUNT="/mnt/pve/${NFS_STORAGE}"

ISO_DIR="${NFS_MOUNT}/template/iso"
ISO_NAME="ubuntu-24.04.3-live-server-amd64.iso"
ISO_URL="https://releases.ubuntu.com/noble/${ISO_NAME}"

CLOUD_IMG_LOCAL="/root/noble-server-cloudimg-amd64.img"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

TEMPLATE_VMID=9000
TEMPLATE_NAME="chatgpt-build"
BRIDGE="vmbr0"
DISK_SIZE_GB=20

CI_USER="kyle"
CI_PASS="root"

SNIPPET_NAME="allow-pwd.yaml"
SNIPPET_PATH="${NFS_MOUNT}/snippets/${SNIPPET_NAME}"
SNIPPET_VOL="${NFS_STORAGE}:snippets/${SNIPPET_NAME}"

declare -A VMS=(
  [101]="${TEMPLATE_NAME}1"
  [102]="${TEMPLATE_NAME}2"
  [103]="${TEMPLATE_NAME}3"
)
IP_101="192.168.1.151/24"
IP_102="192.168.1.152/24"
IP_103="192.168.1.153/24"
GW="192.168.1.1"

### ====== HELPERS ======
say(){ echo -e "\n== $* =="; }
have_storage(){ pvesm status | awk '{print $1}' | grep -qx "$1"; }
vm_exists(){ qm status "$1" >/dev/null 2>&1; }

attach_imported_disk() {
  local vmid="$1"
  local VOLID
  VOLID="$(qm config "${vmid}" | awk -F'[, ]+' '/^unused[0-9]+: /{print $2; exit}')"
  if [ -z "${VOLID:-}" ]; then
    echo "ERROR: Could not find imported disk (unusedN) on VM ${vmid}"
    exit 1
  fi
  qm set "${vmid}" --scsihw virtio-scsi-pci --scsi0 "${VOLID}"
}

### ====== Ensure storage & snippet ======
say "Ensuring NFS storage '${NFS_STORAGE}' exists and supports snippets"
if ! have_storage "${NFS_STORAGE}"; then
  echo "ERROR: Storage ${NFS_STORAGE} not found. Add it first in Datacenter -> Storage."
  exit 1
fi
pvesm set "${NFS_STORAGE}" --content images,iso,backup,vztmpl,rootdir,snippets >/dev/null
mkdir -p "${NFS_MOUNT}/snippets" "${ISO_DIR}"

if [ ! -f "${SNIPPET_PATH}" ]; then
  say "Creating cloud-init snippet ${SNIPPET_PATH}"
  cat > "${SNIPPET_PATH}" <<EOF
#cloud-config
users:
  - name: ${CI_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
ssh_pwauth: true
chpasswd:
  expire: false
  list: |
    ${CI_USER}:${CI_PASS}
EOF
  chmod 644 "${SNIPPET_PATH}"
else
  say "Snippet already present at ${SNIPPET_PATH}"
fi

### ====== ISO & cloud image ======
if [ ! -f "${ISO_DIR}/${ISO_NAME}" ]; then
  say "Downloading ISO to ${ISO_DIR}/${ISO_NAME}"
  curl -fsSL -o "${ISO_DIR}/${ISO_NAME}" "${ISO_URL}"
else
  say "ISO already present at ${ISO_DIR}/${ISO_NAME}"
fi
say "ISO available via Proxmox storage '${NFS_STORAGE}'."

if [ ! -f "${CLOUD_IMG_LOCAL}" ]; then
  say "Downloading Ubuntu cloud image: $(basename "${CLOUD_IMG_LOCAL}")"
  curl -fsSL -o "${CLOUD_IMG_LOCAL}" "${CLOUD_IMG_URL}"
else
  say "Cloud image already present at ${CLOUD_IMG_LOCAL}"
fi

### ====== Template create/update ======
if ! vm_exists "${TEMPLATE_VMID}"; then
  say "Creating VM ${TEMPLATE_VMID} (${TEMPLATE_NAME}) from cloud image..."
  qm create "${TEMPLATE_VMID}" --name "${TEMPLATE_NAME}" --memory 2048 --cores 2 --net0 "virtio,bridge=${BRIDGE}" --ostype l26 --agent enabled=1

  say "Importing cloud image as scsi0"
  qm importdisk "${TEMPLATE_VMID}" "${CLOUD_IMG_LOCAL}" "${NFS_STORAGE}" >/dev/null
  attach_imported_disk "${TEMPLATE_VMID}"

  qm set "${TEMPLATE_VMID}" --ide2 "${NFS_STORAGE}:cloudinit,media=cdrom"
  qm set "${TEMPLATE_VMID}" --boot order=scsi0 --bootdisk scsi0
  qm set "${TEMPLATE_VMID}" --serial0 socket --vga std

  qm set "${TEMPLATE_VMID}" --ciuser "${CI_USER}" --cipassword "${CI_PASS}"
  qm set "${TEMPLATE_VMID}" -cicustom "user=${SNIPPET_VOL}"

  qm resize "${TEMPLATE_VMID}" scsi0 "+$((DISK_SIZE_GB - 3))G" || true

  qm template "${TEMPLATE_VMID}"
  say "Template ${TEMPLATE_VMID} ready."
else
  say "Template VMID ${TEMPLATE_VMID} exists; enforcing config."
  qm set "${TEMPLATE_VMID}" --name "${TEMPLATE_NAME}" --memory 2048 --cores 2 --net0 "virtio,bridge=${BRIDGE}" --ostype l26 --agent enabled=1
  if ! qm config "${TEMPLATE_VMID}" | grep -q "^scsi0:"; then
    say "scsi0 missing—importing OS disk from ${CLOUD_IMG_LOCAL}..."
    qm importdisk "${TEMPLATE_VMID}" "${CLOUD_IMG_LOCAL}" "${NFS_STORAGE}" >/dev/null
    attach_imported_disk "${TEMPLATE_VMID}"
  fi
  qm set "${TEMPLATE_VMID}" --ide2 "${NFS_STORAGE}:cloudinit,media=cdrom"
  qm set "${TEMPLATE_VMID}" --boot order=scsi0 --bootdisk scsi0
  qm set "${TEMPLATE_VMID}" --serial0 socket --vga std
  qm set "${TEMPLATE_VMID}" --ciuser "${CI_USER}" --cipassword "${CI_PASS}"
  qm set "${TEMPLATE_VMID}" -cicustom "user=${SNIPPET_VOL}"
  if ! qm config "${TEMPLATE_VMID}" | grep -q "^template:"; then
    qm template "${TEMPLATE_VMID}"
  fi
fi

### ====== Recreate clones ======
say "Recreating 3 clone(s) from template ${TEMPLATE_VMID}..."

recreate_vm () {
  local id="$1" name="$2" ip="$3"
  if vm_exists "${id}"; then
    say "Destroying existing VM ${id} (${name})"
    qm stop "${id}" >/dev/null 2>&1 || true
    qm destroy "${id}" --purge || true
  fi

  say "Cloning ${name} (VMID ${id})..."
  qm clone "${TEMPLATE_VMID}" "${id}" --name "${name}" --full true
  qm set "${id}" --net0 "virtio,bridge=${BRIDGE}"
  qm set "${id}" --ipconfig0 "ip=${ip},gw=${GW}"
  qm set "${id}" --ciuser "${CI_USER}" --cipassword "${CI_PASS}"
  qm set "${id}" -cicustom "user=${SNIPPET_VOL}"
  qm set "${id}" --boot order=scsi0 --bootdisk scsi0
  qm set "${id}" --serial0 socket --vga std

  qm cloudinit update "${id}"
  qm start "${id}"
  say "VM ${id} (${name}) created and started."
}

recreate_vm 101 "${VMS[101]}" "${IP_101}"
recreate_vm 102 "${VMS[102]}" "${IP_102}"
recreate_vm 103 "${VMS[103]}" "${IP_103}"

say "All done ✅
- Storage: ${NFS_STORAGE}
- ISO: ${ISO_NAME} present on Synology
- Snippet: ${SNIPPET_VOL}
- Template: ${TEMPLATE_NAME} (VMID ${TEMPLATE_VMID})
- Clones: 101 102 103 on ${BRIDGE}
- Static IPs: ${IP_101} ${IP_102} ${IP_103}
- Login: ${CI_USER}/${CI_PASS}"