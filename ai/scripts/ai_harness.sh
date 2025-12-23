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
REMOTE_ROOT="${REMOTE_ROOT:-/tmp/homelab}"
REMOTE_CONFIG_YAML="${REMOTE_ROOT}/${CONFIG_YAML}"
REMOTE_ENV_FILE="${REMOTE_ROOT}/${ENV_FILE}"

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

RSYNC_EXCLUDES=(
  "--exclude=.git"
  "--exclude=ai/state/**"
  "--exclude=ui/logs/**"
)
RSYNC_CMD=(rsync -az --rsync-path="mkdir -p ${REMOTE_ROOT} && rsync" -e "${SSH_CMD[*]}" "${RSYNC_EXCLUDES[@]}")

TARGET="${SSH_USER}@${CTRL_IP}"
REMOTE_REPO="${REMOTE_ROOT}"
REMOTE_TARGET="${REMOTE_REPO}/${TASK_TARGET}"

printf 'HARNESS_START task=%s target=%s stage=%s detail=%s\n' "$TASK_ID" "$TASK_TARGET" "$TASK_STAGE" "$TASK_DETAIL"

set +e
"${RSYNC_CMD[@]}" "${ROOT_DIR}/" "${TARGET}:${REMOTE_REPO}/"
rsync_rc=$?
set -e
printf 'HARNESS_STEP name=rsync rc=%d\n' "$rsync_rc"
if [ "$rsync_rc" -ne 0 ]; then
  printf 'HARNESS_END task=%s exit=%d\n' "$TASK_ID" "$rsync_rc"
  exit "$rsync_rc"
fi

set +e
"${SSH_CMD[@]}" "$TARGET" "cd ${REMOTE_REPO} && sudo chmod +x ${TASK_TARGET} 2>/dev/null || true"
chmod_rc=$?
set -e
printf 'HARNESS_STEP name=chmod rc=%d\n' "$chmod_rc"
if [ "$chmod_rc" -ne 0 ]; then
  printf 'HARNESS_END task=%s exit=%d\n' "$TASK_ID" "$chmod_rc"
  exit "$chmod_rc"
fi

set +e
"${SSH_CMD[@]}" "$TARGET" "cd ${REMOTE_REPO} && sudo env CLUSTER=${CLUSTER} CONFIG_ENV=${REMOTE_ENV_FILE} CLUSTER_CONFIG_FILE=${REMOTE_CONFIG_YAML} CTRL_IP=${CTRL_IP} DOMAIN=${DOMAIN} ${TASK_TARGET} ${TASK_STAGE}"
exec_rc=$?
set -e
printf 'HARNESS_STEP name=exec rc=%d\n' "$exec_rc"

printf 'HARNESS_END task=%s exit=%d\n' "$TASK_ID" "$exec_rc"
exit "$exec_rc"
