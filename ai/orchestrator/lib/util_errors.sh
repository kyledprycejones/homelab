#!/usr/bin/env bash
set -euo pipefail

: "${PROXMOX_HOST:=192.168.1.214}"
: "${PROXMOX_SSH_PORT:=22}"

# Error classifications that indicate EXTERNAL blockers (not recoverable by planner)
# These should trigger blocked_mode=external, not recovery escalation
EXTERNAL_BLOCK_CLASSIFICATIONS="ERR_SSH_UNREACHABLE ERR_SSH_AUTH_FAILED ERR_DNS_UNREACHABLE ERR_NETWORK_UNREACHABLE"

is_external_block_classification(){
  local classification="$1"
  case " $EXTERNAL_BLOCK_CLASSIFICATIONS " in
    *" $classification "*) return 0 ;;
    *) return 1 ;;
  esac
}

is_proxmox_host_reachable(){
  python3 - "$PROXMOX_HOST" "$PROXMOX_SSH_PORT" <<'PY'
import socket
import sys

host, port = sys.argv[1], int(sys.argv[2])
sock = socket.socket()
sock.settimeout(2.0)
try:
    sock.connect((host, port))
    sock.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
}

resolve_ssh_vs_vm_classification(){
  if is_proxmox_host_reachable; then
    echo "ERR_VM_UNREACHABLE"
  else
    echo "ERR_SSH_UNREACHABLE"
  fi
}

classify_error(){
  local logfile="$1"
  CLASSIFICATION_CONFIDENCE="low"
  if [ -z "$logfile" ] || [ ! -f "$logfile" ]; then
    echo "ERR_UNKNOWN"
    return 0
  fi

  if grep -q "Control-plane IP not configured" "$logfile"; then
    CLASSIFICATION_CONFIDENCE="high"
    echo "ERR_CONFIG_MISSING_CTRL_IP"
    return 0
  fi

  if grep -q "No VMs found on Proxmox" "$logfile"; then
    CLASSIFICATION_CONFIDENCE="high"
    echo "ERR_PREREQ_MISSING_VMS"
    return 0
  fi

  # SSH/Network connectivity errors - these are external unless the Proxmox host is reachable
  if grep -qE "Network is unreachable|No route to host|Connection timed out|Operation timed out" "$logfile"; then
    CLASSIFICATION_CONFIDENCE="high"
    resolve_ssh_vs_vm_classification
    return 0
  fi
  if grep -qE "ssh: connect to host .* port [0-9]+:" "$logfile" && grep -qE "rc=255|exit=255" "$logfile"; then
    CLASSIFICATION_CONFIDENCE="high"
    resolve_ssh_vs_vm_classification
    return 0
  fi
  if grep -qE "HARNESS_STEP name=scp rc=255" "$logfile"; then
    CLASSIFICATION_CONFIDENCE="high"
    resolve_ssh_vs_vm_classification
    return 0
  fi
  # SSH authentication failures
  if grep -qE "Permission denied.*publickey|Host key verification failed|Too many authentication failures" "$logfile"; then
    CLASSIFICATION_CONFIDENCE="high"
    echo "ERR_SSH_AUTH_FAILED"
    return 0
  fi
  # DNS resolution failures
  if grep -qE "Could not resolve hostname|Name or service not known|Temporary failure in name resolution" "$logfile"; then
    CLASSIFICATION_CONFIDENCE="high"
    echo "ERR_DNS_UNREACHABLE"
    return 0
  fi

  # k3s-specific errors
  if grep -q "k3s kubeconfig missing" "$logfile"; then
    CLASSIFICATION_CONFIDENCE="high"
    echo "ERR_K3S_KUBECONFIG_MISSING"
    return 0
  fi
  if grep -q "Unable to locate package kubectl" "$logfile"; then
    CLASSIFICATION_CONFIDENCE="high"
    echo "ERR_KUBECTL_NOT_AVAILABLE"
    return 0
  fi
  echo "ERR_UNKNOWN"
}
