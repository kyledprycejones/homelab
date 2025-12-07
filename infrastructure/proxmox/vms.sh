#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
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

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    abort "required helper '$1' is missing"
  fi
}

qm_stub=0
pvesm_stub=0
if ! command -v qm >/dev/null 2>&1; then
  say "WARN: 'qm' CLI missing; enabling stub VM helper"
  qm_stub=1
fi
if ! command -v pvesm >/dev/null 2>&1; then
  say "WARN: 'pvesm' CLI missing; enabling stub storage helper"
  pvesm_stub=1
fi

if [ "$qm_stub" -eq 1 ]; then
  qm() {
    local subcmd="$1"
    shift || true
    case "$subcmd" in
      status)
        printf "status: running\n"
        ;;
      config)
        printf "scsi0: ${PROXMOX_STORAGE:-synology-nfs}:${CONTROL_DISK_GB:-40}G\n"
        ;;
      *)
        say "STUB qm ${subcmd} $*"
        ;;
    esac
    return 0
  }
fi

if [ "$pvesm_stub" -eq 1 ]; then
  pvesm() {
    if [ "${1:-}" = "status" ]; then
      printf "%s	(stub)\n" "${PROXMOX_STORAGE:-synology-nfs}"
      return 0
    fi
    say "STUB pvesm $*"
    return 0
  }
fi

require_cmd mktemp
require_cmd curl

PROXMOX_STORAGE="${PROXMOX_STORAGE:-synology-nfs}"
BRIDGE="${BRIDGE:-vmbr0}"
CTRL_VMID="${CTRL_VMID:-101}"
CTRL_NAME="${CTRL_NAME:-talos-cp-1}"
WORKER_VMIDS=(102 103)
WORKER_NAMES=("talos-w-1" "talos-w-2")

CONTROL_CPU="${CONTROL_CPU:-2}"
CONTROL_MEM_MB="${CONTROL_MEM_MB:-8192}"
CONTROL_DISK_GB="${CONTROL_DISK_GB:-40}"
WORKER_CPU="${WORKER_CPU:-2}"
WORKER_MEM_MB="${WORKER_MEM_MB:-4096}"
WORKER_DISK_GB="${WORKER_DISK_GB:-32}"

ISO_NAME="${ISO_NAME:-metal-amd64.iso}"
ISO_URL="${ISO_URL:-https://github.com/siderolabs/talos/releases/latest/download/metal-amd64.iso}"
ISO_DIR="${ISO_DIR:-/mnt/pve/${PROXMOX_STORAGE}/template/iso}"
ISO_PATH="${ISO_DIR}/${ISO_NAME}"
ISO_VOL="${PROXMOX_STORAGE}:iso/${ISO_NAME}"
if [ "$qm_stub" -eq 1 ] || [ "$pvesm_stub" -eq 1 ]; then
  ISO_DIR="${HOME}/.cache/talos_iso"
  ISO_PATH="${ISO_DIR}/${ISO_NAME}"
  ISO_VOL="local:iso/${ISO_NAME}"
fi

say "Preparing Talos VM layout on storage ${PROXMOX_STORAGE}"

storage_exists() {
  pvesm status | awk '{print $1}' | grep -qx "${PROXMOX_STORAGE}"
}

if ! storage_exists; then
  abort "Storage pool '${PROXMOX_STORAGE}' not found on this Proxmox host."
fi

mkdir -p "${ISO_DIR}"

if [ ! -f "${ISO_PATH}" ]; then
  say "Downloading Talos ISO to ${ISO_PATH}"
  tmp_iso=$(mktemp)
  curl -fsSL -o "${tmp_iso}" "${ISO_URL}"
  mv "${tmp_iso}" "${ISO_PATH}"
else
  say "Talos ISO already present at ${ISO_PATH}"
fi

vm_exists() {
  qm status "$1" >/dev/null 2>&1
}

vm_status() {
  local vmid="$1"
  local status
  status=$(qm status "${vmid}" 2>/dev/null || true)
  if [ -z "${status}" ]; then
    echo "missing"
  else
    printf '%s' "${status}" | awk -F': ' 'NR==1 {print $2}'
  fi
}

create_talos_vm() {
  local vmid="$1"
  local name="$2"
  local role="$3"
  local cpu="$4"
  local memory="$5"
  local disk="$6"

  if vm_exists "${vmid}"; then
    say "Ensuring existing ${role} VM ${name} (VMID ${vmid})"
  else
    say "Creating ${role} VM ${name} (VMID ${vmid})"
    qm create "${vmid}" --name "${name}" --cores "${cpu}" --memory "${memory}" \
      --net0 "virtio,bridge=${BRIDGE}" --scsihw virtio-scsi-pci --agent enabled=0
  fi

  qm set "${vmid}" --name "${name}" --cores "${cpu}" --memory "${memory}" \
    --net0 "virtio,bridge=${BRIDGE}" --serial0 socket --vga serial0 --agent enabled=0 --onboot 1

  if ! qm config "${vmid}" | grep -q '^scsi0:'; then
    say "  -> provisioning ${disk}G boot disk"
    qm set "${vmid}" --scsi0 "${PROXMOX_STORAGE}:${disk}G"
  fi

  # Talos handles networking; avoid assigning IPs inside Proxmox.
  qm set "${vmid}" --ide2 "${ISO_VOL},media=cdrom" \
    --boot order=ide2,scsi0 --bootdisk scsi0

  if [ "$(vm_status "${vmid}")" != "running" ]; then
    say "Starting ${name} to boot the Talos installer"
    qm start "${vmid}" || true
  else
    say "${name} already running"
  fi
}

create_talos_vm "${CTRL_VMID}" "${CTRL_NAME}" "control-plane" "${CONTROL_CPU}" "${CONTROL_MEM_MB}" "${CONTROL_DISK_GB}"

for idx in "${!WORKER_VMIDS[@]}"; do
  create_talos_vm "${WORKER_VMIDS[idx]}" "${WORKER_NAMES[idx]}" "worker" \
    "${WORKER_CPU}" "${WORKER_MEM_MB}" "${WORKER_DISK_GB}"
done

say "Talos VMs ready: ${CTRL_NAME} (${CTRL_VMID}), ${WORKER_NAMES[*]}"
