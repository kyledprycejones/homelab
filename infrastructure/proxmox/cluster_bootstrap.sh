#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO (stage=${CURRENT_STAGE:-unknown})" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_ENV="${CONFIG_ENV:-${REPO_ROOT}/config/env/prox-n100.env}"
if [ -f "${CONFIG_ENV}" ]; then
  # shellcheck disable=SC1090
  source "${CONFIG_ENV}"
fi

log() {
  printf '[%s] %s\n' "$(date '+%F %T%z')" "$*"
}

say() {
  log "== $* =="
}

abort() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    abort "Required command '$1' not found in PATH"
  fi
}

yaml_top_value() {
  local key="$1"
  local file="$2"
  python3 - "$key" "$file" <<'PY'
import re
import sys
key = sys.argv[1]
path = sys.argv[2]
pattern = re.compile(r'^[ \t]*' + re.escape(key) + r'[ \t]*:[ \t]*(.*)$')
try:
    with open(path) as fh:
        for line in fh:
            match = pattern.match(line)
            if match:
                print(match.group(1).strip())
                sys.exit(0)
except FileNotFoundError:
    pass
PY
}

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

require_cmd curl
require_cmd python3
require_cmd nc

CLUSTER_CONFIG_FILE="${CLUSTER_CONFIG_FILE:-${REPO_ROOT}/config/clusters/prox-n100.yaml}"
CLUSTER_NAME="$(yaml_top_value clusterName "${CLUSTER_CONFIG_FILE}" || true)"
CLUSTER_NAME="${CLUSTER_NAME:-prox-n100}"
CTRL_IP="${CTRL_IP:-}"
if [ -n "${CTRL_IP}" ]; then
  say "Using CTRL_IP override from environment: ${CTRL_IP}"
else
  CTRL_IP="$(yaml_nested_value controller ip "${CLUSTER_CONFIG_FILE}" || true)"
fi
if [ -z "${CTRL_IP}" ]; then
  abort "Control plane IP missing; set CTRL_IP or add controller.ip to ${CLUSTER_CONFIG_FILE}"
fi

CTRL_NAME="${CTRL_NAME:-k3s-cp-1}"

WORKER_IPS=()
mapfile -t WORKER_IPS < <(yaml_list_values workers "${CLUSTER_CONFIG_FILE}")
if [ "${#WORKER_IPS[@]}" -eq 0 ]; then
  abort "Worker IPs missing in ${CLUSTER_CONFIG_FILE}; add a 'workers' list"
fi

WORKER_NAMES_STR="${WORKER_NAMES:-k3s-w-1 k3s-w-2}"
read -r -a WORKER_NAMES <<< "${WORKER_NAMES_STR}"
if [ "${#WORKER_NAMES[@]}" -lt "${#WORKER_IPS[@]}" ]; then
  say "WARNING: defined ${#WORKER_IPS[@]} worker IPs but only ${#WORKER_NAMES[@]} names; truncating IP list"
  WORKER_IPS=("${WORKER_IPS[@]:0:${#WORKER_NAMES[@]}}")
elif [ "${#WORKER_NAMES[@]}" -gt "${#WORKER_IPS[@]}" ]; then
  WORKER_NAMES=("${WORKER_NAMES[@]:0:${#WORKER_IPS[@]}}")
fi
WORKER_COUNT="${#WORKER_IPS[@]}"
if [ "${WORKER_COUNT}" -eq 0 ]; then
  abort "No workers configured"
fi

SSH_USER="${SSH_USER:-ubuntu}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
if [ -z "${SSH_KEY_FILE}" ]; then
  for cand in "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_rsa"; do
    if [ -f "$cand" ]; then
      SSH_KEY_FILE="$cand"
      break
    fi
  done
fi
if [ -z "${SSH_KEY_FILE}" ] || [ ! -f "${SSH_KEY_FILE}" ]; then
  abort "SSH key not found; set SSH_KEY_FILE to a valid private key"
fi

KUBECONFIG_DIR="${KUBECONFIG_DIR:-${REPO_ROOT}/infrastructure/proxmox/k3s}"
KUBECONFIG_PATH="${KUBECONFIG_DIR}/kubeconfig"
K3S_TOKEN_PATH="${KUBECONFIG_DIR}/node-token"
mkdir -p "${KUBECONFIG_DIR}"

K3S_INSTALL_URL="${K3S_INSTALL_URL:-https://get.k3s.io}"
K3S_CHANNEL="${K3S_CHANNEL:-stable}"
K3S_SERVER_ARGS="${K3S_SERVER_ARGS:---node-name ${CTRL_NAME:-k3s-cp-1} --node-ip ${CTRL_IP} --tls-san ${CTRL_IP} --write-kubeconfig-mode 644}"
K3S_URL="https://${CTRL_IP}:6443"
READY_TIMEOUT_SECS="${READY_TIMEOUT_SECS:-300}"
CURRENT_STAGE="init"

ssh_base_opts=(-i "${SSH_KEY_FILE}" -p "${SSH_PORT}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

build_remote_cmd() {
  local args=("$@")
  local cmd
  cmd=$(printf '%q ' "${args[@]}")
  printf '%s' "${cmd% }"
}

ssh_run() {
  local host="$1"
  shift
  [ "$#" -gt 0 ] || abort "ssh_run requires a command"
  local remote_cmd
  remote_cmd=$(build_remote_cmd "$@")
  ssh "${ssh_base_opts[@]}" "${SSH_USER}@${host}" "bash -lc '${remote_cmd}'"
}

scp_fetch() {
  local host="$1"
  local remote_path="$2"
  local local_path="$3"
  scp -q -i "${SSH_KEY_FILE}" -P "${SSH_PORT}" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${host}:${remote_path}" "${local_path}"
}

ensure_local_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    return
  fi
  say "Installing kubectl"
  local os arch version url dest
  os="$(uname | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) abort "Unsupported architecture: ${arch}" ;;
  esac
  version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  url="https://dl.k8s.io/${version}/bin/${os}/${arch}/kubectl"
  dest="/usr/local/bin/kubectl"
  if curl -fsSL "$url" -o /tmp/kubectl-download; then
    chmod +x /tmp/kubectl-download
    if sudo mv /tmp/kubectl-download "$dest" >/dev/null 2>&1; then
      say "kubectl installed to ${dest}"
    else
      mkdir -p "${HOME}/.local/bin"
      mv /tmp/kubectl-download "${HOME}/.local/bin/kubectl"
      dest="${HOME}/.local/bin/kubectl"
      say "kubectl installed to ${dest}"
    fi
  else
    abort "Failed to download kubectl"
  fi
  export PATH="${HOME}/.local/bin:${PATH}"
}

ensure_remote_command() {
  local host="$1"
  local tool="$2"
  ssh_run "$host" "if ! command -v ${tool} >/dev/null 2>&1; then sudo apt-get update -y && sudo apt-get install -y ${tool}; fi"
}

wait_for_port() {
  local host="$1"
  local port="$2"
  local deadline=$(( $(date +%s) + READY_TIMEOUT_SECS ))
  while true; do
    if nc -z -w 3 "$host" "$port" >/dev/null 2>&1; then
      break
    fi
    if [ $(date +%s) -ge "$deadline" ]; then
      abort "Timeout waiting for ${host}:${port}"
    fi
    sleep 3
  done
}

fetch_k3s_token() {
  local token
  token="$(ssh_run "$CTRL_IP" "sudo cat /var/lib/rancher/k3s/server/node-token")"
  token="${token//$'\n'/}"
  if [ -z "$token" ]; then
    abort "Failed to read k3s node token"
  fi
  echo "$token" > "$K3S_TOKEN_PATH"
  chmod 600 "$K3S_TOKEN_PATH"
  K3S_TOKEN="$token"
}

fetch_kubeconfig() {
  local tmpfile="${KUBECONFIG_PATH}.tmp"
  scp_fetch "$CTRL_IP" "/etc/rancher/k3s/k3s.yaml" "$tmpfile"
  python3 - "$CTRL_IP" "$tmpfile" <<'PY'
import pathlib, sys
ctrl_ip = sys.argv[1]
path = pathlib.Path(sys.argv[2])
data = path.read_text()
data = data.replace('https://127.0.0.1:6443', f'https://{ctrl_ip}:6443')
path.write_text(data)
PY
  mv "$tmpfile" "$KUBECONFIG_PATH"
  chmod 600 "$KUBECONFIG_PATH"
}

run_kubectl() {
  KUBECONFIG="$KUBECONFIG_PATH" kubectl "$@"
}

wait_for_nodes_ready() {
  local expected="$1"
  local deadline=$(( $(date +%s) + READY_TIMEOUT_SECS ))
  say "Waiting for ${expected} Kubernetes nodes to become Ready"
  while true; do
    local nodes
    nodes="$(run_kubectl get nodes --no-headers 2>/dev/null || true)"
    if [ -n "$nodes" ]; then
      local count
      count=$(printf '%s
' "$nodes" | wc -l)
      if [ "$count" -ge "$expected" ]; then
        if printf '%s
' "$nodes" | awk '$2 != "Ready" {exit 1}'; then
          say "All ${expected} nodes are Ready"
          run_kubectl get nodes -o wide
          break
        fi
      fi
    fi
    if [ $(date +%s) -ge "$deadline" ]; then
      log "Nodes output:"\n"$nodes"
      abort "Timed out waiting for nodes to become Ready"
    fi
    sleep 5
  done
}

install_k3s_server() {
  if ssh_run "$CTRL_IP" "sudo test -f /etc/rancher/k3s/k3s.yaml" >/dev/null 2>&1; then
    say "k3s server already installed on ${CTRL_IP}"
    return
  fi
  say "Installing k3s server on ${CTRL_IP}"
  ssh_run "$CTRL_IP" "curl -sfL ${K3S_INSTALL_URL} | INSTALL_K3S_CHANNEL=${K3S_CHANNEL} INSTALL_K3S_EXEC='server ${K3S_SERVER_ARGS}' sudo sh -"
  ssh_run "$CTRL_IP" "sudo systemctl enable --now k3s"
  wait_for_port "$CTRL_IP" 6443
}

install_k3s_agent() {
  local host="$1"
  local name="$2"
  if ssh_run "$host" "sudo test -f /etc/rancher/k3s/k3s-agent.yaml" >/dev/null 2>&1; then
    say "k3s agent already present on ${host}"
    return
  fi
  say "Joining ${host} as ${name}"
  ssh_run "$host" "curl -sfL ${K3S_INSTALL_URL} | INSTALL_K3S_CHANNEL=${K3S_CHANNEL} K3S_URL=${K3S_URL} K3S_TOKEN=${K3S_TOKEN} INSTALL_K3S_EXEC='agent --node-name ${name} --node-ip ${host}' sudo sh -"
  ssh_run "$host" "sudo systemctl enable --now k3s-agent"
}

stage_preflight() {
  CURRENT_STAGE="preflight"
  say "Preflight checks"
  ensure_local_kubectl
  if command -v nc >/dev/null 2>&1; then
    for host in "$CTRL_IP" "${WORKER_IPS[@]}"; do
      if nc -z -w 3 "$host" "$SSH_PORT" >/dev/null 2>&1; then
        log "SSH port reachable on ${host}:${SSH_PORT}"
      else
        log "SSH port ${SSH_PORT} not reachable on ${host} (VM may still boot)"
      fi
    done
  else
    log "nc not installed locally; skipping TCP preflight"
  fi
  say "Preflight complete"
}

stage_k3s() {
  CURRENT_STAGE="k3s"
  say "Bootstrapping k3s"
  log "Swap remains enabled on all nodes per policy"
  ensure_remote_command "$CTRL_IP" curl
  for host in "${WORKER_IPS[@]}"; do
    ensure_remote_command "$host" curl
  done
  install_k3s_server
  fetch_k3s_token
  say "Stored k3s node token at ${K3S_TOKEN_PATH}"
  for idx in "${!WORKER_IPS[@]}"; do
    install_k3s_agent "${WORKER_IPS[idx]}" "${WORKER_NAMES[idx]}"
  done
  fetch_kubeconfig
  say "Control plane: ${CTRL_NAME} (${CTRL_IP})"
  for idx in "${!WORKER_IPS[@]}"; do
    say "Worker ${WORKER_NAMES[idx]} -> ${WORKER_IPS[idx]}"
  done
  say "kubeconfig available at ${KUBECONFIG_PATH}"
  say "k3s bootstrap complete"
}

stage_postcheck() {
  CURRENT_STAGE="postcheck"
  say "Verifying cluster health"
  ensure_local_kubectl
  if [ ! -f "${KUBECONFIG_PATH}" ]; then
    abort "Kubeconfig missing at ${KUBECONFIG_PATH}; run the k3s stage first"
  fi
  wait_for_nodes_ready $((1 + WORKER_COUNT))
  run_kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
  run_kubectl -n kube-system get pods -l k8s-app=coredns -o wide
  run_kubectl -n kube-system get pods -o wide | head -n 20
  run_kubectl get nodes -o wide
  say "Cluster verification complete"
}

usage() {
  cat <<USAGE
Usage: $0 [preflight|k3s|postcheck|all]
Stages:
  preflight   - validate host tools and SSH connectivity
  k3s        - install k3s server + agents and fetch kubeconfig
  postcheck  - verify nodes Ready and core DNS pods
  all        - run all stages in order (default)
USAGE
  exit 1
}

TARGET_STAGE="${1:-all}"
case "$TARGET_STAGE" in
  preflight) stage_preflight ;; 
  k3s) stage_preflight; stage_k3s ;;
  postcheck) stage_postcheck ;;
  all) stage_preflight; stage_k3s; stage_postcheck ;;
  *) usage ;;
esac
yaml_list_values() {
