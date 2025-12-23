#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

: "${PROXMOX_INVENTORY_FILE:=${REPO_ROOT}/ai/state/proxmox_inventory.json}"
: "${CTRL_IP_FILE:=${REPO_ROOT}/ai/state/ctrl_ip.txt}"
: "${NODE_IPS_FILE:=${REPO_ROOT}/ai/state/node_ips.txt}"

if [ ! -f "${PROXMOX_INVENTORY_FILE}" ]; then
  echo "ERROR: Proxmox inventory missing; run S1-PROVISION-VMS" >&2
  exit 1
fi

controller_ip="$(python3 - "${PROXMOX_INVENTORY_FILE}" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception:
    sys.exit(1)
print(data.get("controller_ip", ""))
PY
)"

controller_ip="${controller_ip//$'\r'/}"
controller_ip="${controller_ip//$'\n'/}"

if [ -z "${controller_ip}" ]; then
  echo "ERROR: Control-plane IP not configured in inventory; run S1-PROVISION-VMS first." >&2
  exit 1
fi

node_ips="$(python3 - "${PROXMOX_INVENTORY_FILE}" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path))
hosts = []
for vm in data.get("vms", []):
    for key in ("ip", "ipconfig0"):
        value = vm.get(key)
        if value:
            hosts.append(value)
            break
print("\n".join(hosts))
PY
)"

mkdir -p "$(dirname "${CTRL_IP_FILE}")"
printf '%s\n' "${controller_ip}" > "${CTRL_IP_FILE}"

mkdir -p "$(dirname "${NODE_IPS_FILE}")"
: > "${NODE_IPS_FILE}"
if [ -n "${node_ips}" ]; then
  printf '%s\n' "${node_ips}" >> "${NODE_IPS_FILE}"
fi

echo "controller_ip=${controller_ip}"
if [ -n "${node_ips}" ]; then
  echo "node_ips:"
  printf '%s\n' "${node_ips}"
else
  echo "node_ips: <none>"
fi
