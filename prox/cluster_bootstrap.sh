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
  ensure_known_hosts
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

# Run a command on control-plane with kubeconfig set
kctl() {
  # Ensure KUBECONFIG is exported in the remote shell before executing arbitrary commands
  # This allows shell constructs like 'if', 'for', and pipelines to work reliably, and
  # ensures child processes (kubectl) receive the env var.
  if [ "${INFRA_QUIET:-0}" = "1" ] && [[ "$*" != *"<<"* ]]; then
    ssh_do "$CTRL_IP" "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; $* 1>/dev/null"
  else
    ssh_do "$CTRL_IP" "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; $*"
  fi
}

helmctl() {
  if [ "${INFRA_QUIET:-0}" = "1" ] && [[ "$*" != *"<<"* ]]; then
    ssh_do "$CTRL_IP" "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; $* 1>/dev/null"
  else
    ssh_do "$CTRL_IP" "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; $*"
  fi
}

wait_nodes_ready() {
  # Ensure kubectl is available on the controller before API checks
  ssh_do "$CTRL_IP" "command -v kubectl >/dev/null 2>&1 || sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl"
  local deadline=$(( $(date +%s) + READY_TIMEOUT_SECS ))
  while true; do
    if kctl "kubectl get nodes 2>/dev/null | grep -q ' Ready ' && test \$(kubectl get nodes --no-headers | wc -l) -ge $((1 + ${#WORKERS[@]}))"; then
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
  ssh_do "$CTRL_IP" "command -v kubectl >/dev/null 2>&1 || sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl"
  if ! ssh_do "$CTRL_IP" "systemctl is-active --quiet k3s"; then
    echo "ERROR: k3s server is not running on $CTRL_IP. Run '$0 k3s' or '$0 all' first."; exit 1; fi
  if ! ssh_do "$CTRL_IP" "test -f /etc/rancher/k3s/k3s.yaml"; then
    echo "ERROR: kubeconfig missing on $CTRL_IP at /etc/rancher/k3s/k3s.yaml. Run '$0 k3s' first."; exit 1; fi
  if ! kctl "kubectl get nodes --request-timeout=10s >/dev/null 2>&1"; then
    if ! ssh_do "$CTRL_IP" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/k3s kubectl get nodes --request-timeout=10s >/dev/null 2>&1"; then
      echo "ERROR: Kubernetes API on $CTRL_IP:6443 not reachable. Check k3s health."; exit 1; fi
  fi
}

ensure_ns() {
  local ns="$1"
  kctl "kubectl get ns ${ns} >/dev/null 2>&1 || kubectl create ns ${ns}"
}

########################################
# 1) CONTROL PLANE
########################################
bootstrap_control_plane() {
  say "Preparing control-plane ($CTRL_IP)"
  ssh_do "$CTRL_IP" "sudo -n true" 2>/dev/null || { echo "ERROR: cannot sudo on $CTRL_IP"; exit 1; }
  ensure_prereqs_node "$CTRL_IP"

  if ssh_do "$CTRL_IP" "systemctl is-active --quiet k3s"; then
    say "k3s server already running on $CTRL_IP"
  else
    say "Installing k3s server on $CTRL_IP"
    ssh_do "$CTRL_IP" "curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644 --with-node-id"
  fi

  # Ensure kubectl, jq, helm
  ssh_do "$CTRL_IP" "command -v kubectl >/dev/null 2>&1 || sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl"
  ssh_do "$CTRL_IP" "command -v jq >/dev/null 2>&1 || (sudo apt-get update -y && sudo apt-get install -y jq)"
  ssh_do "$CTRL_IP" "command -v helm >/dev/null 2>&1 || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo -E bash -s -"

  say "Waiting for control-plane node to be Ready"
  local s_deadline=$(( $(date +%s) + 120 ))
  while ! kctl "kubectl get nodes 2>/dev/null | grep -q ' Ready '"; do
    [ "$(date +%s)" -ge "$s_deadline" ] && break
    sleep 3
  done
  kctl "kubectl get nodes -o wide || true"
}

########################################
# 2) WORKERS
########################################
join_workers() {
  say "Joining workers: ${WORKERS[*]}"
  local token
  token="$(ssh_do "$CTRL_IP" "sudo cat /var/lib/rancher/k3s/server/node-token")"

  for w in "${WORKERS[@]}"; do
    say "Configuring worker $w"
    ensure_prereqs_node "$w"

    if ssh_do "$w" "systemctl is-active --quiet k3s-agent"; then
      say "Resetting existing k3s agent on $w before re-joining"
      ssh_do "$w" "sudo systemctl stop k3s-agent; sudo /usr/local/bin/k3s-agent-uninstall.sh || true; sudo rm -rf /etc/rancher/k3s /var/lib/rancher/k3s"
    fi
    ssh_do "$w" "curl -sfL https://get.k3s.io | sudo K3S_URL='https://$CTRL_IP:6443' K3S_TOKEN='$token' K3S_NODE_IP='$w' sh -s - agent --with-node-id"

    local join_deadline=$(( $(date +%s) + JOIN_TIMEOUT_SECS ))
    while true; do
      if kctl "kubectl get nodes -o wide 2>/dev/null | grep -E \"\b$w\b\" | grep -q ' Ready '"; then
        say "Worker $w is Ready"
        break
      fi
      if [ "$(date +%s)" -ge "$join_deadline" ]; then
        echo "ERROR: Timeout waiting for worker $w"
        ssh_do "$w" "sudo journalctl -u k3s-agent -n 200 --no-pager || true"
        exit 1
      fi
      sleep 5
    done
  done
  kctl "kubectl get nodes -o wide"
}

########################################
# 3) INFRA (minimal: NFS + basics)
########################################
install_infra() {
  INFRA_QUIET=1
  if [ "${VERBOSE:-0}" -ge 2 ]; then INFRA_QUIET=0; fi

  say "Checking cluster readiness"
  ensure_cluster_ready

  say "Ensuring tools on controller"
  ssh_do "$CTRL_IP" "command -v kubectl >/dev/null 2>&1 || sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl"
  ssh_do "$CTRL_IP" "command -v jq >/dev/null 2>&1 || (sudo apt-get update -y && sudo apt-get install -y jq)"
  ssh_do "$CTRL_IP" "command -v helm >/dev/null 2>&1 || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo -E bash -s -"

  say "Adding Helm repos"
  helmctl "helm repo add nfs-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ || true"
  helmctl "helm repo update"

  say "Creating namespaces"
  ensure_ns nfs-provisioner

  say "Ensuring NFS client tools on all nodes"
  ssh_do "$CTRL_IP" "command -v mount.nfs >/dev/null 2>&1 || (sudo apt-get update -y && sudo apt-get install -y nfs-common)"
  for w in "${WORKERS[@]}"; do
    ssh_do "$w" "command -v mount.nfs >/dev/null 2>&1 || (sudo apt-get update -y && sudo apt-get install -y nfs-common)"
  done

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
    phase="$(ssh_do "$CTRL_IP" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n nfs-provisioner get pvc nfs-provisioning-check -o jsonpath='{.status.phase}' 2>/dev/null || true")"
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
  say "Skipping Vault, Argo CD, monitoring, logging, and cloudflared installation. These will be managed via GitOps (Flux) from the infra/ directory."
  return 0
}

########################################
# 4) APPS (GitOps-managed placeholder)
########################################
install_apps() {
  say "Skipping direct app installation; managed via GitOps (Flux) under infra/."
}

stage_gitops() {
  ensure_cluster_ready
  say "Installing Flux GitOps toolkit"
  setup_local_git_snapshot

  # Ensure flux CLI on controller
  ssh_do "$CTRL_IP" "command -v flux >/dev/null 2>&1 || curl -s https://fluxcd.io/install.sh | sudo bash"

  # Ensure namespace
  ensure_ns flux-system

  # Apply Flux controllers
  ssh_do "$CTRL_IP" "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; flux install --namespace=flux-system --network-policy=false || true"

  # GitRepository for this repo
  kctl "cat <<EOF | kubectl apply -f -
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: homelab-repo
  namespace: flux-system
spec:
  interval: 1m0s
  url: ${GIT_REPO}
  ref:
    branch: ${GIT_BRANCH}
EOF
"

  # Kustomization to sync infra/
  kctl "cat <<EOF | kubectl apply -f -
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: homelab-infra
  namespace: flux-system
spec:
  interval: 1m0s
  path: ./infra
  prune: true
  sourceRef:
    kind: GitRepository
    name: homelab-repo
  timeout: 5m0s
  wait: true
EOF
"

  say "Flux installed and configured to sync ./infra from ${GIT_REPO}@${GIT_BRANCH}"
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
  if kctl "kubectl -n flux-system get kustomization homelab-infra -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" >/dev/null 2>&1; then
    flux_ok=1
  fi
  if kctl "kubectl -n tunnel get pods 2>/dev/null | grep -q Running" >/dev/null 2>&1; then
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
