#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO}" >&2' ERR

ENV_FILE="config/env/prox-n100.env"
source "$ENV_FILE"

PROXMOX_HOST=192.168.1.214
PROXMOX_USER="$SSH_USER"
PROXMOX_PASS="$SSH_PASS"
PROXMOX_PORT=22
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROXMOX_STORAGE="${PROXMOX_STORAGE:-synology-nfs}"
BRIDGE="${BRIDGE:-vmbr0}"
CTRL_IP="${CTRL_IP:-}"
WORKERS="${WORKERS:-}"
CONTROL_CPU="${CONTROL_CPU:-2}"
CONTROL_MEM_MB="${CONTROL_MEM_MB:-8192}"
CONTROL_DISK_GB="${CONTROL_DISK_GB:-40}"
WORKER_CPU="${WORKER_CPU:-2}"
WORKER_MEM_MB="${WORKER_MEM_MB:-4096}"
WORKER_DISK_GB="${WORKER_DISK_GB:-32}"

SSH_OPTIONS=(
  -o StrictHostKeyChecking=accept-new
  -o PubkeyAuthentication=no
  -o BatchMode=no
  -o PreferredAuthentications=password,keyboard-interactive
  -o ConnectTimeout=7
  -o NumberOfPasswordPrompts=1
)

now(){ date "+%Y-%m-%dT%H:%M:%S%z"; }
stage(){ printf "\n[ %s ] STAGE: %s\n" "$(now)" "$*"; }

remote_scp(){
  local src="$1"
  local dst="$2"
  SSHPASS="$PROXMOX_PASS" sshpass -e scp -q -P "$PROXMOX_PORT" "${SSH_OPTIONS[@]}" "$src" "${PROXMOX_USER}@${PROXMOX_HOST}:${dst}"
}

remote_ssh(){
  local cmd="$1"
  SSHPASS="$PROXMOX_PASS" sshpass -e ssh -T -p "$PROXMOX_PORT" "${SSH_OPTIONS[@]}" "${PROXMOX_USER}@${PROXMOX_HOST}" "$cmd"
}

check_proxmox_connectivity(){
  stage "CHECK: Proxmox reachability ${PROXMOX_HOST}:${PROXMOX_PORT}"
  if ! remote_ssh "echo ok" >/dev/null 2>&1; then
    echo "ERROR: Unable to reach Proxmox at ${PROXMOX_HOST}:${PROXMOX_PORT} with provided credentials or network access." >&2
    exit 1
  fi
}

talos_loop(){
  local first_attempt=1
  while true; do
    stage "TALOS LOOP START"
    if [ "$first_attempt" -eq 1 ]; then
      first_attempt=0
      local wipe_script="${REPO_ROOT}/infrastructure/proxmox/wipe_proxmox.sh"
      if [ -f "$wipe_script" ]; then
        stage "TALOS LOOP: running wipe_proxmox.sh (first run)"
        if ! remote_scp "$wipe_script" "/root/wipe_proxmox.sh"; then
          stage "TALOS LOOP: failed to copy wipe_proxmox.sh"
        fi
        if ! remote_ssh "bash /root/wipe_proxmox.sh || true"; then
          stage "TALOS LOOP: wipe_proxmox.sh execution failed"
        fi
      fi
    fi
    local vms_script="${REPO_ROOT}/infrastructure/proxmox/vms.sh"
    if [ -f "$vms_script" ]; then
      stage "TALOS LOOP: provisioning VMs"
      local vms_tmp="$(mktemp)"
      cat >"$vms_tmp" <<'VMS'
#!/usr/bin/env bash
set -euo pipefail

say(){ echo -e "\n== $* =="; }

PROXMOX_STORAGE="${PROXMOX_STORAGE:-synology-nfs}"
BRIDGE="${BRIDGE:-vmbr0}"
CTRL_VMID="${CTRL_VMID:-101}"
CTRL_NAME="${CTRL_NAME:-talos-cp-1}"
CONTROL_CPU="${CONTROL_CPU:-2}"
CONTROL_MEM_MB="${CONTROL_MEM_MB:-8192}"
CONTROL_DISK_GB="${CONTROL_DISK_GB:-40}"
WORKER_VMIDS_STR="${WORKER_VMIDS:-102 103}"
WORKER_NAMES_STR="${WORKER_NAMES:-talos-w-1 talos-w-2}"
WORKER_CPU="${WORKER_CPU:-2}"
WORKER_MEM_MB="${WORKER_MEM_MB:-4096}"
WORKER_DISK_GB="${WORKER_DISK_GB:-32}"
ISO_NAME="${ISO_NAME:-metal-amd64.iso}"
ISO_PATH="${ISO_PATH:-/mnt/pve/${PROXMOX_STORAGE}/template/iso/${ISO_NAME}}"
ISO_VOL="${ISO_VOL:-${PROXMOX_STORAGE}:iso/${ISO_NAME}}"

read -r -a WORKER_VMIDS <<<"${WORKER_VMIDS_STR}"
read -r -a WORKER_NAMES <<<"${WORKER_NAMES_STR}"

mkdir -p "$(dirname "${ISO_PATH}")"
if [ ! -f "${ISO_PATH}" ]; then
  say "Downloading Talos ISO to ${ISO_PATH}"
  curl -fsSL -o "${ISO_PATH}" "https://github.com/siderolabs/talos/releases/latest/download/${ISO_NAME}"
else
  say "Talos ISO already present at ${ISO_PATH}"
fi

ensure_disk(){
  local vmid="$1" size_gb="$2"
  local disk_dir="/mnt/pve/${PROXMOX_STORAGE}/images/${vmid}"
  local disk_path="${disk_dir}/vm-${vmid}-disk-0.raw"
  if ! qm config "$vmid" | grep -q '^scsi0:'; then
    mkdir -p "${disk_dir}"
    qemu-img create -f raw "${disk_path}" "${size_gb}G"
    qm set "$vmid" --scsi0 "${PROXMOX_STORAGE}:${vmid}/vm-${vmid}-disk-0.raw"
  fi
}

configure_vm(){
  local vmid="$1" name="$2" role="$3" cpu="$4" mem="$5" disk="$6"
  if ! qm status "$vmid" >/dev/null 2>&1; then
    say "Creating ${role} VM ${name} (VMID ${vmid})"
    qm create "$vmid" --name "$name" --cores "$cpu" --memory "$mem" \
      --net0 "virtio,bridge=${BRIDGE}" --scsihw virtio-scsi-pci --agent enabled=0
  else
    say "Ensuring existing ${role} VM ${name} (VMID ${vmid})"
  fi

  qm set "$vmid" --name "$name" --cores "$cpu" --memory "$mem" \
    --net0 "virtio,bridge=${BRIDGE}" --serial0 socket --vga serial0 --agent enabled=0 --onboot 1

  ensure_disk "$vmid" "$disk"

  qm set "$vmid" --boot order=ide2\;scsi0 --bootdisk scsi0 --ide2 "${ISO_VOL},media=cdrom"

  if [ "$(qm status "$vmid" 2>/dev/null | awk '{print $2}')" != "running" ]; then
    say "Starting ${name} to boot the Talos installer"
    qm start "$vmid" || true
  else
    say "${name} already running"
  fi
}

configure_vm "$CTRL_VMID" "$CTRL_NAME" control-plane "$CONTROL_CPU" "$CONTROL_MEM_MB" "$CONTROL_DISK_GB"

for idx in "${!WORKER_VMIDS[@]}"; do
  configure_vm "${WORKER_VMIDS[idx]}" "${WORKER_NAMES[idx]}" worker "$WORKER_CPU" "$WORKER_MEM_MB" "$WORKER_DISK_GB"
done

say "Talos VMs ready: ${CTRL_NAME} (${CTRL_VMID}) DHCP-only networking enabled"
VMS
      local vms_to_copy="$vms_tmp"
      if ! remote_scp "$vms_to_copy" "/root/vms.sh"; then
        stage "TALOS LOOP: failed to copy vms.sh"
      fi
      rm -f "$vms_tmp"
      local remote_env=(
        "PROXMOX_STORAGE=${PROXMOX_STORAGE}"
        "BRIDGE=${BRIDGE}"
        "CTRL_IP=${CTRL_IP}"
        "WORKERS=${WORKERS}"
        "CONTROL_CPU=${CONTROL_CPU}"
        "CONTROL_MEM_MB=${CONTROL_MEM_MB}"
        "CONTROL_DISK_GB=${CONTROL_DISK_GB}"
        "WORKER_CPU=${WORKER_CPU}"
        "WORKER_MEM_MB=${WORKER_MEM_MB}"
        "WORKER_DISK_GB=${WORKER_DISK_GB}"
      )
      local remote_prefix=""
      for kv in "${remote_env[@]}"; do
        local key="${kv%%=*}"
        local value="${kv#*=}"
        remote_prefix+="${key}='${value}' "
      done
      if ! remote_ssh "${remote_prefix}bash /root/vms.sh"; then
        stage "TALOS LOOP: vms.sh execution failed"
      fi
    fi
    stage "TALOS LOOP: invoking bootstrap talos"
    if bash "${REPO_ROOT}/infrastructure/proxmox/cluster_bootstrap.sh" talos; then
      stage "TALOS LOOP SUCCESS"
      break
    fi
    local rc=$?
    stage "TALOS LOOP FAILED (rc=${rc}) - retrying in 3s"
    sleep 3
  done
}

infra_loop(){
  while true; do
    stage "INFRA LOOP START"
    if bash "${REPO_ROOT}/infrastructure/proxmox/cluster_bootstrap.sh" infra; then
      stage "INFRA LOOP SUCCESS"
      break
    fi
    local rc=$?
    stage "INFRA LOOP FAILED (rc=${rc}) - retrying in 3s"
    sleep 3
  done
}

apps_loop(){
  while true; do
    stage "APPS LOOP START"
    if bash "${REPO_ROOT}/infrastructure/proxmox/cluster_bootstrap.sh" apps; then
      stage "APPS LOOP SUCCESS"
      break
    fi
    local rc=$?
    stage "APPS LOOP FAILED (rc=${rc}) - retrying in 3s"
    sleep 3
  done
}

stage "CLI LOOP START"
check_proxmox_connectivity
talos_loop
infra_loop
apps_loop
stage "CLI LOOP COMPLETE"
