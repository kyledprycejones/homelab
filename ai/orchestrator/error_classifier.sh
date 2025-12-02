#!/usr/bin/env bash
set -euo pipefail

classify_error(){
  local tail="$1"
  local lower="${tail,,}"
  ERROR_HASH="$(printf '%s' "$tail" | shasum | awk '{print $1}')"
  if [[ "$lower" == *"permission"* ]]; then ERROR_TYPE="permission_denied"; return; fi
  if [[ "$lower" == *"no such file"* || "$lower" == *"cannot open"* ]]; then ERROR_TYPE="missing_file"; return; fi
  if [[ "$lower" == *"command not found"* ]]; then ERROR_TYPE="command_not_found"; return; fi
  if [[ "$lower" == *"timeout"* || "$lower" == *"network"* || "$lower" == *"connection"* ]]; then ERROR_TYPE="network_error"; return; fi
  if [[ "$lower" == *"yaml"* || "$lower" == *"kustomize"* ]]; then ERROR_TYPE="yaml_parse_error"; return; fi
  if [[ "$lower" == *"talos"* ]]; then ERROR_TYPE="talos_error"; return; fi
  if [[ "$lower" == *"proxmox"* ]]; then ERROR_TYPE="proxmox_error"; return; fi
  ERROR_TYPE="unknown"
}
