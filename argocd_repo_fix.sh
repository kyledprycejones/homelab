#!/usr/bin/env bash
set -euo pipefail

# Simple, linear kubectl commands to fix Argo CD repo-server init
# No JSON inline, no complex flags — copy/paste friendly.

NS=argocd
DEP=argocd-repo-server
ARGO_IMG=quay.io/argoproj/argocd:v3.1.1

echo
echo "== 1) Hard reset initContainers to copyutil only (${ARGO_IMG}) =="
cat > /tmp/rs-init.json <<EOF
[
  {
    "op":"replace",
    "path":"/spec/template/spec/initContainers",
    "value":[
      {
        "name":"copyutil",
        "image":"${ARGO_IMG}",
        "command":["/bin/cp","-n","/usr/local/bin/argocd","/var/run/argocd/argocd-cmp-server"],
        "args":[],
        "volumeMounts":[
          {"name":"var-files","mountPath":"/var/run/argocd"}
        ]
      }
    ]
  }
]
EOF
kubectl -n "$NS" patch deploy "$DEP" --type json --patch-file /tmp/rs-init.json

echo
echo "== 2) Restart pods and wait for rollout =="
# Force new ReplicaSet by bumping a template annotation
kubectl -n "$NS" patch deploy "$DEP" -p '{"spec":{"template":{"metadata":{"annotations":{"fix-ts":"'"$(date +%s)"'"}}}}}' >/dev/null || true
# Hard restart
kubectl -n "$NS" scale deploy "$DEP" --replicas=0
kubectl -n "$NS" wait --for=delete pod -l app.kubernetes.io/name=$DEP --timeout=120s || true
kubectl -n "$NS" scale deploy "$DEP" --replicas=1
kubectl -n "$NS" rollout status deploy/"$DEP" --timeout=5m || true

echo
echo "== 3) Show init containers (name:image) =="
kubectl -n "$NS" get deploy "$DEP" \
  -o jsonpath='{range .spec.template.spec.initContainers[*]}- {.name}:{.image}{"\n"}{end}'

echo
echo "== 3b) Deployment initContainers command/args =="
kubectl -n "$NS" get deploy "$DEP" -o jsonpath='{range .spec.template.spec.initContainers[*]}- {.name} CMD={.command} ARGS={.args}{"\n"}{end}'

echo
echo "Done. If still failing, describe the newest pod and check copyutil logs:"
echo "  POD=\$(kubectl -n $NS get pod -l app.kubernetes.io/name=$DEP -o jsonpath='{.items[0].metadata.name}')"
echo "  kubectl -n $NS get pod $POD -o jsonpath='{range .spec.initContainers[*]}- {.name} CMD={.command} ARGS={.args}{"\n"}{end}'"
echo "  kubectl -n $NS describe pod $POD | sed -n '1,160p'"
echo "  kubectl -n $NS logs $POD -c copyutil --since=5m"

# Optional: re-add AVP init (set ADD_AVP=1 when running this script)
if [ "${ADD_AVP:-0}" = "1" ]; then
  echo "\n== 4) Add AVP init to copy plugin from image =="
  AVP_IMG=ghcr.io/argoproj-labs/argocd-vault-plugin:v1.18.0
  cat > /tmp/rs-avp.json <<EOF
[
  {
    "op":"add",
    "path":"/spec/template/spec/initContainers/-",
    "value":{
      "name":"avp-download",
      "image":"${AVP_IMG}",
      "command":["/bin/sh","-c"],
      "args":["cp /usr/local/bin/argocd-vault-plugin /custom-tools/avp; chmod +x /custom-tools/avp"],
      "volumeMounts":[{"name":"custom-tools","mountPath":"/custom-tools"}]
    }
  }
]
EOF
  kubectl -n "$NS" patch deploy "$DEP" --type json --patch-file /tmp/rs-avp.json
  echo "\n== 5) Restart pods and wait for rollout (with AVP) =="
  kubectl -n "$NS" delete pod -l app.kubernetes.io/name=$DEP || true
  kubectl -n "$NS" rollout status deploy/"$DEP" --timeout=5m || true
  echo "\n== 6) AVP init logs (if any) =="
  kubectl -n "$NS" logs deploy/"$DEP" -c avp-download --since=2m || true
fi
