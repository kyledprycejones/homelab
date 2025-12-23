#!/usr/bin/env bash
# Preflight Tool Checker
# Ensures required tools are available before running stages/probes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

log() {
  printf '[preflight] %s\n' "$1" >&2
}

error() {
  printf '[preflight] ERROR: %s\n' "$1" >&2
  return 1
}

check_tool() {
  local tool="$1"
  local install_cmd="${2:-}"

  if command -v "$tool" >/dev/null 2>&1; then
    log "✓ $tool found: $(command -v $tool)"
    return 0
  fi

  if [ -n "$install_cmd" ]; then
    log "⚠ $tool not found, attempting installation..."
    if eval "$install_cmd"; then
      if command -v "$tool" >/dev/null 2>&1; then
        log "✓ $tool installed successfully: $(command -v $tool)"
        return 0
      else
        error "$tool installation completed but command still not found in PATH"
        return 1
      fi
    else
      error "$tool installation failed"
      return 1
    fi
  else
    error "$tool not found and no install command provided"
    return 1
  fi
}

install_kubectl() {
  local os arch version url install_path
  os="$(uname | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *)
      error "Unsupported architecture: ${arch}"
      return 1
      ;;
  esac
  version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  url="https://dl.k8s.io/${version}/bin/${os}/${arch}/kubectl"
  install_path="/usr/local/bin/kubectl"
  if curl -fsSL "$url" -o /tmp/kubectl-install; then
    chmod +x /tmp/kubectl-install
    if sudo mv /tmp/kubectl-install "$install_path" >/dev/null 2>&1; then
      log "kubectl installed to ${install_path}"
    else
      mkdir -p "${HOME}/.local/bin"
      mv /tmp/kubectl-install "${HOME}/.local/bin/kubectl"
      install_path="${HOME}/.local/bin/kubectl"
      log "kubectl installed to ${install_path}"
    fi
    export PATH="${HOME}/.local/bin:${PATH}"
    return 0
  else
    error "Failed to download kubectl from ${url}"
    return 1
  fi
}

preflight_stage() {
  local stage="$1"
  local failed=0

  log "Running preflight checks for stage: $stage"
  case "$stage" in
    k3s)
      if ! check_tool kubectl "install_kubectl"; then
        failed=1
      fi
      ;;
    infra|apps|ingress|obs)
      if ! command -v kubectl >/dev/null 2>&1; then
        log "⚠ kubectl not found (the bootstrap script installs it during k3s stage)"
      else
        log "✓ kubectl found: $(command -v kubectl)"
      fi
      ;;
    *)
      log "No specific preflight checks for stage: $stage"
      ;;
  esac

  if [ $failed -eq 0 ]; then
    log "Preflight checks passed for stage: $stage"
    return 0
  else
    error "Preflight checks failed for stage: $stage"
    return 1
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  stage="${1:-}"
  if [ -z "$stage" ]; then
    error "Usage: $0 <stage>"
    exit 1
  fi
  preflight_stage "$stage"
fi
