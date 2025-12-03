#!/usr/bin/env bash
set -Eeuo pipefail

REMOTE=192.168.1.214
PORT=22
KYLE_USER="kyle"
KYLE_PASS="root"
ROOT_PASS="root"

SSH_OPTS=(
  -T
  -p "$PORT"
  -o StrictHostKeyChecking=accept-new
  -o PubkeyAuthentication=no
  -o BatchMode=no
  -o PreferredAuthentications=password,keyboard-interactive
  -o ConnectTimeout=7
  -o NumberOfPasswordPrompts=1
)
SCP_OPTS=(
  -P "$PORT"
  -o StrictHostKeyChecking=accept-new
  -o PubkeyAuthentication=no
  -o BatchMode=no
  -o PreferredAuthentications=password,keyboard-interactive
  -o ConnectTimeout=7
  -o NumberOfPasswordPrompts=1
)

SSHPASS(){ sshpass -p "$KYLE_PASS" "$@"; }
now(){ date -Is; }
stage(){ printf "\n[ %s ] STAGE: %s\n" "$(now)" "$*"; }

ensure_kyle_exists(){
  stage "ENSURE-USER"
  if sshpass -p "$ROOT_PASS" ssh "${SSH_OPTS[@]}" root@"$REMOTE" "id $KYLE_USER" >/dev/null 2>&1; then
    echo "user $KYLE_USER exists"
    return 0
  fi
  echo "creating user $KYLE_USER with password 'root'"
  sshpass -p "$ROOT_PASS" ssh "${SSH_OPTS[@]}" root@"$REMOTE" "useradd -m -s /bin/bash $KYLE_USER || true && echo '$KYLE_USER:$KYLE_PASS' | chpasswd"
}

push_file(){
  stage "PUSH"
  SSHPASS scp -q "${SCP_OPTS[@]}" proxmox/scripts/cluster_bootstrap.sh "$KYLE_USER@$REMOTE:/home/$KYLE_USER/cluster_bootstrap.sh"
  rc=$?; [ $rc -eq 0 ] || { echo "scp failed (rc=$rc)"; return $rc; }
  echo "pushed proxmox/scripts/cluster_bootstrap.sh -> $REMOTE:/home/$KYLE_USER/"
}

promote_and_lint(){
  stage "PROMOTE+LINT"
  SSHPASS ssh "${SSH_OPTS[@]}" "$KYLE_USER@$REMOTE" "
    printf '%s\n' '$ROOT_PASS' | su - root -c '
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
      mv -f /home/$KYLE_USER/cluster_bootstrap.sh /root/cluster_bootstrap.sh || true
      chmod +x /root/cluster_bootstrap.sh || true
      bash -n /root/cluster_bootstrap.sh || true
      (command -v shellcheck >/dev/null 2>&1 && shellcheck /root/cluster_bootstrap.sh -S warning || true)
    '
  "
}

preflight(){
  stage "PREFLIGHT"
  if ! SSHPASS ssh "${SSH_OPTS[@]}" "$KYLE_USER@$REMOTE" "command -v kubectl >/dev/null 2>&1"; then
    echo "kubectl not present yet on remote; skipping preflight (infra will be run)"
    return 0
  fi

  SSHPASS ssh "${SSH_OPTS[@]}" "$KYLE_USER@$REMOTE" "
    printf '%s\n' '$ROOT_PASS' | su - root -c '
      set -euo pipefail
      export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
      export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
      kubectl wait --for=condition=Ready node --all --timeout=90s || echo 'nodes not ready yet'
      kubectl get ns preflight-dns >/dev/null 2>&1 || kubectl create ns preflight-dns || true
      kubectl -n preflight-dns delete pod dnscheck --ignore-not-found || true
      kubectl -n preflight-dns run dnscheck --image=busybox:1.36 --restart=Never -- nslookup github.com || true
      kubectl -n preflight-dns wait --for=condition=Completed pod/dnscheck --timeout=60s || echo 'dnscheck failed or timed out'
      kubectl -n preflight-dns logs dnscheck || true
    '
  "
}

run_infra(){
  stage "INFRA"
  SSHPASS ssh "${SSH_OPTS[@]}" "$KYLE_USER@$REMOTE" "
    printf '%s\n' '$ROOT_PASS' | su - root -c '
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
      CF_API_TOKEN=${CF_API_TOKEN:-} CF_TUNNEL_TOKEN=${CF_TUNNEL_TOKEN:-}
      echo \"Running: /root/cluster_bootstrap.sh infra\"
      bash /root/cluster_bootstrap.sh infra
    '
  "
}

assert_argo(){
  stage "ASSERT-ARGO"
  SSHPASS ssh "${SSH_OPTS[@]}" "$KYLE_USER@$REMOTE" "
    printf '%s\n' '$ROOT_PASS' | su - root -c '
      set -euo pipefail
      export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
      kubectl -n argocd get applications.argoproj.io -o json \
        | jq -r \".items[] | [.metadata.name, .status.sync.status, .status.health.status] | @tsv\" \
        | tee /root/argo_app_status.tsv || true

      FAILED=$(kubectl -n argocd get applications.argoproj.io -o json \
        | jq -r '[.items[] | select(.status.sync.status != \"Synced\" or .status.health.status != \"Healthy\")] | length')
      echo \"Argo apps failing: $FAILED\"
      if [ \"$FAILED\" -ne 0 ]; then
        echo 'Not all Argo apps are Synced & Healthy' >&2
        exit 2
      fi
    '
  "
}

diagnostics(){
  stage "DIAGNOSTICS"
  SSHPASS ssh "${SSH_OPTS[@]}" "$KYLE_USER@$REMOTE" "
    printf '%s\n' '$ROOT_PASS' | su - root -c '
      set +e
      export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
      echo \"=== NODES ===\"; kubectl get nodes -o wide || true
      echo \"=== KUBE-SYSTEM ===\"; kubectl -n kube-system get deploy,ds,svc,endpoints || true
      echo \"=== COREDNS LOGS ===\"; kubectl -n kube-system logs deploy/coredns --tail=200 || true
      kubectl -n kube-system get cm coredns -o yaml || true
      echo \"=== RESOLV.CONF ===\"; cat /etc/resolv.conf || true
      echo \"=== ARGOCD ===\"; kubectl -n argocd get pods,svc,ep,deploy -o wide || true
      kubectl -n argocd logs deploy/argocd-repo-server --tail=200 || true
      kubectl -n argocd logs deploy/argocd-application-controller --tail=200 || true
      kubectl -n argocd get applications.argoproj.io -o yaml | sed -n '1,200p' || true
      echo \"=== CRDS ===\"; kubectl api-resources | sort | sed -n '1,200p' || true
      echo \"=== STORAGE ===\"; kubectl get sc,pv,pvc -A || true
      showmount -e 192.168.1.112 || true
    '
  "
}

# MAIN loop
attempt=0
ensure_kyle_exists

while :; do
  attempt=$((attempt+1))
  stage "LOOP-START (attempt #$attempt)"

  set +e
  push_file && promote_and_lint && preflight && run_infra && assert_argo
  rc=$?
  set -e

  if [ $rc -eq 0 ]; then
    stage "SUCCESS"
    echo "✅ Infra converged: all Argo CD apps Synced & Healthy."
    exit 0
  fi

  stage "LOOP-FAILED (rc=$rc)"
  echo "Collecting diagnostics (remote)..."
  diagnostics
  echo "---- Inspect diagnostics and patch proxmox/scripts/cluster_bootstrap.sh with a minimal fix; show unified diff. ----"
  sleep 3
done
