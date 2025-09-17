#!/usr/bin/env bash
set -euo pipefail 

########################################
# CONFIG
########################################
CTRL_IP="${CTRL_IP:-192.168.1.151}"
WORKERS=("${WORKER1:-192.168.1.152}" "${WORKER2:-192.168.1.153}")

# SSH config (override via env: SSH_USER, SSH_PASS, SSH_PORT)
SSH_USER="${SSH_USER:-kyle}"
SSH_PASS="${SSH_PASS:-root}"
SSH_PORT="${SSH_PORT:-22}"

DOMAIN="funoffshore.com"
LE_EMAIL="${LE_EMAIL:-kyledprycejones@gmail.com}"

# NFS
NFS_SERVER="${NFS_SERVER:-192.168.1.112}"
NFS_PATH="${NFS_PATH:-/volume1/fire_share2}"

# GitOps
GIT_REPO="${GIT_REPO:-https://github.com/kyledprycejones/homelab}"
# Use the default repo branch unless overridden
GIT_BRANCH="${GIT_BRANCH:-main}"

# Cloudflare tunnel
CF_REPLICAS=${CF_REPLICAS:-2}

# Timeouts
READY_TIMEOUT_SECS=${READY_TIMEOUT_SECS:-600}
JOIN_TIMEOUT_SECS=${JOIN_TIMEOUT_SECS:-300}

# Feature toggles (defaults: disabled)
# Set to 1 to enable during install_infra stage
ENABLE_MONITORING=${ENABLE_MONITORING:-0}
ENABLE_LOGGING=${ENABLE_LOGGING:-0}
# Prefer Cloudflare Origin CA for origin TLS (default: on)
USE_ORIGIN_CA=${USE_ORIGIN_CA:-1}
# Install cert-manager (needed only if using ACME/LE). Default off when using Origin CA
ENABLE_CERT_MANAGER=${ENABLE_CERT_MANAGER:-0}

# Debug: set DEBUG=1 for trace
if [ "${DEBUG:-0}" = "1" ]; then set -x; fi

########################################
# OPTIONAL SECRETS (env)
# If unset, Cloudflare-related pieces (DNS01 + tunnel) are skipped
########################################
CF_API_TOKEN="${CF_API_TOKEN:-b1iakg9ercyKYKPPRTyC27Cq7DOi7uNxXho4rXbA}" 
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-eyJhIjoiZjAzMTkyMjA5MmUwNDc0MWU2OTJkYjA5ZjYyZTlhYjAiLCJ0IjoiYTM1OTE3NjQtZjlkOC00ODA0LTk1OWUtYmM3ZjNjYTczZjE3IiwicyI6Ik5UY3dORFEzTkdVdE5qYzBOQzAwTW1JNUxXSXpOakF0WWpjNU56Y3hOVE0yTm1SaiJ9}" 
# Optional: Cloudflare Origin CA key (used to issue origin certificates via Cloudflare)
CF_ORIGIN_CA_KEY="${CF_ORIGIN_CA_KEY:-v1.0-ddd66443ad024815912b9276-6bb8ea9e61f4f1040045e99b73b639e3e7b72e82cc4db470290d4171b1f3f3a8f695c3783e45275b6f08a31df058a109270a36f74aa5d30c6df0f6014c01f4c7e44315228b09e95cb2}"

# Cloudflare challenge handling
# Set to 1 to attempt configuring Cloudflare to skip interactive challenges
# for argocd.$DOMAIN via API (firewall bypass + page rule security level).
# Requires CF_API_TOKEN with permissions for the zone.
CF_BYPASS_CHALLENGE=${CF_BYPASS_CHALLENGE:-1}

########################################
# HELPERS
########################################
say(){ echo -e "\n== $* =="; }

# Print effective config (masking secrets)
say_config() {
  local cf_api_masked cf_tunnel_masked origin_ca_masked pass_masked
  cf_api_masked="${CF_API_TOKEN:0:4}***${CF_API_TOKEN:+${CF_API_TOKEN: -4}}"
  cf_tunnel_masked="${CF_TUNNEL_TOKEN:0:4}***${CF_TUNNEL_TOKEN:+${CF_TUNNEL_TOKEN: -4}}"
  origin_ca_masked="${CF_ORIGIN_CA_KEY:0:6}***${CF_ORIGIN_CA_KEY:+${CF_ORIGIN_CA_KEY: -4}}"
  pass_masked="${SSH_PASS:+*****}"
  echo "Config: CTRL_IP=$CTRL_IP SSH_USER=$SSH_USER SSH_PORT=$SSH_PORT PASS=$pass_masked WORKERS=${WORKERS[*]} DOMAIN=$DOMAIN GIT_BRANCH=$GIT_BRANCH"
  echo "Cloudflare: API=$cf_api_masked TUNNEL=$cf_tunnel_masked ORIGIN_CA=$origin_ca_masked BYPASS=$CF_BYPASS_CHALLENGE"
}

ensure_host_tools() {
  if ! command -v sshpass >/dev/null 2>&1; then
    say "Installing sshpass on host"
    apt-get update -y && apt-get install -y sshpass
  fi
  # Ensure curl and jq are available for Cloudflare API calls (best-effort)
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y curl jq || true
  fi
  # nc for connectivity checks
  if ! command -v nc >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y netcat-openbsd || true
  fi
  ensure_known_hosts
}

# Preload SSH known_hosts for controller and workers to avoid repeated warnings
ensure_known_hosts() {
  # Use the invoking user's home (works on non-root hosts like macOS dev machines)
  local home_dir="${HOME:-/root}"
  local kh="$home_dir/.ssh/known_hosts"
  mkdir -p "$home_dir/.ssh" && chmod 700 "$home_dir/.ssh"
  touch "$kh" && chmod 600 "$kh"
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
    ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR \
    "${SSH_USER}@${host}" "$@"
}

scp_to() {
  local src="$1" host="$2" dst="$3"
  SSHPASS="$SSH_PASS" sshpass -e \
    scp -q -P "${SSH_PORT}" -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR \
    "$src" "${SSH_USER}@${host}:${dst}"
}

wipe_known_hosts() {
  for ip in "$CTRL_IP" "${WORKERS[@]}"; do
    ssh-keygen -f "/root/.ssh/known_hosts" -R "$ip" >/dev/null 2>&1 || true
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
    printf "- %s: " "$h"
    if command -v nc >/dev/null 2>&1 && ! nc -z -w 2 "$h" "$SSH_PORT" 2>/dev/null; then
      echo "port ${SSH_PORT} closed"; continue
    fi
    if SSHPASS="$SSH_PASS" sshpass -e ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=4 -o LogLevel=ERROR "${SSH_USER}@${h}" 'echo ok' 2>/dev/null | grep -q '^ok$'; then
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

# Standalone stages to run specific parts of infra/apps
stage_cloudflare() {
  ensure_cluster_ready
  if [ -z "${CF_TUNNEL_TOKEN:-}" ]; then
    echo "WARN: CF_TUNNEL_TOKEN not set; cannot deploy cloudflared."; return 0; fi
  ensure_ns tunnel
  say "Deploying cloudflared (${CF_REPLICAS} replicas) in token mode"
  kctl "kubectl -n tunnel apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflared-token
  namespace: tunnel
stringData:
  TUNNEL_TOKEN: ${CF_TUNNEL_TOKEN}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: tunnel
  labels: { app: cloudflared }
spec:
  replicas: ${CF_REPLICAS}
  selector:
    matchLabels: { app: cloudflared }
  template:
    metadata:
      labels: { app: cloudflared }
    spec:
      containers:
      - name: cloudflared
        image: cloudflare/cloudflared:latest
        command: [\"cloudflared\"]
        args: [\"tunnel\",\"run\"]
        env:
          - name: TUNNEL_TOKEN
            valueFrom:
              secretKeyRef:
                name: cloudflared-token
                key: TUNNEL_TOKEN
EOF
"
  kctl "kubectl -n tunnel rollout status deploy/cloudflared --timeout=5m || true"
  # Reminder tailored to enabled stacks
  local cf_extra=""
  if [ "${ENABLE_MONITORING:-0}" -eq 1 ]; then cf_extra=", grafana.${DOMAIN}, prometheus.${DOMAIN}"; fi
  say "Reminder: add Public Hostnames in Cloudflare for argocd.${DOMAIN}${cf_extra}"
}

stage_argocd() {
  ensure_cluster_ready
  dns_preflight_host
  say "Installing Argo CD + AVP"
  kctl "cat >/tmp/argocd-values.yaml <<'EOF'
repoServer:
  # Force known-good public resolvers to avoid upstream DNS issues on cluster
  dnsPolicy: None
  dnsConfig:
    nameservers:
      - 1.1.1.1
      - 8.8.8.8
  env:
    - name: AVP_TYPE
      value: vault
    - name: VAULT_ADDR
      value: http://vault.vault.svc:8200
    - name: AVP_AUTH_TYPE
      value: kubernetes
    - name: AVP_K8S_ROLE
      value: argocd-repo
  initContainers:
    - name: avp-download
      image: ghcr.io/argoproj-labs/argocd-vault-plugin:v1.18.0
      command: [\"/bin/sh\",\"-c\"]
      args:
        - set -eu; \\
          cp /usr/local/bin/argocd-vault-plugin /custom-tools/avp; \\
          chmod +x /custom-tools/avp
      volumeMounts:
        - name: custom-tools
          mountPath: /custom-tools
  volumes:
    - name: custom-tools
      emptyDir: {}
  volumeMounts:
    - name: custom-tools
      mountPath: /usr/local/bin/argocd-vault-plugin
      subPath: avp
server:
  extraArgs: [\"--insecure\"]
EOF"
  helmctl "helm upgrade --install argocd argo/argo-cd -n argocd -f /tmp/argocd-values.yaml --timeout 15m --wait --wait-for-jobs || true"
  # Safeguard: ensure repo-server copyutil init has correct image/command and var-files mount (strategic merge by name)
  kctl "bash -lc 'set -e
    ns=argocd; dep=argocd-repo-server
    # Wait a moment for Deployment to exist
    for i in 1 2 3 4 5; do kubectl -n \"$ns\" get deploy \"$dep\" >/dev/null 2>&1 && break || sleep 2; done
    cat >/tmp/rs-copyutil-merge.json <<EOF
{ "spec": { "template": { "spec": { "initContainers": [ {
  "name": "copyutil",
  "image": "quay.io/argoproj/argocd:v3.1.1",
  "command": ["/bin/cp","-n","/usr/local/bin/argocd","/var/run/argocd/argocd-cmp-server"],
  "args": [],
  "volumeMounts": [ { "name": "var-files", "mountPath": "/var/run/argocd" } ]
} ] } } } }
EOF
    kubectl -n \"$ns\" patch deploy \"$dep\" --type merge --patch-file /tmp/rs-copyutil-merge.json || true
  '"
  # Optional: configure Vault policy/role if Vault exists and bootstrap file present
  VAULT_POD="$(ssh_do "$CTRL_IP" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n vault get pod -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true")"
  ROOT_TOKEN="$(ssh_do "$CTRL_IP" "sudo jq -r .root_token /root/vault-bootstrap.json" 2>/dev/null || true)"
  if [ -n "$VAULT_POD" ] && [ -n "$ROOT_TOKEN" ]; then
    kctl "kubectl -n vault exec '${VAULT_POD}' -- sh -c '
      export VAULT_ADDR=http://127.0.0.1:8200
      export VAULT_TOKEN='"'"'${ROOT_TOKEN}'"'"'
      vault policy write argocd-read - <<POL
path \"kv/data/homelab/*\" { capabilities = [\"read\"] }
POL
      vault write auth/kubernetes/role/argocd-repo \\
        bound_service_account_names=argocd-repo-server \\
        bound_service_account_namespaces=argocd \\
        policies=argocd-read
    '"
  fi
}

# Network: Ingresses for entry via Traefik (k3s default)
stage_network() {
  ensure_cluster_ready
  say "Configuring Ingress for Argo CD (Traefik)"
  # Create an Ingress for argocd.${DOMAIN} pointing to argocd-server:80.
  # If TLS secret exists, enable HTTPS on Traefik; otherwise expose HTTP only.
  if kctl "kubectl -n argocd get secret argocd-server-tls >/dev/null 2>&1"; then
    kctl "cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
    traefik.ingress.kubernetes.io/router.tls: \"true\"
spec:
  ingressClassName: traefik
  rules:
  - host: argocd.${DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
  tls:
  - hosts: [\"argocd.${DOMAIN}\"]
    secretName: argocd-server-tls
EOF"
  else
    kctl "cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
  - host: argocd.${DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
EOF"
  fi

  say "Ingress created. If using Cloudflare Tunnel: set Public Hostname argocd.${DOMAIN} origin to HTTPS https://traefik.kube-system.svc.cluster.local:443 when argocd-server-tls exists, otherwise use HTTP http://traefik.kube-system.svc.cluster.local:80. HTTP Host Header: argocd.${DOMAIN}." 

  # Optional Ingresses for monitoring stack
  if [ "${ENABLE_MONITORING:-0}" -eq 1 ]; then
    say "Configuring Ingress for Grafana (Traefik)"
    kctl "bash -lc 'set -e\nns=monitoring; host=grafana.${DOMAIN}\nif kubectl -n \"$ns\" get secret grafana-tls >/dev/null 2>&1; then\ncat <<EOF | kubectl apply -f -\napiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n  name: grafana\n  namespace: \$ns\n  annotations:\n    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure\n    traefik.ingress.kubernetes.io/router.tls: \"true\"\nspec:\n  ingressClassName: traefik\n  rules:\n  - host: \$host\n    http:\n      paths:\n      - path: /\n        pathType: Prefix\n        backend:\n          service:\n            name: monitoring-grafana\n            port:\n              number: 80\n  tls:\n  - hosts: [\"\$host\"]\n    secretName: grafana-tls\nEOF\nelse\ncat <<EOF | kubectl apply -f -\napiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n  name: grafana\n  namespace: \$ns\n  annotations:\n    traefik.ingress.kubernetes.io/router.entrypoints: web\nspec:\n  ingressClassName: traefik\n  rules:\n  - host: \$host\n    http:\n      paths:\n      - path: /\n        pathType: Prefix\n        backend:\n          service:\n            name: monitoring-grafana\n            port:\n              number: 80\nEOF\nfi'"

    say "Configuring Ingress for Prometheus (Traefik)"
    kctl "bash -lc 'set -e\nns=monitoring; host=prometheus.${DOMAIN}\nif kubectl -n \"$ns\" get secret prometheus-tls >/dev/null 2>&1; then\ncat <<EOF | kubectl apply -f -\napiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n  name: prometheus\n  namespace: \$ns\n  annotations:\n    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure\n    traefik.ingress.kubernetes.io/router.tls: \"true\"\nspec:\n  ingressClassName: traefik\n  rules:\n  - host: \$host\n    http:\n      paths:\n      - path: /\n        pathType: Prefix\n        backend:\n          service:\n            name: monitoring-kube-prometheus-stack-prometheus\n            port:\n              number: 9090\n  tls:\n  - hosts: [\"\$host\"]\n    secretName: prometheus-tls\nEOF\nelse\ncat <<EOF | kubectl apply -f -\napiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n  name: prometheus\n  namespace: \$ns\n  annotations:\n    traefik.ingress.kubernetes.io/router.entrypoints: web\nspec:\n  ingressClassName: traefik\n  rules:\n  - host: \$host\n    http:\n      paths:\n      - path: /\n        pathType: Prefix\n        backend:\n          service:\n            name: monitoring-kube-prometheus-stack-prometheus\n            port:\n              number: 9090\nEOF\nfi'"
  fi

  # Optionally configure Cloudflare to bypass interactive challenges for this hostname
  if [ "${CF_BYPASS_CHALLENGE}" = "1" ]; then
    cf_configure_challenge_bypass "argocd.${DOMAIN}" || true
  fi
}

stage_storage() {
  ensure_cluster_ready; ensure_ns nfs-provisioner
  say "Installing NFS dynamic provisioner"
  helmctl "helm upgrade --install nfs-subdir-external-provisioner nfs-provisioner/nfs-subdir-external-provisioner -n nfs-provisioner --set nfs.server='${NFS_SERVER}' --set nfs.path='${NFS_PATH}' --set storageClass.name='nfs-storage' --set storageClass.mountOptions[0]=nfsvers=3 --set storageClass.defaultClass=true"
}

stage_cert() {
  ensure_cluster_ready; ensure_ns cert-manager
  say "Installing cert-manager"
  helmctl "helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --set crds.enabled=true --timeout 10m --wait || true"
}

stage_vault() {
  ensure_cluster_ready; ensure_ns vault
  say "Installing Vault"
  kctl "cat >/tmp/vault-values.yaml <<'EOF'
server:
  ha:
    enabled: false
  dataStorage:
    enabled: true
    size: 5Gi
    storageClass: nfs-storage
    accessModes: [ReadWriteOnce]
  affinity: null
  nodeSelector: {}
  tolerations:
    - operator: Exists
ui:
  enabled: true
resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits: { cpu: 500m, memory: 512Mi }
EOF"
  helmctl "helm upgrade --install vault hashicorp/vault -n vault -f /tmp/vault-values.yaml --force || true"
}

stage_monitoring() { ensure_cluster_ready; ensure_ns monitoring; say "Installing kube-prometheus-stack"; helmctl "helm upgrade --install monitoring prometheus-community/kube-prometheus-stack -n monitoring --set grafana.adminPassword=admin --timeout 15m --wait --wait-for-jobs || true"; }
stage_logging() { ensure_cluster_ready; ensure_ns logging; say "Installing Loki + Promtail"; helmctl "helm upgrade --install logging grafana/loki-stack -n logging --set grafana.enabled=false --set promtail.enabled=true --timeout 10m --wait --wait-for-jobs || true"; }
stage_tailscale() { ensure_cluster_ready; say "Installing Tailscale operator"; helmctl "helm repo add tailscale https://pkgs.tailscale.com/helmcharts >/dev/null 2>&1 || true"; helmctl "helm repo update >/dev/null 2>&1 || true"; helmctl "helm upgrade --install tailscale-operator tailscale/tailscale-operator -n tailscale-system --create-namespace || true"; }

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
# 3) INFRA (cert-manager, NFS, Vault, Argo CD + AVP, monitoring, logging, cloudflared)
########################################
install_infra() {
  # Determine if Cloudflare-dependent steps should run
  local SKIP_CF=0
  if [ -z "${CF_API_TOKEN:-}" ] || [ -z "${CF_TUNNEL_TOKEN:-}" ]; then
    echo "WARN: CF_API_TOKEN and/or CF_TUNNEL_TOKEN not set; skipping Cloudflare DNS01 and tunnel deploy."
    SKIP_CF=1
  fi
  # Reduce verbosity: only print failures from kubectl/helm in this stage
  INFRA_QUIET=1
  say "Checking cluster readiness"
  # Ensure kubectl exists before API checks (token installs may not have it yet)
  ssh_do "$CTRL_IP" "command -v kubectl >/dev/null 2>&1 || sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl"
  # Ensure k3s server is running on the control-plane and kubeconfig exists
  if ! ssh_do "$CTRL_IP" "systemctl is-active --quiet k3s"; then
    echo "ERROR: k3s server is not running on $CTRL_IP. Run '$0 k3s' or '$0 all' first."
    exit 1
  fi
  if ! ssh_do "$CTRL_IP" "test -f /etc/rancher/k3s/k3s.yaml"; then
    echo "ERROR: kubeconfig missing on $CTRL_IP at /etc/rancher/k3s/k3s.yaml. Run '$0 k3s' first."
    exit 1
  fi
  # Quick API check (short timeout to avoid hanging)
  if ! kctl "kubectl get nodes --request-timeout=10s >/dev/null 2>&1"; then
    # Fallback to k3s embedded kubectl in case PATH/symlink is odd
    if ! ssh_do "$CTRL_IP" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/k3s kubectl get nodes --request-timeout=10s >/dev/null 2>&1"; then
      echo "ERROR: Kubernetes API on $CTRL_IP:6443 not reachable. k3s appears running but API check failed."
      echo "Hint: Try 'ssh $SSH_USER@$CTRL_IP \"KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes -o wide\"' and check 'journalctl -u k3s'."
      exit 1
    fi
  fi

  say "Adding Helm repos"
  # Ensure tools exist even when running only the 'infra' stage
  ssh_do "$CTRL_IP" "command -v kubectl >/dev/null 2>&1 || sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl"
  ssh_do "$CTRL_IP" "command -v jq >/dev/null 2>&1 || (sudo apt-get update -y && sudo apt-get install -y jq)"
  ssh_do "$CTRL_IP" "command -v helm >/dev/null 2>&1 || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo -E bash -s -"
  helmctl "helm version --short || true"
  say "Adding repo: jetstack"
  helmctl "helm repo add jetstack https://charts.jetstack.io || true"
  say "Adding repo: argo"
  helmctl "helm repo add argo https://argoproj.github.io/argo-helm || true"
  say "Adding repo: hashicorp"
  helmctl "helm repo add hashicorp https://helm.releases.hashicorp.com || true"
  say "Adding repo: prometheus-community"
  helmctl "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true"
  say "Adding repo: grafana"
  helmctl "helm repo add grafana https://grafana.github.io/helm-charts || true"
  say "Adding repo: nfs-provisioner"
  helmctl "helm repo add nfs-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ || true"
  say "Updating Helm repos"
  helmctl "helm repo update"

  say "Creating namespaces"
  for ns in cert-manager argocd vault tunnel nfs-provisioner monitoring logging; do
    kctl "kubectl get ns $ns >/dev/null 2>&1 || kubectl create ns $ns"
  done

  # Ensure cloudflared comes up early if tokens are provided, so later Helm hooks don't block tunnel setup
  if [ "$SKIP_CF" -eq 0 ]; then
    say "Ensuring cloudflared is deployed (early)"
    # Only apply if not already present
    if ! kctl "kubectl -n tunnel get deploy/cloudflared >/dev/null 2>&1"; then
      kctl "kubectl -n tunnel apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflared-token
  namespace: tunnel
stringData:
  TUNNEL_TOKEN: ${CF_TUNNEL_TOKEN}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: tunnel
  labels: { app: cloudflared }
spec:
  replicas: ${CF_REPLICAS}
  selector:
    matchLabels: { app: cloudflared }
  template:
    metadata:
      labels: { app: cloudflared }
    spec:
      containers:
      - name: cloudflared
        image: cloudflare/cloudflared:latest
        command: [\"/bin/sh\",\"-c\"]
        args: [\"exec cloudflared tunnel run --token \$TUNNEL_TOKEN\"]
        env:
          - name: TUNNEL_TOKEN
            valueFrom:
              secretKeyRef:
                name: cloudflared-token
                key: TUNNEL_TOKEN
EOF
"
      # Best-effort wait so connectors register
      kctl "kubectl -n tunnel rollout status deploy/cloudflared --timeout=3m || true"
    fi
  fi

  # Ensure NFS client tools exist on all nodes (for dynamic provisioning)
  say "Ensuring NFS client on all nodes"
  ssh_do "$CTRL_IP" "command -v mount.nfs >/dev/null 2>&1 || (sudo apt-get update -y && sudo apt-get install -y nfs-common)"
  for w in "${WORKERS[@]}"; do
    ssh_do "$w" "command -v mount.nfs >/dev/null 2>&1 || (sudo apt-get update -y && sudo apt-get install -y nfs-common)"
  done

  # NFS provisioner (default SC)
  say "Installing NFS dynamic provisioner"
  helmctl "helm upgrade --install nfs-subdir-external-provisioner nfs-provisioner/nfs-subdir-external-provisioner \
    -n nfs-provisioner \
    --set nfs.server='${NFS_SERVER}' \
    --set nfs.path='${NFS_PATH}' \
    --set storageClass.name='nfs-storage' \
    --set storageClass.mountOptions[0]=nfsvers=3 \
    --set storageClass.defaultClass=true"

  # Ensure nfs-storage is default (idempotent)
  # Wait until the StorageClass exists to avoid race on first install
  while ! kctl "kubectl get sc nfs-storage >/dev/null 2>&1"; do sleep 2; done
  kctl "kubectl get sc nfs-storage -o json | jq '.metadata.annotations[\"storageclass.kubernetes.io/is-default-class\"]=\"true\"' | kubectl apply -f -"

  # Validate dynamic provisioning with a short-lived test PVC before deploying Vault
  say "Validating NFS dynamic provisioning"
  kctl "cat <<'EOF' | kubectl apply --validate=false -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-provisioning-check
  namespace: vault
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-storage
  resources:
    requests:
      storage: 1Mi
EOF
"
  # Wait up to 2 minutes for Bound
  check_deadline=$(( $(date +%s) + 120 ))
  while true; do
    phase="$(ssh_do "$CTRL_IP" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n vault get pvc nfs-provisioning-check -o jsonpath='{.status.phase}' 2>/dev/null || true")"
    [ "$phase" = "Bound" ] && break
    if [ "$(date +%s)" -ge "$check_deadline" ]; then
      echo "ERROR: NFS dynamic provisioning did not bind a test PVC within 2 minutes."
      kctl "kubectl -n vault describe pvc nfs-provisioning-check || true"
      kctl "kubectl -n nfs-provisioner get pods -o wide || true"
      kctl "kubectl -n nfs-provisioner logs deploy/nfs-subdir-external-provisioner --tail=200 || true"
      echo "Hint: Verify NAS export permissions for ${NFS_SERVER}:${NFS_PATH} and that nodes can 'mount -t nfs' it."
      exit 1
    fi
    sleep 3
  done
  # Clean up the test PVC (the provisioned PV will be deleted by the provisioner)
  kctl "kubectl -n vault delete pvc nfs-provisioning-check --ignore-not-found=true"

  # cert-manager (optional; disabled when using Origin CA)
  if [ "${ENABLE_CERT_MANAGER:-0}" -eq 1 ]; then
    say "Installing cert-manager"
    helmctl "helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --set crds.enabled=true || true"
    # Wait for CRDs to register before applying resources
    while ! kctl "kubectl get crd clusterissuers.cert-manager.io >/dev/null 2>&1"; do sleep 2; done
    # And wait for core deployments to be ready (best-effort)
    kctl "kubectl -n cert-manager rollout status deploy/cert-manager --timeout=5m || true"
    kctl "kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=5m || true"
    kctl "kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=5m || true"
  else
    say "Skipping cert-manager install (ENABLE_CERT_MANAGER=0)"
  fi

  if [ "$SKIP_CF" -eq 0 ]; then
    if [ "${USE_ORIGIN_CA:-1}" -eq 1 ] && [ -n "${CF_ORIGIN_CA_KEY:-}" ]; then
      say "Minting Cloudflare Origin CA certificate for argocd.${DOMAIN}"
      kctl "bash -lc '
        set -e
        ns=argocd; host=argocd.${DOMAIN}
        resp=\$(curl -sS -X POST https://api.cloudflare.com/client/v4/certificates \\
          -H \"X-Auth-User-Service-Key: ${CF_ORIGIN_CA_KEY}\" \\
          -H \"Content-Type: application/json\" \\
          --data-raw \"{\\\"hostnames\\\":[\\\"$host\\\"],\\\"request_type\\\":\\\"origin-rsa\\\",\\\"requested_validity\\\":5475}\")
        ok=\$(printf %s \"\$resp\" | jq -r .success)
        [ \"$ok\" = \"true\" ] || { echo \"Cloudflare Origin CA API error:\n\$resp\" >&2; exit 1; }
        cert=\$(printf %s \"\$resp\" | jq -r .result.certificate)
        key=\$(printf %s \"\$resp\" | jq -r .result.private_key)
        [ -n \"$cert\" ] && [ -n \"$key\" ] || { echo \"Origin CA response missing cert/key\" >&2; exit 1; }
        tmpc=\$(mktemp); tmpk=\$(mktemp)
        printf %s \"\$cert\" >\"\$tmpc\"; printf %s \"\$key\" >\"\$tmpk\"
        kubectl -n \"$ns\" delete secret argocd-server-tls --ignore-not-found=true
        kubectl -n \"$ns\" create secret tls argocd-server-tls --cert=\"\$tmpc\" --key=\"\$tmpk\"
        rm -f \"\$tmpc\" \"\$tmpk\"
      '"
    else
      if [ "${ENABLE_CERT_MANAGER:-0}" -eq 1 ]; then
        say "Creating Cloudflare token secret for cert-manager"
        kctl "kubectl -n cert-manager delete secret cloudflare-api-token >/dev/null 2>&1 || true"
        kctl "kubectl -n cert-manager create secret generic cloudflare-api-token --from-literal=api-token='${CF_API_TOKEN}'"
        say "Applying ClusterIssuer (LE DNS01 via Cloudflare)"
        kctl "cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns01
spec:
  acme:
    email: ${LE_EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: le-account-key
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-token
            key: api-token
      selector: {}
EOF
"
        say "Requesting argocd.${DOMAIN} certificate via LE"
        kctl "kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-server
  namespace: argocd
spec:
  secretName: argocd-server-tls
  issuerRef:
    name: letsencrypt-dns01
    kind: ClusterIssuer
  dnsNames:
    - argocd.${DOMAIN}
EOF
"
      else
        say "Skipping ACME issuer/certificate (ENABLE_CERT_MANAGER=0). No TLS will be created unless USE_ORIGIN_CA=1."
      fi
    fi
  else
    say "Skipping cert-manager DNS01 ClusterIssuer (no CF_API_TOKEN)"
  fi

  # Vault (single-node, backed by nfs-storage)
  say "Installing Vault (single-node)"
  kctl "cat >/tmp/vault-values.yaml <<'EOF'
server:
  ha:
    enabled: false
  dataStorage:
    enabled: true
    size: 5Gi
    storageClass: nfs-storage
    accessModes: [ReadWriteOnce]
  affinity: null
  nodeSelector: {}
  tolerations:
    - operator: Exists
ui:
  enabled: true
resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits: { cpu: 500m, memory: 512Mi }
EOF"
  # Install/upgrade Vault; if immutable StatefulSet fields block the upgrade,
  # delete the StatefulSet (keep PVCs via --cascade=orphan) and retry once.
  helmctl "bash -lc 'set -e; \
    helm upgrade --install vault hashicorp/vault -n vault -f /tmp/vault-values.yaml --force \
    || { \
      echo >&2 \"Vault upgrade hit immutable StatefulSet change; deleting statefulset/vault and retrying...\"; \
      kubectl -n vault delete statefulset vault --cascade=orphan --wait=false || true; \
      sleep 3; \
      helm upgrade --install vault hashicorp/vault -n vault -f /tmp/vault-values.yaml; \
    }'"

  # Wait PVC and pod (best-effort PVC wait; rely primarily on pod readiness later)
  kctl "kubectl -n vault wait --for=jsonpath='{.status.phase}'=Bound pvc/data-vault-0 --timeout=5m || true"

  # Give the StatefulSet a short window to create pods; do not block forever
  say "Waiting for Vault StatefulSet to begin rollout"
  kctl "kubectl -n vault rollout status statefulset/vault --timeout=3m || true"

  # Wait for a Vault pod to be created, then capture its name
  say "Waiting for Vault pod to appear"
  local pod_deadline=$(( $(date +%s) + 180 ))
  VAULT_POD=""
  while true; do
    VAULT_POD="$(ssh_do "$CTRL_IP" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n vault get pod -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true")"
    if [ -n "$VAULT_POD" ]; then
      break
    fi
    if [ "$(date +%s)" -ge "$pod_deadline" ]; then
      echo "ERROR: Timeout waiting for Vault pod to be created. Diagnostics:" >&2
      kctl "kubectl -n vault get sts vault -o wide || true"
      kctl "kubectl -n vault describe sts vault || true"
      kctl "kubectl -n vault get pods -o wide || true"
      kctl "kubectl -n vault get events --sort-by=.lastTimestamp | tail -n 100 || true"
      exit 1
    fi
    sleep 3
  done

  # Wait until the Vault pod phase is Running (not necessarily Ready).
  # Vault's readiness probe fails until initialized/unsealed, so don't block on Ready.
  say "Waiting for Vault pod to be Running (not Ready)"
  run_deadline=$(( $(date +%s) + 300 ))
  while true; do
    phase="$(ssh_do "$CTRL_IP" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n vault get pod ${VAULT_POD} -o jsonpath='{.status.phase}' 2>/dev/null || true")"
    [ "$phase" = "Running" ] && break
    if [ "$(date +%s)" -ge "$run_deadline" ]; then
      echo "ERROR: Vault pod did not reach Running phase within 5 minutes (current: $phase)." >&2
      kctl "kubectl -n vault get pods -o wide || true"
      kctl "kubectl -n vault describe pod ${VAULT_POD} || true"
      exit 1
    fi
    sleep 3
  done

  # Ensure exec works into the container before attempting init/unseal
  say "Ensuring exec access to Vault container"
  exec_deadline=$(( $(date +%s) + 120 ))
  while true; do
    if kctl "kubectl -n vault exec '${VAULT_POD}' -- sh -c 'echo ok' >/dev/null 2>&1"; then
      break
    fi
    if [ "$(date +%s)" -ge "$exec_deadline" ]; then
      echo "ERROR: Unable to exec into ${VAULT_POD} after 2 minutes." >&2
      kctl "kubectl -n vault describe pod ${VAULT_POD} || true"
      exit 1
    fi
    sleep 2
  done

  # Init once; write via sudo tee (single-line to avoid heredoc quirks under quiet mode)
  kctl "POD='${VAULT_POD}'; if ! kubectl -n vault exec \"\$POD\" -- sh -c 'vault status | grep -q \"Initialized.*true\"'; then kubectl -n vault exec \"\$POD\" -- vault operator init -key-shares=1 -key-threshold=1 -format=json | sudo tee /root/vault-bootstrap.json >/dev/null; fi"

  # Read bootstrap creds if present; remain idempotent if already initialized
  ROOT_TOKEN="$(ssh_do "$CTRL_IP" "sudo jq -r .root_token /root/vault-bootstrap.json" 2>/dev/null || true)"
  UNSEAL_KEY="$(ssh_do "$CTRL_IP" "sudo jq -r .unseal_keys_b64[0] /root/vault-bootstrap.json" 2>/dev/null || true)"

  if [ -z "${ROOT_TOKEN:-}" ] || [ -z "${UNSEAL_KEY:-}" ]; then
    echo "WARN: Vault appears initialized but /root/vault-bootstrap.json is missing. Skipping unseal/seed to stay idempotent."
  else
    # Unseal & seed secrets (idempotent where possible)
    kctl "kubectl -n vault exec '${VAULT_POD}' -- vault operator unseal '${UNSEAL_KEY}' || true"
    if [ "$SKIP_CF" -eq 0 ]; then
      kctl "kubectl -n vault exec '${VAULT_POD}' -- sh -c '
        set -e
        export VAULT_ADDR=http://127.0.0.1:8200
        export VAULT_TOKEN='\"'\"'${ROOT_TOKEN}'\"'\"'
        vault secrets enable -path=kv kv-v2 || true
        vault auth enable kubernetes || true
        vault write auth/kubernetes/config \
          token_reviewer_jwt=\"$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\" \
          kubernetes_host=https://kubernetes.default.svc:443 \
          kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt || true
        vault kv put kv/homelab/cert-manager api-token=\"${CF_API_TOKEN}\"
        vault kv put kv/homelab/cloudflared token=\"${CF_TUNNEL_TOKEN}\"
      '"
    else
      kctl "kubectl -n vault exec '${VAULT_POD}' -- sh -c '
        set -e
        export VAULT_ADDR=http://127.0.0.1:8200
        export VAULT_TOKEN='\"'\"'${ROOT_TOKEN}'\"'\"'
        vault secrets enable -path=kv kv-v2 || true
        vault auth enable kubernetes || true
        vault write auth/kubernetes/config \
          token_reviewer_jwt=\"$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\" \
          kubernetes_host=https://kubernetes.default.svc:443 \
          kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt || true
      '"
    fi
  fi

  # Argo CD + AVP
  say "Installing Argo CD + AVP"
  kctl "cat >/tmp/argocd-values.yaml <<'EOF'
repoServer:
  env:
    - name: AVP_TYPE
      value: vault
    - name: VAULT_ADDR
      value: http://vault.vault.svc:8200
    - name: AVP_AUTH_TYPE
      value: kubernetes
    - name: AVP_K8S_ROLE
      value: argocd-repo
  initContainers:
    - name: avp-download
      image: ghcr.io/argoproj-labs/argocd-vault-plugin:v1.18.0
      command: [\"/bin/sh\",\"-c\"]
      args:
        - set -eu; \\
          cp /usr/local/bin/argocd-vault-plugin /custom-tools/avp; \\
          chmod +x /custom-tools/avp
      volumeMounts:
        - name: custom-tools
          mountPath: /custom-tools
  volumes:
    - name: custom-tools
      emptyDir: {}
  volumeMounts:
    - name: custom-tools
      mountPath: /usr/local/bin/argocd-vault-plugin
      subPath: avp
server:
  extraArgs: [\"--insecure\"]
EOF"
  # Install Argo CD without blocking on rollout to keep infra stage fast; do not fail on transient helm issues
  helmctl "helm upgrade --install argocd argo/argo-cd -n argocd -f /tmp/argocd-values.yaml || true"

  # Safeguard: ensure repo-server copyutil init has correct image/command and var-files mount (strategic merge by name)
  kctl "bash -lc 'set -e
    ns=argocd; dep=argocd-repo-server
    for i in 1 2 3 4 5; do kubectl -n \"$ns\" get deploy \"$dep\" >/dev/null 2>&1 && break || sleep 2; done
    cat >/tmp/rs-copyutil-merge.json <<EOF
{ "spec": { "template": { "spec": { "initContainers": [ {
  "name": "copyutil",
  "image": "quay.io/argoproj/argocd:v3.1.1",
  "command": ["/bin/cp","-n","/usr/local/bin/argocd","/var/run/argocd/argocd-cmp-server"],
  "args": [],
  "volumeMounts": [ { "name": "var-files", "mountPath": "/var/run/argocd" } ]
} ] } } } }
EOF
    kubectl -n \"$ns\" patch deploy \"$dep\" --type merge --patch-file /tmp/rs-copyutil-merge.json || true
  '"

  # Vault policy/role for Argo CD
  say "Configuring Vault role/policy for Argo CD"
  kctl "kubectl -n vault exec '${VAULT_POD}' -- sh -c '
    export VAULT_ADDR=http://127.0.0.1:8200
    export VAULT_TOKEN='\"'\"'${ROOT_TOKEN}'\"'\"'
    vault policy write argocd-read - <<POL
path \"kv/data/homelab/*\" { capabilities = [\"read\"] }
POL
    vault write auth/kubernetes/role/argocd-repo \
      bound_service_account_names=argocd-repo-server \
      bound_service_account_namespaces=argocd \
      policies=argocd-read
  '"

  # Monitoring + Logging
  if [ "${ENABLE_MONITORING:-0}" -eq 1 ]; then
    say "Installing kube-prometheus-stack"
    helmctl "helm upgrade --install monitoring prometheus-community/kube-prometheus-stack -n monitoring --set grafana.adminPassword=admin --timeout 15m --wait --wait-for-jobs || true"
  else
    say "Skipping monitoring stack (ENABLE_MONITORING=0)"
  fi
  if [ "${ENABLE_LOGGING:-0}" -eq 1 ]; then
    say "Installing Loki + Promtail"
    helmctl "helm upgrade --install logging grafana/loki-stack -n logging --set grafana.enabled=false --set promtail.enabled=true --timeout 10m --wait --wait-for-jobs || true"
  else
    say "Skipping logging stack (ENABLE_LOGGING=0)"
  fi

  # cloudflared (token mode) + routes
  local argocd_host="argocd.${DOMAIN}"
  local grafana_host="grafana.${DOMAIN}"
  local prom_host="prometheus.${DOMAIN}"

  if [ "$SKIP_CF" -eq 0 ]; then
    say "Deploying cloudflared (${CF_REPLICAS} replicas) in token mode"
    kctl "kubectl -n tunnel apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflared-token
  namespace: tunnel
stringData:
  TUNNEL_TOKEN: ${CF_TUNNEL_TOKEN}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: tunnel
  labels: { app: cloudflared }
spec:
  replicas: ${CF_REPLICAS}
  selector:
    matchLabels: { app: cloudflared }
  template:
    metadata:
      labels: { app: cloudflared }
    spec:
      containers:
      - name: cloudflared
        image: cloudflare/cloudflared:latest
        command: [\"/bin/sh\",\"-c\"]
        args: [\"exec cloudflared tunnel run --token \$TUNNEL_TOKEN\"]
        env:
          - name: TUNNEL_TOKEN
            valueFrom:
              secretKeyRef:
                name: cloudflared-token
                key: TUNNEL_TOKEN
EOF
"

    # Wait for cloudflared deployment to be ready (best-effort)
    kctl "kubectl -n tunnel rollout status deploy/cloudflared --timeout=5m || true"

    # Tailor reminder to enabled stacks
    cf_extra=""
    if [ "${ENABLE_MONITORING:-0}" -eq 1 ]; then cf_extra=", grafana.${DOMAIN}, prometheus.${DOMAIN}"; fi
    say "Reminder: define Public Hostnames in Cloudflare Zero Trust for argocd.${DOMAIN}${cf_extra}. Token mode ignores local config."

    # Optional wildcard cert
    say "Requesting wildcard cert (optional)"
    kctl "kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-funoffshore
  namespace: cert-manager
spec:
  secretName: wildcard-funoffshore-tls
  issuerRef:
    name: letsencrypt-dns01
    kind: ClusterIssuer
  dnsNames:
    - \"*.${DOMAIN}\"
    - \"${DOMAIN}\"
EOF
"
  else
    say "Skipping cloudflared deploy and wildcard cert (no CF_TUNNEL_TOKEN/CF_API_TOKEN)"
  fi
  # Re-enable normal verbosity for subsequent stages
  INFRA_QUIET=0
  # Set up ingress routes after core stacks
  stage_network
}

########################################
# 4) APPS (ArgoCD App-of-Apps)
########################################
install_apps() {
  ensure_cluster_ready
  dns_preflight_host
  say "Creating Argo CD App-of-Apps (repo: ${GIT_REPO} branch: ${GIT_BRANCH})"
  # Ensure argocd namespace exists and Helm is available when running apps standalone
  ensure_ns argocd
  ssh_do "$CTRL_IP" "command -v helm >/dev/null 2>&1 || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo -E bash -s -"
  # Ensure CoreDNS forwards external lookups to public resolvers to avoid upstream DNS issues
  say "Ensuring CoreDNS has public forwarders for external DNS"
  kctl "bash -lc 'set -e
    CM=\$(kubectl -n kube-system get configmap coredns -o name 2>/dev/null || true)
    if [ -n \"\$CM\" ]; then
      cat >/tmp/Corefile-public <<EOF
.:53 {
    errors
    health
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
        ttl 30
    }
    prometheus :9153
    forward . 1.1.1.1 1.0.0.1 8.8.8.8
    cache 30
    loop
    reload
    loadbalance
}
EOF
      kubectl -n kube-system get configmap coredns -o jsonpath="{.data.NodeHosts}" >/tmp/NodeHosts || true
      if [ -s /tmp/NodeHosts ]; then
        kubectl -n kube-system create configmap coredns \\
          --from-file=Corefile=/tmp/Corefile-public \\
          --from-file=NodeHosts=/tmp/NodeHosts \\
          -o yaml --dry-run=client | kubectl apply -f -
      else
        kubectl -n kube-system create configmap coredns --from-file=Corefile=/tmp/Corefile-public -o yaml --dry-run=client | kubectl apply -f -
      fi
      rm -f /tmp/NodeHosts
      kubectl -n kube-system rollout restart deploy/coredns || true
      kubectl -n kube-system rollout status deploy/coredns --timeout=2m || true
    fi
  '"
  # Quick DNS sanity check from within cluster (best-effort)
  kctl "kubectl -n argocd run dnscheck --rm -i --restart=Never --image=busybox:1.36 -- nslookup onedr0p.github.io || true"
  # Make sure Argo CD Application CRD is present before applying any Applications
  kctl "bash -lc 'for i in {1..60}; do kubectl get crd applications.argoproj.io >/dev/null 2>&1 && break || sleep 2; done'"
  kctl "kubectl apply --validate=false -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: homelab-root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GIT_REPO}
    targetRevision: ${GIT_BRANCH}
    # Point to an existing path in this repo that contains Argo Application YAMLs
    path: proxmox/ci
  destination:
    namespace: argocd
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
"

  # Optional: Tailscale operator (installs CRDs and controller; configuration is user-driven)
  say "Installing optional Tailscale operator"
  helmctl "helm repo add tailscale https://pkgs.tailscale.com/helmcharts >/dev/null 2>&1 || true"
  helmctl "helm repo update >/dev/null 2>&1 || true"
  helmctl "helm upgrade --install tailscale-operator tailscale/tailscale-operator -n tailscale-system --create-namespace || true"

  # Media homelab apps via Argo CD Applications
  say "Deploying media apps (servarr, jellyseerr, minecraft) via Argo CD"
  # Servarr umbrella (enables Jellyfin, Jellyseerr, Sonarr; tweak as needed)
  kctl "kubectl apply --validate=false -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: servarr
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.kubito.dev
    chart: servarr
    targetRevision: 1.0.7
    helm:
      values: |
        persistence:
          config:
            enabled: true
            storageClass: \"\"
            size: 5Gi
          media:
            enabled: true
            storageClass: \"\"
            size: 50Gi
            accessMode: ReadWriteMany
        jellyfin:
          enabled: false
          ingress:
            enabled: true
            ingressClassName: traefik
            annotations:
              traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
              traefik.ingress.kubernetes.io/router.tls: \"true\"
            hosts:
              - host: jellyfin.${DOMAIN}
                paths:
                  - path: /
                    pathType: Prefix
            tls:
              - hosts:
                  - jellyfin.${DOMAIN}
                secretName: jellyfin-tls
          service:
            port: 8096
        jellyseerr:
          enabled: true
          ingress:
            enabled: true
            ingressClassName: traefik
            annotations:
              traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
              traefik.ingress.kubernetes.io/router.tls: \"true\"
            hosts:
              - host: jellyseerr.${DOMAIN}
                paths:
                  - path: /
                    pathType: Prefix
            tls:
              - hosts:
                  - jellyseerr.${DOMAIN}
                secretName: jellyseerr-tls
          service:
            port: 5055
          env:
            JELLYFIN_URL: http://servarr-jellyfin.servarr.svc.cluster.local:8096
            SONARR_URL: http://servarr-sonarr.servarr.svc.cluster.local:8989
        sonarr:
          enabled: true
          ingress:
            enabled: true
            ingressClassName: traefik
            annotations:
              traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
              traefik.ingress.kubernetes.io/router.tls: \"true\"
            hosts:
              - host: sonarr.${DOMAIN}
                paths:
                  - path: /
                    pathType: Prefix
            tls:
              - hosts:
                  - sonarr.${DOMAIN}
                secretName: sonarr-tls
          service:
            port: 8989
        radarr:
          enabled: true
          ingress:
            enabled: true
            ingressClassName: traefik
            annotations:
              traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
              traefik.ingress.kubernetes.io/router.tls: "true"
            hosts:
              - host: radarr.${DOMAIN}
                paths:
                  - path: /
                    pathType: Prefix
            tls:
              - hosts:
                  - radarr.${DOMAIN}
                secretName: radarr-tls
          service:
            port: 7878
        qbittorrent:
          enabled: true
          ingress:
            enabled: true
            ingressClassName: traefik
            annotations:
              traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
              traefik.ingress.kubernetes.io/router.tls: "true"
            hosts:
              - host: qbittorrent.${DOMAIN}
                paths:
                  - path: /
                    pathType: Prefix
            tls:
              - hosts:
                  - qbittorrent.${DOMAIN}
                secretName: qbittorrent-tls
          service:
            port: 8080
        prowlarr:
          enabled: true
          ingress:
            enabled: true
            ingressClassName: traefik
            annotations:
              traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
              traefik.ingress.kubernetes.io/router.tls: "true"
            hosts:
              - host: prowlarr.${DOMAIN}
                paths:
                  - path: /
                    pathType: Prefix
            tls:
              - hosts:
                  - prowlarr.${DOMAIN}
                secretName: prowlarr-tls
          service:
            port: 9696
  destination:
    server: https://kubernetes.default.svc
    namespace: servarr
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
"

  # Standalone Jellyseerr (optional separate release)
  kctl "kubectl apply --validate=false -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: jellyseerr
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.jellyseerr.dev
    chart: jellyseerr
    targetRevision: 1.7.0
    helm:
      values: |
        persistence:
          config:
            enabled: true
            storageClass: \"\"
            size: 5Gi
        ingress:
          enabled: true
          ingressClassName: traefik
          annotations:
            traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
            traefik.ingress.kubernetes.io/router.tls: \"true\"
          hosts:
            - host: jellyseerr.${DOMAIN}
              paths:
                - path: /
                  pathType: Prefix
          tls:
            - hosts:
                - jellyseerr.${DOMAIN}
              secretName: jellyseerr-tls
        service:
          type: ClusterIP
          port: 5055
  destination:
    server: https://kubernetes.default.svc
    namespace: jellyseerr
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
"

  # Standalone Jellyfin (onedr0p chart)
  kctl "kubectl apply --validate=false -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: jellyfin
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://onedr0p.github.io/helm-charts
    chart: jellyfin
    targetRevision: 6.0.0
    helm:
      values: |
        persistence:
          config:
            enabled: true
            storageClass: ""
            size: 5Gi
        ingress:
          main:
            enabled: true
            ingressClassName: traefik
            annotations:
              traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
              traefik.ingress.kubernetes.io/router.tls: "true"
            hosts:
              - host: jellyfin.${DOMAIN}
                paths:
                  - path: /
                    pathType: Prefix
            tls:
              - hosts:
                  - jellyfin.${DOMAIN}
                secretName: jellyfin-tls
  destination:
    server: https://kubernetes.default.svc
    namespace: jellyfin
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
"

  # Overseerr (onedr0p chart)
  kctl "kubectl apply --validate=false -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: overseerr
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://onedr0p.github.io/helm-charts
    chart: overseerr
    targetRevision: 2.0.0
    helm:
      values: |
        persistence:
          config:
            enabled: true
            storageClass: ""
            size: 5Gi
        ingress:
          main:
            enabled: true
            ingressClassName: traefik
            annotations:
              traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
              traefik.ingress.kubernetes.io/router.tls: "true"
            hosts:
              - host: overseerr.${DOMAIN}
                paths:
                  - path: /
                    pathType: Prefix
            tls:
              - hosts:
                  - overseerr.${DOMAIN}
                secretName: overseerr-tls
  destination:
    server: https://kubernetes.default.svc
    namespace: overseerr
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
"

  # Minecraft server
  kctl "kubectl apply --validate=false -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: minecraft
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://helm.itzg.me
    chart: minecraft
    targetRevision: 4.22.0
    helm:
      values: |
        minecraftServer:
          eula: true
          difficulty: normal
          mode: survival
          pvp: true
          maxPlayers: 20
          motd: \"Welcome to Homelab Minecraft!\"
          memory: \"2048M\"
        persistence:
          dataDir:
            enabled: true
            storageClass: \"\"
            size: 10Gi
        service:
          type: ClusterIP
          port: 25565
        ingress:
          enabled: true
          ingressClassName: traefik
          annotations:
            traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
            traefik.ingress.kubernetes.io/router.tls: \"true\"
          hosts:
            - host: minecraft.${DOMAIN}
              paths:
                - path: /
                  pathType: Prefix
          tls:
            - hosts:
                - minecraft.${DOMAIN}
              secretName: minecraft-tls
  destination:
    server: https://kubernetes.default.svc
    namespace: minecraft
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
"
}

########################################
# MAIN — staged execution
########################################
stage="${1:-all}"

case "$stage" in
  preflight)
    ensure_host_tools
    say_config
    check_connectivity
    ;;
  diagnose)
    ensure_host_tools
    say_config
    check_connectivity
    diagnose_cluster
    ;;
  k3s)
    ensure_host_tools
    wipe_known_hosts
    bootstrap_control_plane
    join_workers
    wait_nodes_ready
    ;;
  infra)
    ensure_host_tools
    install_infra
    ;;
  cloudflare)
    ensure_host_tools
    stage_cloudflare
    ;;
  network)
    ensure_host_tools
    stage_network
    ;;
  argocd)
    ensure_host_tools
    stage_argocd
    ;;
  storage)
    ensure_host_tools
    stage_storage
    ;;
  cert)
    ensure_host_tools
    stage_cert
    ;;
  vault)
    ensure_host_tools
    stage_vault
    ;;
  monitoring)
    ensure_host_tools
    stage_monitoring
    ;;
  logging)
    ensure_host_tools
    stage_logging
    ;;
  tailscale)
    ensure_host_tools
    stage_tailscale
    ;;
  apps)
    ensure_host_tools
    install_apps
    ;;
  all)
    ensure_host_tools
    wipe_known_hosts
    bootstrap_control_plane
    join_workers
    wait_nodes_ready
    install_infra
    install_apps
    ;;
  *)
    echo "Usage: $0 [preflight|diagnose|k3s|infra|cloudflare|network|argocd|storage|cert|vault|monitoring|logging|tailscale|apps|all]  (default: all)"
    exit 1
    ;;
esac

say_lines="Done 🎉 Stage: $stage\n- Control plane: $CTRL_IP\n- Workers: ${WORKERS[*]}\n- URLs (once DNS tunnel CNAME is set):\n    https://argocd.${DOMAIN}"
if [ "${ENABLE_MONITORING:-0}" -eq 1 ]; then
  say_lines+="\n    https://grafana.${DOMAIN}\n    https://prometheus.${DOMAIN}"
fi
say_lines+="\n- Vault bootstrap on control-plane: /root/vault-bootstrap.json"
say "$say_lines"
