#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_ENV="${CONFIG_ENV:-${REPO_ROOT}/config/env/prox-n100.env}"
LOG_DIR="${LOG_DIR:-${REPO_ROOT}/logs}"

if [ -f "${CONFIG_ENV}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${CONFIG_ENV}"
  set +a
fi

mkdir -p "${LOG_DIR}"
TS="$(date +%Y%m%d%H%M%S)"
LOG_FILE="${LOG_DIR}/bootstrap_${TS}.log"

if [ "$#" -gt 0 ]; then
  CMD=("${REPO_ROOT}/infrastructure/proxmox/cluster_bootstrap.sh" "$@")
else
  CMD=("${REPO_ROOT}/infrastructure/proxmox/cluster_bootstrap.sh" "all")
fi

echo "Logging to ${LOG_FILE}"
"${CMD[@]}" 2>&1 | tee "${LOG_FILE}"
