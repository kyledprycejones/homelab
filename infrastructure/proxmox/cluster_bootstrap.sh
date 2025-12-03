#!/usr/bin/env bash
set -eEuo pipefail

CURRENT_STAGE="init"
on_err() {
  local rc=$?
  echo "ERROR: Stage ${CURRENT_STAGE:-unknown} failed at line $1 (exit=${rc}). Check the harness log for details."
  exit "$rc"
}
trap 'on_err $LINENO' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Optional: preload environment from config/env/<cluster>.env
CONFIG_ENV="${CONFIG_ENV:-${REPO_ROOT}/config/env/prox-n100.env}"
if [ -f "${CONFIG_ENV}" ]; then
  # shellcheck disable=SC1090
  source "${CONFIG_ENV}"
fi

########################################
# CONFIG
########################################
CTRL_IP="${CTRL_IP:-192.168.1.151}"
# Allow WORKERS env as a space/comma-separated list; fallback to two defaults
if [ -n "${WORKERS:-}" ]; then
  IFS=' ,:' read -r -a WORKERS <<< "${WORKERS}"
else
  WORKERS=("${WORKER1:-192.168.1.152}" "${WORKER2:-192.168.1.153}")
fi
# Drop empty entries so callers can omit unused defaults
_trimmed_workers=()
for w in "${WORKERS[@]}"; do
  [ -n "$w" ] && _trimmed_workers+=("$w")
done
WORKERS=("${_trimmed_workers[@]}")

# Talos cluster settings
TALOS_CLUSTER_NAME="${TALOS_CLUSTER_NAME:-prox-n100}"
TALOS_ENDPOINTS="${TALOS_ENDPOINTS:-$CTRL_IP}"

# Where to store Talos cluster config + kubeconfig on the host running this script
# Use $HOME/.talos when running remotely (script copied to /tmp)
# Only use REPO_ROOT/.talos if REPO_ROOT is set and not root directory
if [ -n "${TALOS_CONFIG_DIR:-}" ]; then
  : # Use explicit override
elif [ -n "${REPO_ROOT:-}" ] && [ "${REPO_ROOT}" != "/" ] && [ "${REPO_ROOT}" != "/tmp" ]; then
  TALOS_CONFIG_DIR="${REPO_ROOT}/.talos/${TALOS_CLUSTER_NAME}"
else
  TALOS_CONFIG_DIR="${HOME}/.talos/${TALOS_CLUSTER_NAME}"
fi
TALOS_KUBECONFIG="${TALOS_KUBECONFIG:-${TALOS_CONFIG_DIR}/kubeconfig}"

# Default install disk for Talos nodes (override if needed)
TALOS_INSTALL_DISK="${TALOS_INSTALL_DISK:-/dev/sda}"

# Extra flags for talosctl gen config (e.g. --with-secrets)
TALOS_EXTRA_GENCONFIG_FLAGS="${TALOS_EXTRA_GENCONFIG_FLAGS:-}"

# SSH config (override via env: SSH_USER, SSH_PASS, SSH_PORT)
SSH_USER="${SSH_USER:-kyle}"
SSH_PASS="${SSH_PASS:-root}"
SSH_PORT="${SSH_PORT:-22}"

DOMAIN="${DOMAIN:-funoffshore.com}"
LE_EMAIL="${LE_EMAIL:-}"

# NFS
NFS_SERVER="${NFS_SERVER:-192.168.1.112}"
NFS_PATH="${NFS_PATH:-/volume1/fire_share2}"

# GitOps
GIT_REPO="${GIT_REPO:-https://github.com/kyledprycejones/homelab}"
# Use the default repo branch unless overridden
GIT_BRANCH="${GIT_BRANCH:-main}"
USE_LOCAL_GIT_SNAPSHOT="${USE_LOCAL_GIT_SNAPSHOT:-1}"
LOCAL_GIT_SNAPSHOT_PORT="${LOCAL_GIT_SNAPSHOT_PORT:-29418}"
LOCAL_GIT_SNAPSHOT_DIR="${LOCAL_GIT_SNAPSHOT_DIR:-/opt/git_snapshots}"

# Timeouts
READY_TIMEOUT_SECS=${READY_TIMEOUT_SECS:-600}
JOIN_TIMEOUT_SECS=${JOIN_TIMEOUT_SECS:-300}

# Verbosity / Debug
# -v   : verbose
# -vv  : very verbose (enable shell xtrace)
# -vvv : max verbosity (xtrace + SSH debug)
VERBOSE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -vvv) VERBOSE=3; shift ;;
    -vv)  VERBOSE=2; shift ;;
    -v)   VERBOSE=1; shift ;;
    --verbose)
      VERBOSE="${2:-1}"; shift 2 ;;
    --) shift; break ;;
    -*) break ;;
    *) break ;;
  esac
done

# Preserve legacy DEBUG=1 behavior
if [ "${DEBUG:-0}" = "1" ]; then VERBOSE=$(( VERBOSE < 2 ? 2 : VERBOSE )); fi
if [ "$VERBOSE" -ge 2 ]; then set -x; fi
# SSH log level adjusts with verbosity
SSH_LOG_LEVEL=ERROR
if [ "$VERBOSE" -ge 3 ]; then SSH_LOG_LEVEL=DEBUG; elif [ "$VERBOSE" -ge 2 ]; then SSH_LOG_LEVEL=INFO; fi

########################################
# OPTIONAL SECRETS (env)
# If unset, Cloudflare-related pieces (DNS01 + tunnel) are skipped
########################################
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
# Optional: Cloudflare Origin CA key (used to issue origin certificates via Cloudflare)
CF_ORIGIN_CA_KEY="${CF_ORIGIN_CA_KEY:-}"


########################################
# HELPERS
########################################
say(){ echo -e "\n== $* =="; }

stage_start() {
  local name="$1"
  CURRENT_STAGE="$name"
  say "STAGE [$name] START"
}

stage_end() {
  local name="$1"
  say "STAGE [$name] COMPLETE"
  CURRENT_STAGE="idle"
}

# Print effective config (masking secrets)
say_config() {
  local cf_api_masked cf_tunnel_masked origin_ca_masked pass_masked
  cf_api_masked="${CF_API_TOKEN:0:4}***${CF_API_TOKEN:+${CF_API_TOKEN: -4}}"
  cf_tunnel_masked="${CF_TUNNEL_TOKEN:0:4}***${CF_TUNNEL_TOKEN:+${CF_TUNNEL_TOKEN: -4}}"
  origin_ca_masked="${CF_ORIGIN_CA_KEY:0:6}***${CF_ORIGIN_CA_KEY:+${CF_ORIGIN_CA_KEY: -4}}"
  pass_masked="${SSH_PASS:+*****}"
  echo "Config: CTRL_IP=$CTRL_IP SSH_USER=$SSH_USER SSH_PORT=$SSH_PORT PASS=$pass_masked WORKERS=${WORKERS[*]} DOMAIN=$DOMAIN GIT_BRANCH=$GIT_BRANCH"
  echo "Cloudflare: API=$cf_api_masked TUNNEL=$cf_tunnel_masked ORIGIN_CA=$origin_ca_masked"
}

install_pkg_if_available() {
  local pkg="$1"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y && sudo apt-get install -y "$pkg"
  elif command -v brew >/dev/null 2>&1; then
    brew install "$pkg" || true
  else
    echo "WARN: could not install $pkg automatically (no apt-get or brew found). Install it manually." >&2
    return 1
  fi
}

ensure_host_tools() {
  if ! command -v sshpass >/dev/null 2>&1 && [ -n "${SSH_PASS:-}" ]; then
    say "Installing sshpass on host"
    install_pkg_if_available sshpass || true
  fi
  # Ensure curl and jq are available for helper calls (best-effort)
  if ! command -v curl >/dev/null 2>&1; then
    install_pkg_if_available curl || true
  fi
  if ! command -v jq >/dev/null 2>&1; then
    install_pkg_if_available jq || true
  fi
  # nc for connectivity checks
  if ! command -v nc >/dev/null 2>&1; then
    install_pkg_if_available netcat-openbsd || true
  fi

  ensure_talosctl
  ensure_local_kubectl
  ensure_known_hosts
}

ensure_talosctl() {
  if command -v talosctl >/dev/null 2>&1; then
    return 0
  fi
  say "Installing talosctl on host"
  local os arch url
  os="$(uname | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
  esac
  url="https://github.com/siderolabs/talos/releases/latest/download/talosctl-${os}-${arch}"
  curl -fsSL "$url" -o /tmp/talosctl
  chmod +x /tmp/talosctl
  sudo mv /tmp/talosctl /usr/local/bin/talosctl
}

ensure_local_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    return 0
  fi
  say "Installing kubectl on host (best effort)"
  if command -v brew >/dev/null 2>&1; then
    brew install kubectl || true
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y && sudo apt-get install -y kubectl || true
  fi
}

ensure_local_helm() {
  if command -v helm >/dev/null 2>&1; then
    return 0
  fi
  say "Installing helm on host (best effort)"
  if command -v brew >/dev/null 2>&1; then
    brew install helm || true
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y && sudo apt-get install -y helm || true
  fi
}

ensure_flux_cli() {
  if command -v flux >/dev/null 2>&1; then
    return 0
  fi
  say "Installing flux CLI on host (best effort)"
  curl -s https://fluxcd.io/install.sh | sudo bash || true
}

setup_local_git_snapshot() {
  if [ "${USE_LOCAL_GIT_SNAPSHOT}" != "1" ]; then
    say "Using remote GitOps repo ${GIT_REPO}@${GIT_BRANCH}"
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is required to create the local Git snapshot" >&2
    exit 1
  fi

  local branch_ref repo_root bundle
  repo_root="${REPO_ROOT}"
  branch_ref="${GIT_BRANCH}"
  if [ -z "$branch_ref" ] || ! git -C "$repo_root" rev-parse --verify "$branch_ref" >/dev/null 2>&1; then
    branch_ref="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
  fi

  bundle="$(mktemp /tmp/homelab-git-XXXXXX.bundle)"
  git -C "$repo_root" bundle create "$bundle" "$branch_ref"
  scp_to "$bundle" "$CTRL_IP" "/tmp/homelab.bundle"
  rm -f "$bundle"

  ssh_do "$CTRL_IP" "sudo mkdir -p ${LOCAL_GIT_SNAPSHOT_DIR} && sudo chown -R ${SSH_USER}:${SSH_USER} ${LOCAL_GIT_SNAPSHOT_DIR}"
  ssh_do "$CTRL_IP" "rm -rf ${LOCAL_GIT_SNAPSHOT_DIR}/homelab.git && git clone --bare /tmp/homelab.bundle ${LOCAL_GIT_SNAPSHOT_DIR}/homelab.git"
  ssh_do "$CTRL_IP" "pkill -f 'git daemon.*${LOCAL_GIT_SNAPSHOT_DIR}' >/dev/null 2>&1 || true"
  ssh_do "$CTRL_IP" "nohup bash -c 'cd ${LOCAL_GIT_SNAPSHOT_DIR} && git daemon --reuseaddr --base-path=${LOCAL_GIT_SNAPSHOT_DIR} --export-all --port=${LOCAL_GIT_SNAPSHOT_PORT} ${LOCAL_GIT_SNAPSHOT_DIR} >${LOCAL_GIT_SNAPSHOT_DIR}/git-daemon.log 2>&1' >/dev/null 2>&1 &"

  GIT_REPO="git://${CTRL_IP}:${LOCAL_GIT_SNAPSHOT_PORT}/homelab.git"
  GIT_BRANCH="$branch_ref"
  say "Serving local Git snapshot at ${GIT_REPO} (branch ${GIT_BRANCH})"
}

# Preload SSH known_hosts for controller and workers to avoid repeated warnings
ensure_known_hosts() {
  # Prefer $HOME/.ssh, but fall back to a writable temp path if needed
  local home_dir="${HOME:-/root}"
  local kh
  if ! mkdir -p "$home_dir/.ssh" 2>/dev/null; then
    home_dir="/tmp/homelab_ssh"
    mkdir -p "$home_dir/.ssh"
  fi
  chmod 700 "$home_dir/.ssh" || true
  kh="$home_dir/.ssh/known_hosts"
  touch "$kh" 2>/dev/null || { kh="/tmp/homelab_ssh/known_hosts"; mkdir -p /tmp/homelab_ssh; touch "$kh"; }
  chmod 600 "$kh" || true
  for ip in "$CTRL_IP" "${WORKERS[@]}"; do
    # Add if not present
    if ! grep -q "^\[$ip\]" "$kh" 2>/dev/null && ! grep -q "^$ip " "$kh" 2>/dev/null; then
      ssh-keyscan -H "$ip" 2>/dev/null >> "$kh" || true
    fi
  done
}

render_flux_sync() {
  local src="$1" dst="$2"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required to render ${src}" >&2
    exit 1
  fi
  GIT_BRANCH="${GIT_BRANCH:-main}" GIT_REPO="${GIT_REPO:-}" python3 - "$src" "$dst" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
repo = os.environ.get("GIT_REPO", "")
branch = os.environ.get("GIT_BRANCH", "main") or "main"
with open(src, "r", encoding="utf-8") as f:
    data = f.read()
data = data.replace("${GIT_REPO}", repo).replace("${GIT_BRANCH:-main}", branch)
with open(dst, "w", encoding="utf-8") as f:
    f.write(data)
PY
}

ssh_do() {
  local host="$1"; shift
  SSHPASS="$SSH_PASS" sshpass -e \
    ssh -T -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new -o LogLevel=${SSH_LOG_LEVEL:-ERROR} \
    "${SSH_USER}@${host}" "$@"
}

scp_to() {
  local src="$1" host="$2" dst="$3"
  SSHPASS="$SSH_PASS" sshpass -e \
    scp -q -P "${SSH_PORT}" -o StrictHostKeyChecking=accept-new -o LogLevel=${SSH_LOG_LEVEL:-ERROR} \
    "$src" "${SSH_USER}@${host}:${dst}"
}

wipe_known_hosts() {
  local home_dir="${HOME:-/root}"
  local kh="$home_dir/.ssh/known_hosts"
  [ -f "$kh" ] || return 0
  for ip in "$CTRL_IP" "${WORKERS[@]}"; do
    ssh-keygen -f "$kh" -R "$ip" >/dev/null 2>&1 || true
    ssh-keygen -f "$kh" -R "[$ip]:${SSH_PORT}" >/dev/null 2>&1 || true
  done
}

ensure_prereqs_node() {
  local host="$1"
  ssh_do "$host" "sudo swapoff -a || true; sudo sed -i '/ swap / s/^/#/' /etc/fstab || true"
  ssh_do "$host" "command -v ufw >/dev/null 2>&1 && (sudo ufw disable || true) || true"
  ssh_do "$host" "if ! command -v chronyd >/dev/null 2>&1 && ! command -v chrony >/dev/null 2>&1; then sudo apt-get update -y && sudo apt-get install -y chrony; fi; sudo systemctl enable --now chrony || true"
  # Ensure NFS client is available for dynamic provisioning
  ssh_do "$host" "command -v mount.nfs >/dev/null 2>&1 || (sudo apt-get update -y && sudo apt-get install -y nfs-common)"
}

#
# Run a command locally with kubeconfig set (Talos-managed cluster)
kctl() {
  # Pass arbitrary shell fragments through bash -lc so conditionals / pipes work,
  # with KUBECONFIG pointed at the Talos-generated kubeconfig.
  if [ "${INFRA_QUIET:-0}" = "1" ] && [[ "$*" != *"<<"* ]]; then
    KUBECONFIG="${TALOS_KUBECONFIG}" bash -lc "$* 1>/dev/null"
  else
    KUBECONFIG="${TALOS_KUBECONFIG}" bash -lc "$*"
  fi
}

helmctl() {
  if [ "${INFRA_QUIET:-0}" = "1" ] && [[ "$*" != *"<<"* ]]; then
    KUBECONFIG="${TALOS_KUBECONFIG}" bash -lc "$* 1>/dev/null"
  else
    KUBECONFIG="${TALOS_KUBECONFIG}" bash -lc "$*"
  fi
}

wait_nodes_ready() {
  local expected_nodes=$((1 + ${#WORKERS[@]}))
  local deadline=$(( $(date +%s) + READY_TIMEOUT_SECS ))

  say "Waiting for ${expected_nodes} Kubernetes node(s) to become Ready via Talos kubeconfig ${TALOS_KUBECONFIG}"

  while true; do
    if kctl "kubectl get nodes 2>/dev/null | grep -q ' Ready ' && [ \$(kubectl get nodes --no-headers | wc -l) -ge ${expected_nodes} ]"; then
      kctl "kubectl get nodes -o wide"
      break
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "ERROR: Timeout waiting for all nodes to become Ready."
      kctl "kubectl get nodes -o wide || true; kubectl get pods -A -o wide || true"
      exit 1
    fi

    sleep 5
  done
}

# Basic reachability and auth checks before doing expensive work
check_connectivity() {
  say "Checking SSH connectivity"
  local all_hosts=("$CTRL_IP" "${WORKERS[@]}")
  for h in "${all_hosts[@]}"; do
    printf -- "- %s: " "$h"
    if command -v nc >/dev/null 2>&1 && ! nc -z -w 2 "$h" "$SSH_PORT" 2>/dev/null; then
      echo "port ${SSH_PORT} closed"; continue
    fi
    if SSHPASS="$SSH_PASS" sshpass -e ssh -T -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=4 -o LogLevel=ERROR "${SSH_USER}@${h}" 'echo ok' 2>/dev/null | grep -q '^ok$'; then
      echo "ok"
    else
      echo "ssh failed"
    fi
  done
}

# DNS preflight — verify host can resolve external names
dns_preflight_host() {
  say "DNS preflight: validating external name resolution on control-plane host"
  # Try multiple tools on the host to resolve a well-known domain
  if ! ssh_do "$CTRL_IP" "getent hosts onedr0p.github.io >/dev/null 2>&1 || resolvectl query onedr0p.github.io >/dev/null 2>&1 || nslookup onedr0p.github.io >/dev/null 2>&1"; then
    echo "ERROR: Control-plane host cannot resolve external domains (e.g., onedr0p.github.io)." >&2
    echo "Fix the host's DNS (systemd-resolved or netplan). Example for systemd-resolved:" >&2
    echo "  sudo mkdir -p /etc/systemd/resolved.conf.d" >&2
    echo "  printf '[Resolve]\nDNS=1.1.1.1 1.0.0.1 8.8.8.8\nDomains=~.\n' | sudo tee /etc/systemd/resolved.conf.d/10-public.conf" >&2
    echo "  sudo systemctl restart systemd-resolved && resolvectl query onedr0p.github.io" >&2
    exit 1
  fi
}

# Summarize cluster state for quick debugging
diagnose_cluster() {
  ensure_cluster_ready
  say "Cluster info"
  kctl "kubectl version --short || true"
  kctl "kubectl cluster-info || true"
  kctl "kubectl get nodes -o wide || true"
  say "Core components"
  kctl "kubectl -n kube-system get pods -o wide || true"
  say "Argocd pods"
  kctl "kubectl -n argocd get pods -o wide || true"
  say "Vault pods"
  kctl "kubectl -n vault get pods -o wide || true"
  say "Storage classes"
  kctl "kubectl get sc || true"
  say "PVCs"
  kctl "kubectl get pvc -A || true"
  say "Services"
  kctl "kubectl get svc -A | sed -n '1,120p' || true"
  say "Pending/Failed pods detail"
  kctl "kubectl get pods -A --field-selector=status.phase!=Running -o wide || true"
  say "Recent events"
  kctl "kubectl get events -A --sort-by=.lastTimestamp | tail -n 200 || true"
}

########################################
# SUB-STAGE HELPERS
########################################
cf_api() {
  local method="$1" path="$2" body="${3:-}"
  if [ -z "${CF_API_TOKEN:-}" ]; then echo "WARN: CF_API_TOKEN not set"; return 1; fi
  if [ -n "$body" ]; then
    curl -fsS -X "$method" "https://api.cloudflare.com/client/v4${path}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
      --data "$body"
  else
    curl -fsS -X "$method" "https://api.cloudflare.com/client/v4${path}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json"
  fi
}

cf_get_zone_id() {
  # Uses jq if available; falls back to sed
  local zone_json
  zone_json=$(cf_api GET "/zones?name=${DOMAIN}&per_page=1" || true)
  if command -v jq >/dev/null 2>&1; then
    echo "$zone_json" | jq -r '.result[0].id // empty'
  else
    echo "$zone_json" | sed -n 's/.*"result":\[\{"id":"\([a-f0-9]\{32\}\)".*/\1/p'
  fi
}

cf_create_firewall_bypass() {
  # Bypass WAF/BIC/Hot for a specific hostname using Firewall Rules API
  local host="$1" zid="$2"
  [ -z "$zid" ] && return 1
  local payload
  payload=$(cat <<JSON
[
  {
    "action": "bypass",
    "filter": {"expression": "(http.host eq \"${host}\")"},
    "products": ["waf","bic","hot"],
    "description": "Bypass challenge for ${host}"
  }
]
JSON
)
  cf_api POST "/zones/${zid}/firewall/rules" "$payload" >/dev/null 2>&1 || true
}

cf_create_pagerule_security_off() {
  # Set Security Level to Essentially Off for a hostname path via Page Rules API (best-effort)
  local host="$1" zid="$2"
  [ -z "$zid" ] && return 1
  local payload
  payload=$(cat <<JSON
{
  "targets": [
    {"target": "url", "constraint": {"operator": "matches", "value": "${host}/*"}}
  ],
  "actions": [
    {"id": "security_level", "value": "essentially_off"}
  ],
  "status": "active",
  "priority": 1
}
JSON
)
  cf_api POST "/zones/${zid}/pagerules" "$payload" >/dev/null 2>&1 || true
}

cf_configure_challenge_bypass() {
  local host="$1"
  if [ -z "${CF_API_TOKEN:-}" ]; then
    echo "WARN: CF_API_TOKEN not set; cannot configure Cloudflare challenge bypass for ${host}."; return 0
  fi
  say "Configuring Cloudflare challenge bypass for ${host}"
  local zid
  zid=$(cf_get_zone_id)
  if [ -z "$zid" ]; then echo "WARN: Could not resolve Cloudflare Zone ID for ${DOMAIN}"; return 0; fi
  # Try firewall bypass and page rule to minimize interactive challenges
  cf_create_firewall_bypass "$host" "$zid"
  cf_create_pagerule_security_off "$host" "$zid"
}
ensure_cluster_ready() {
  if [ ! -f "${TALOS_KUBECONFIG}" ]; then
    echo "ERROR: Talos kubeconfig missing at ${TALOS_KUBECONFIG}. Run '$0 k3s' (Talos cluster stage) first."
    exit 1
  fi
  if ! KUBECONFIG="${TALOS_KUBECONFIG}" kubectl get nodes --request-timeout=10s >/dev/null 2>&1; then
    echo "ERROR: Kubernetes API not reachable using ${TALOS_KUBECONFIG}. Check Talos cluster health."
    exit 1
  fi
}

ensure_ns() {
  local ns="$1"
  kctl "kubectl get ns ${ns} >/dev/null 2>&1 || kubectl create ns ${ns}"
}

########################################
# 1) CONTROL PLANE (Talos)
########################################
bootstrap_control_plane() {
  say "Bootstrapping Talos control-plane at ${CTRL_IP} with workers: ${WORKERS[*]:-<none>}"

  mkdir -p "${TALOS_CONFIG_DIR}"

  local cluster_name="${TALOS_CLUSTER_NAME}"
  local endpoints="${TALOS_ENDPOINTS}"

  say "Generating Talos machine configs (cluster=${cluster_name}, endpoint=https://${CTRL_IP}:6443)"
  talosctl gen config "${cluster_name}" "https://${CTRL_IP}:6443" \
    --output-dir "${TALOS_CONFIG_DIR}" \
    --install-disk "${TALOS_INSTALL_DISK}" \
    ${TALOS_EXTRA_GENCONFIG_FLAGS}

  say "Applying control-plane config to ${CTRL_IP}"
  talosctl apply-config \
    --insecure \
    --nodes "${CTRL_IP}" \
    --file "${TALOS_CONFIG_DIR}/controlplane.yaml"

  if [ "${#WORKERS[@]}" -gt 0 ]; then
    say "Applying worker config to ${WORKERS[*]}"
    for w in "${WORKERS[@]}"; do
      talosctl apply-config \
        --insecure \
        --nodes "${w}" \
        --file "${TALOS_CONFIG_DIR}/worker.yaml"
    done
  fi

  say "Bootstrapping Talos cluster (etcd + control-plane) via ${CTRL_IP}"
  talosctl bootstrap \
    --nodes "${CTRL_IP}" \
    --endpoints "${endpoints}"

  say "Fetching kubeconfig from Talos into ${TALOS_KUBECONFIG}"
  talosctl kubeconfig \
    --nodes "${CTRL_IP}" \
    --endpoints "${endpoints}" \
    "${TALOS_KUBECONFIG}"
}

########################################
# 2) WORKERS (Talos)
########################################
join_workers() {
  if [ "${#WORKERS[@]}" -eq 0 ]; then
    say "No workers defined; skipping worker join."
    return 0
  fi

  # For Talos, worker node configuration is already applied in bootstrap_control_plane()
  # via 'talosctl apply-config' with the worker.yaml. This function remains as a semantic
  # placeholder and for future extensions if needed.
  say "Talos worker configs have been applied for: ${WORKERS[*]}"
}

########################################
# 3) INFRA (minimal: NFS + basics)
########################################
install_infra() {
  INFRA_QUIET=1
  if [ "${VERBOSE:-0}" -ge 2 ]; then INFRA_QUIET=0; fi

  say "Checking cluster readiness"
  ensure_cluster_ready

  say "Ensuring local kubectl and helm"
  ensure_local_kubectl
  ensure_local_helm

  say "Adding Helm repos"
  helmctl "helm repo add nfs-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ || true"
  helmctl "helm repo update"

  say "Creating namespaces"
  ensure_ns nfs-provisioner

  say "Installing NFS dynamic provisioner"
  helmctl "helm upgrade --install nfs-subdir-external-provisioner nfs-provisioner/nfs-subdir-external-provisioner \
    -n nfs-provisioner \
    --set nfs.server='${NFS_SERVER}' \
    --set nfs.path='${NFS_PATH}' \
    --set storageClass.name='nfs-storage' \
    --set storageClass.mountOptions[0]=nfsvers=3 \
    --set storageClass.defaultClass=true"

  say "Marking nfs-storage as default StorageClass"
  while ! kctl "kubectl get sc nfs-storage >/dev/null 2>&1"; do sleep 2; done
  kctl "kubectl patch storageclass nfs-storage -p '{\"metadata\": {\"annotations\": {\"storageclass.kubernetes.io/is-default-class\": \"true\"}}}' --type=merge"

  say "Validating NFS dynamic provisioning"
  kctl "cat <<'EOF' | kubectl apply --validate=false -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-provisioning-check
  namespace: nfs-provisioner
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-storage
  resources:
    requests:
      storage: 1Mi
EOF
"
  local check_deadline phase
  check_deadline=$(( $(date +%s) + 120 ))
  while true; do
    phase="$(KUBECONFIG="${TALOS_KUBECONFIG}" kubectl -n nfs-provisioner get pvc nfs-provisioning-check -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "$phase" = "Bound" ] && break
    if [ "$(date +%s)" -ge "$check_deadline" ]; then
      echo "ERROR: NFS dynamic provisioning did not bind a test PVC within 2 minutes."
      kctl "kubectl -n nfs-provisioner describe pvc nfs-provisioning-check || true"
      kctl "kubectl -n nfs-provisioner get pods -o wide || true"
      kctl "kubectl -n nfs-provisioner logs deploy/nfs-subdir-external-provisioner --tail=200 || true"
      echo "Hint: Verify NAS export permissions for ${NFS_SERVER}:${NFS_PATH} and that nodes can 'mount -t nfs' it."
      exit 1
    fi
    sleep 3
  done
  kctl "kubectl -n nfs-provisioner delete pvc nfs-provisioning-check --ignore-not-found=true"

  INFRA_QUIET=0
  say "Skipping Vault, Argo CD, monitoring, logging, and cloudflared installation. These will be managed via GitOps (Flux) from cluster/kubernetes/."
  return 0
}

########################################
# 4) APPS (GitOps-managed placeholder)
########################################
install_apps() {
  say "Skipping direct app installation; managed via GitOps (Flux) under cluster/kubernetes/apps."
}

stage_gitops() {
  ensure_cluster_ready
  say "Installing Flux GitOps toolkit"
  setup_local_git_snapshot
  ensure_flux_cli

  # Ensure namespace
  ensure_ns flux-system

  # Apply Flux controllers locally against the Talos-managed cluster
  say "Installing Flux controllers into flux-system"
  KUBECONFIG="${TALOS_KUBECONFIG}" flux install --namespace=flux-system --network-policy=false || true

  local flux_dir rendered_sync
  flux_dir="${REPO_ROOT}/cluster/kubernetes/flux"
  rendered_sync="$(mktemp)"
  render_flux_sync "${flux_dir}/gotk-sync.yaml" "${rendered_sync}"

  kctl "kubectl apply -f '${flux_dir}/gotk-components.yaml'"
  kctl "kubectl apply -f '${rendered_sync}'"
  kctl "kubectl apply -f '${flux_dir}/apps.yaml'"

  rm -f "${rendered_sync}"

  say "Flux installed and configured to sync ./cluster/kubernetes from ${GIT_REPO}@${GIT_BRANCH}"
}

stage_postcheck() {
  set +e
  ensure_cluster_ready || true

  say "Cluster summary"
  kctl "kubectl get nodes -o wide" || true
  kctl "kubectl get pods -A | sed -n '1,120p'" || true

  say "Flux GitOps objects"
  kctl "kubectl get gitrepositories.source.toolkit.fluxcd.io -A" || true
  kctl "kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A" || true

  local nodes_ok=0 flux_ok=0 tunnel_ok=0
  if kctl "kubectl get nodes --no-headers 2>/dev/null | grep -q ' Ready '" >/dev/null 2>&1; then
    nodes_ok=1
  fi
  if kctl "kubectl -n flux-system get kustomization platform -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" >/dev/null 2>&1; then
    flux_ok=1
  elif kctl "kubectl -n flux-system get kustomization apps -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" >/dev/null 2>&1; then
    flux_ok=1
  fi
  if kctl "kubectl -n cloudflared get pods 2>/dev/null | grep -q Running" >/dev/null 2>&1; then
    tunnel_ok=1
  fi

  echo "POSTCHECK_NODES_OK=${nodes_ok}"
  echo "POSTCHECK_FLUX_OK=${flux_ok}"
  echo "POSTCHECK_TUNNEL_OK=${tunnel_ok}"
  set -e
}

########################################
# STAGE WRAPPERS (for consistent banners)
########################################
run_stage_precheck() {
  stage_start precheck
  ensure_host_tools
  say_config
  check_connectivity
  stage_end precheck
}

run_stage_diagnose() {
  stage_start diagnose
  ensure_host_tools
  say_config
  check_connectivity
  diagnose_cluster
  stage_end diagnose
}

run_stage_k3s() {
  stage_start k3s
  ensure_host_tools
  say_config
  wipe_known_hosts
  bootstrap_control_plane
  join_workers
  wait_nodes_ready
  stage_end k3s
}

run_stage_infra() {
  stage_start infra
  ensure_host_tools
  install_infra
  stage_end infra
}

run_stage_apps() {
  stage_start apps
  ensure_host_tools
  stage_gitops
  stage_end apps
}

run_stage_postcheck() {
  stage_start postcheck
  ensure_host_tools
  stage_postcheck
  stage_end postcheck
}
########################################
# MAIN — staged execution
########################################
# After parsing -v flags, the next argument is the stage
stage="${1:-all}"

say "Starting stage: $stage"

case "$stage" in
  precheck)
    run_stage_precheck
    ;;
  preflight)
    run_stage_precheck
    ;;
  diagnose)
    run_stage_diagnose
    ;;
  k3s)
    run_stage_k3s
    ;;
  cluster)
    run_stage_k3s
    ;;
  infra)
    run_stage_infra
    ;;
  apps)
    run_stage_apps
    ;;
  gitops)
    run_stage_apps
    ;;
  postcheck)
    run_stage_postcheck
    ;;
  all)
    run_stage_precheck
    run_stage_k3s
    run_stage_infra
    run_stage_apps
    run_stage_postcheck
    ;;
  *)
    echo "Usage: $0 [-v|-vv|-vvv|--verbose N] [precheck|preflight|diagnose|k3s|cluster|infra|apps|postcheck|all]  (default: all)"
    exit 1
    ;;
esac

say_lines="Done 🎉 Stage: $stage\n- Control plane: $CTRL_IP\n- Workers: ${WORKERS[*]}\n- GitOps source: ${GIT_REPO}@${GIT_BRANCH}\n- Check Flux with:\n    kubectl get gitrepositories.source.toolkit.fluxcd.io -A\n    kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A\n"
say "$say_lines"
