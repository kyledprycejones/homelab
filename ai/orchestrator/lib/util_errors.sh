#!/usr/bin/env bash
set -euo pipefail

classify_error(){
  local logfile="$1"
  if [ -z "$logfile" ] || [ ! -f "$logfile" ]; then
    echo "ERR_UNKNOWN"
    return 0
  fi
  if grep -q "Talos kubeconfig missing" "$logfile"; then
    echo "ERR_TALOS_KUBECONFIG_MISSING"
    return 0
  fi
  if grep -q "Unable to locate package kubectl" "$logfile"; then
    echo "ERR_KUBECTL_NOT_AVAILABLE"
    return 0
  fi
  echo "ERR_UNKNOWN"
}
