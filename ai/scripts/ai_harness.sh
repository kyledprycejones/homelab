#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$ROOT_DIR"

: "${CLUSTER:=prox-n100}"
: "${TASK_ID:=runner}"
: "${TASK_STAGE:=all}"
: "${TASK_TARGET:=}"
: "${TASK_DETAIL:=}"

CONFIG_YAML="config/clusters/${CLUSTER}.yaml"
ENV_FILE="config/env/${CLUSTER}.env"

if [ -z "$TASK_TARGET" ]; then
  echo "Missing TASK_TARGET" >&2
  exit 1
fi

if [ ! -f "$CONFIG_YAML" ]; then
  echo "Cluster config missing: $CONFIG_YAML" >&2
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "yq (v4) is required" >&2
  exit 1
fi

CTRL_IP="$(yq -e '.controller.ip' "$CONFIG_YAML")"
DOMAIN="$(yq -e '.domain' "$CONFIG_YAML")"

SSH_USER="kyle"
SSH_PORT="22"
SSH_PASS=""

if [ -f "$ENV_FILE" ]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +o allexport
fi

SSH_USER="${SSH_USER:-kyle}"
SSH_PORT="${SSH_PORT:-22}"
SSH_PASS="${SSH_PASS:-}"

SSH_OPTS=(-T -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
SCP_OPTS=(-P "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
if [ -n "$SSH_PASS" ]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "sshpass is required when SSH_PASS is set" >&2
    exit 1
  fi
  SSH_CMD=(sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}")
  SCP_CMD=(sshpass -p "$SSH_PASS" scp "${SCP_OPTS[@]}")
else
  SSH_CMD=(ssh "${SSH_OPTS[@]}")
  SCP_CMD=(scp "${SCP_OPTS[@]}")
fi

TARGET="${SSH_USER}@${CTRL_IP}"
WORKING_SCRIPT="/tmp/${TASK_ID}-$(basename "$TASK_TARGET")"
DEPLOY_SCRIPT="/tmp/${TASK_ID}.sh"

printf 'HARNESS_START task=%s target=%s stage=%s detail=%s\n' "$TASK_ID" "$TASK_TARGET" "$TASK_STAGE" "$TASK_DETAIL"

"${SCP_CMD[@]}" "$TASK_TARGET" "$TARGET:$WORKING_SCRIPT"
"${SSH_CMD[@]}" "$TARGET" "sudo mv $WORKING_SCRIPT $DEPLOY_SCRIPT && sudo chmod +x $DEPLOY_SCRIPT"
"${SSH_CMD[@]}" "$TARGET" "sudo $DEPLOY_SCRIPT ${TASK_STAGE}"

printf 'HARNESS_END task=%s exit=0\n' "$TASK_ID"
