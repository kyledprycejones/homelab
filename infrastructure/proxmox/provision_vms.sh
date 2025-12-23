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

QM_STUB=0
PVESM_STUB=0
if ! command -v qm >/dev/null 2>&1; then
  say "WARN: 'qm' CLI missing; entering dry-run mode"
  QM_STUB=1
fi
if ! command -v pvesm >/dev/null 2>&1; then
  say "WARN: 'pvesm' CLI missing; entering dry-run mode"
  PVESM_STUB=1
fi

if [ "$QM_STUB" -eq 1 ]; then
  qm() {
    local subcmd="$1"
    shift || true
    echo "[qm stub] $subcmd $*"
  }
fi

if [ "$PVESM_STUB" -eq 1 ]; then
  pvesm() {
    local subcmd="$1"
    shift || true
    echo "[pvesm stub] $subcmd $*"
  }
fi

require_cmd mktemp
require_cmd curl
require_cmd python3

yaml_nested_value() {
  local block="$1"
  local key="$2"
  local file="$3"
  python3 - "$block" "$key" "$file" <<'PY'
import re
import sys
block = sys.argv[1]
key = sys.argv[2]
path = sys.argv[3]
block_pat = re.compile(r'^(?P<indent>[ \t]*)' + re.escape(block) + r'\s*:\s*$')
key_pat = re.compile(r'^[ \t]*' + re.escape(key) + r'[ \t]*:[ \t]*(.*)$')
inside = False
indent = 0
try:
    with open(path) as fh:
        for line in fh:
            stripped = line.rstrip('\n')
            if not inside:
                match = block_pat.match(stripped)
                if match:
                    inside = True
                    indent = len(match.group('indent'))
                continue
            if not stripped.strip():
                continue
            current_indent = len(re.match(r'[ \t]*', stripped).group(0))
            if current_indent <= indent:
                break
            match = key_pat.match(stripped)
            if match:
                print(match.group(1).strip())
                sys.exit(0)
except FileNotFoundError:
    pass
PY
}

yaml_list_values() {
  local block="$1"
  local file="$2"
  python3 - "$block" "$file" <<'PY'
import re
import sys
block = sys.argv[1]
path = sys.argv[2]
block_pat = re.compile(r'^(?P<indent>[ \t]*)' + re.escape(block) + r'\s*:\s*$')
item_pat = re.compile(r'^[ \t]*-[ \t]*(.*)$')
inside = False
indent = 0
try:
    with open(path) as fh:
        for line in fh:
            stripped = line.rstrip('\n')
            if not inside:
                match = block_pat.match(stripped)
                if match:
                    inside = True
                    indent = len(match.group('indent'))
                continue
            if not stripped.strip():
                continue
            current_indent = len(re.match(r'[ \t]*', stripped).group(0))
            if current_indent <= indent:
                break
            match = item_pat.match(stripped)
            if match:
                print(match.group(1).strip())
except FileNotFoundError:
    pass
PY
}

CLUSTER_CONFIG_FILE="${CLUSTER_CONFIG_FILE:-${REPO_ROOT}/config/clusters/prox-n100.yaml}"
CTRL_IP="${CTRL_IP:-}"
if [ -n "${CTRL_IP}" ]; then
  say "Using CTRL_IP override from environment: ${CTRL_IP}"
else
  CTRL_IP="$(yaml_nested_value controller ip "${CLUSTER_CONFIG_FILE}" || true)"
fi
if [ -z "${CTRL_IP}" ]; then
  abort "Control plane IP not configured; set CTRL_IP or add controller.ip to ${CLUSTER_CONFIG_FILE}"
fi

WORKER_IPS=()
if [ -n "${WORKER_IPS_OVERRIDE:-}" ]; then
  say "Using WORKER_IPS_OVERRIDE"
  IFS=', ' read -r -a manual_ips <<< "${WORKER_IPS_OVERRIDE}"
  for entry in "${manual_ips[@]}"; do
    entry="${entry//[$'\t']/}"
    entry="${entry//,/}"
    [ -n "${entry}" ] && WORKER_IPS+=("${entry}")
  done
else
  mapfile -t WORKER_IPS < <(yaml_list_values workers "${CLUSTER_CONFIG_FILE}")
fi

if [ "${#WORKER_IPS[@]}" -eq 0 ]; then
  abort "Worker IPs missing; add a 'workers' list to ${CLUSTER_CONFIG_FILE} or set WORKER_IPS_OVERRIDE"
fi

PROXMOX_STORAGE="${PROXMOX_STORAGE:-}"
BRIDGE="${BRIDGE:-vmbr0}"
PROXMOX_STORAGE_DEFAULT="synology-nfs"

detect_storage_with_images() {
  if [ -n "${PROXMOX_STORAGE}" ]; then
    return
  fi
  local cfg="/etc/pve/storage.cfg"
  if [ -r "$cfg" ]; then
    local name content
    while IFS= read -r line; do
      if [[ "$line" =~ ^storage[[:space:]]+([^[:space:]]+) ]]; then
        name="${BASH_REMATCH[1]}"
        continue
      fi
      if [[ "$line" =~ ^[[:space:]]*content[[:space:]]+(.+) ]]; then
        content="${BASH_REMATCH[1]}"
        if [[ "$content" =~ images ]]; then
          PROXMOX_STORAGE="$name"
          return
        fi
      fi
    done < "$cfg"
  fi
}
detect_storage_with_images
PROXMOX_STORAGE="${PROXMOX_STORAGE:-${PROXMOX_STORAGE_DEFAULT}}"

storage_exists() {
  if [ "$PVESM_STUB" -eq 1 ]; then
    return 0
  fi
  pvesm status | awk '{print $1}' | grep -qx "${PROXMOX_STORAGE}"
}

if ! storage_exists; then
  abort "Storage pool ${PROXMOX_STORAGE} not found on this host"
fi

UBUNTU_IMAGE_NAME="${UBUNTU_IMAGE_NAME:-jammy-server-cloudimg-amd64.img}"
UBUNTU_IMAGE_URL="${UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/jammy/current/${UBUNTU_IMAGE_NAME}}"
CLOUD_IMAGE_DIR="${CLOUD_IMAGE_DIR:-/mnt/pve/${PROXMOX_STORAGE}/template/cloudimg}"
CLOUD_IMAGE_PATH="${CLOUD_IMAGE_DIR}/${UBUNTU_IMAGE_NAME}"
if [ "$QM_STUB" -eq 1 ] || [ "$PVESM_STUB" -eq 1 ]; then
  CLOUD_IMAGE_DIR="${HOME}/.cache/homelab_ubuntu"
  CLOUD_IMAGE_PATH="${CLOUD_IMAGE_DIR}/${UBUNTU_IMAGE_NAME}"
fi

NETWORK_GATEWAY="${NETWORK_GATEWAY:-192.168.1.1}"
NETWORK_PREFIX_LEN="${NETWORK_PREFIX_LEN:-24}"
NETWORK_DNS="${NETWORK_DNS:-1.1.1.1}"

CTRL_VMID="${CTRL_VMID:-101}"
CTRL_NAME="${CTRL_NAME:-k3s-cp-1}"
CTRL_CPU="${CTRL_CPU:-2}"
CTRL_MEM_MB="${CTRL_MEM_MB:-8192}"
CTRL_DISK_GB="${CTRL_DISK_GB:-40}"

WORKER_VMIDS_STR="${WORKER_VMIDS:-102 103}"
read -r -a WORKER_VMIDS <<< "${WORKER_VMIDS_STR}"
WORKER_NAMES_STR="${WORKER_NAMES:-k3s-w-1 k3s-w-2}"
read -r -a WORKER_NAMES <<< "${WORKER_NAMES_STR}"
WORKER_CPU="${WORKER_CPU:-2}"
WORKER_MEM_MB="${WORKER_MEM_MB:-4096}"
WORKER_DISK_GB="${WORKER_DISK_GB:-32}"

SSH_USER="${SSH_USER:-ubuntu}"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-}"
if [ -z "${SSH_PUBLIC_KEY_FILE}" ]; then
  for candidate in "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_rsa.pub"; do
    if [ -f "$candidate" ]; then
      SSH_PUBLIC_KEY_FILE="$candidate"
      break
    fi
  done
fi

if [ -z "${SSH_PUBLIC_KEY_FILE}" ] || [ ! -f "${SSH_PUBLIC_KEY_FILE}" ]; then
  abort "SSH public key not found; set SSH_PUBLIC_KEY_FILE to a readable .pub file"
fi
SSH_PUBLIC_KEY_DATA="$(tr -d '\n' < "${SSH_PUBLIC_KEY_FILE}")"
if [ -z "${SSH_PUBLIC_KEY_DATA}" ]; then
  abort "SSH public key ${SSH_PUBLIC_KEY_FILE} is empty"
fi

WORKER_COUNT="${#WORKER_IPS[@]}"
if [ ${WORKER_COUNT} -gt ${#WORKER_NAMES[@]} ]; then
  WORKER_COUNT="${#WORKER_NAMES[@]}"
fi
if [ ${WORKER_COUNT} -gt ${#WORKER_VMIDS[@]} ]; then
  WORKER_COUNT="${#WORKER_VMIDS[@]}"
fi
if [ ${WORKER_COUNT} -eq 0 ]; then
  abort "At least one worker definition (name, vmid, and IP) is required"
fi
say "Provisioning ${WORKER_COUNT} workers"
WORKER_IPS=("${WORKER_IPS[@]:0:${WORKER_COUNT}}")
WORKER_NAMES=("${WORKER_NAMES[@]:0:${WORKER_COUNT}}")
WORKER_VMIDS=("${WORKER_VMIDS[@]:0:${WORKER_COUNT}}")

mkdir -p "${CLOUD_IMAGE_DIR}"
if [ ! -f "${CLOUD_IMAGE_PATH}" ]; then
  say "Downloading Ubuntu cloud image to ${CLOUD_IMAGE_PATH}"
  tmpfile=$(mktemp)
  curl -fsSL "${UBUNTU_IMAGE_URL}" -o "$tmpfile"
  mv "$tmpfile" "${CLOUD_IMAGE_PATH}"
else
  say "Cloud image already cached at ${CLOUD_IMAGE_PATH}"
fi

vm_status() {
  local vmid="$1"
  local status
  status=$(qm status "$vmid" 2>/dev/null || true)
  if [ -z "$status" ]; then
    echo "missing"
    return
  fi
  echo "$status" | awk -F': ' 'NR==1 {print $2}'
}

vm_exists() {
  qm status "$1" >/dev/null 2>&1
}

create_vm_disk() {
  local vmid="$1"
  local desired_size_gb="$2"
  local disk_spec="${PROXMOX_STORAGE}:vm-${vmid}-disk-0"
  if [ "$QM_STUB" -eq 1 ]; then
    return 0
  fi
  if qm config "$vmid" | grep -q '^scsi0:'; then
    return 0
  fi
  say "Importing Ubuntu cloud image for VM ${vmid}"
  qm importdisk "$vmid" "${CLOUD_IMAGE_PATH}" "${PROXMOX_STORAGE}" --format qcow2 >/dev/null
  qm set "$vmid" --scsi0 "$disk_spec"
  qm set "$vmid" --scsihw virtio-scsi-pci
  if [ -n "$desired_size_gb" ]; then
    qm resize "$vmid" scsi0 "${desired_size_gb}G" >/dev/null 2>&1 || true
  fi
}

ensure_vm() {
  local vmid="$1"
  local name="$2"
  local role="$3"
  local cpu="$4"
  local mem="$5"
  local disk="$6"
  local ip="$7"

  if vm_exists "$vmid"; then
    say "Ensuring existing ${role} VM ${name} (VMID ${vmid})"
  else
    say "Creating ${role} VM ${name} (VMID ${vmid})"
    qm create "$vmid" --name "$name" --cores "$cpu" --memory "$mem" \
      --net0 "virtio,bridge=${BRIDGE}" --agent enabled=0 >/dev/null 2>&1 || true
  fi

  qm set "$vmid" --name "$name" --cores "$cpu" --memory "$mem" \
    --net0 "virtio,bridge=${BRIDGE}" \
    --serial0 socket --vga serial0 --agent enabled=0 --onboot 1

  create_vm_disk "$vmid" "$disk"

  qm set "$vmid" --boot order=scsi0 --bootdisk scsi0
  qm set "$vmid" --ide2 "${PROXMOX_STORAGE}:cloudinit,media=cdrom" \
    --ciuser "$SSH_USER" --sshkey "$SSH_PUBLIC_KEY_DATA" \
    --ipconfig0 "ip=${ip}/${NETWORK_PREFIX_LEN},gw=${NETWORK_GATEWAY}" \
    --hostname "$name" \
    --nameserver0 "${NETWORK_DNS}"

  local current_status
  current_status=$(vm_status "$vmid")
  if [ "$current_status" != "running" ]; then
    say "Starting ${name}"
    qm start "$vmid" >/dev/null 2>&1 || true
  else
    say "${name} already running"
  fi
}

say "Provisioning control plane VM"
ensure_vm "$CTRL_VMID" "$CTRL_NAME" "control-plane" "$CTRL_CPU" "$CTRL_MEM_MB" "$CTRL_DISK_GB" "$CTRL_IP"

for idx in "${!WORKER_VMIDS[@]}"; do
  ensure_vm "${WORKER_VMIDS[idx]}" "${WORKER_NAMES[idx]}" "worker" \
    "$WORKER_CPU" "$WORKER_MEM_MB" "$WORKER_DISK_GB" "${WORKER_IPS[idx]}"
done

say "Provisioning complete"
say "Control plane: ${CTRL_NAME} (${CTRL_IP})"
for idx in "${!WORKER_VMIDS[@]}"; do
  say "Worker ${WORKER_NAMES[idx]} -> ${WORKER_IPS[idx]}"
done
say "Next: run infrastructure/proxmox/cluster_bootstrap.sh k3s to bootstrap k3s on these VMs"
