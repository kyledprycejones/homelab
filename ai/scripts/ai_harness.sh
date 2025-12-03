#!/usr/bin/env bash
#
# AI HARNESS CONTRACT (long-running CLI loop, Stage 1)
# - Backlog source: ai/backlog.yaml (entries with TASK_ID/TYPE/TARGET/DESCRIPTION; first pending task is processed).
# - State files: ai/state/last_run.log, ai/state/current_task.json, ai/state/metrics.json.
# - Logs: logs/executor/executor-YYYYMMDD-HHMMSS.log per loop.
# - Allowed write paths for CLI: cluster/, infrastructure/, config/, scripts/, docs/, ai/* (never secrets); do not create new top-level dirs; do not touch .gitignore/.sops.yaml/.talos/ beyond documented tasks.
# - Loop pseudocode:
#   1) Parse ai/backlog.yaml, pick first pending task (extract TASK_ID, TYPE, TARGET, DESCRIPTION).
#   2) Mark ai/state/current_task.json status=running with timestamp.
#   3) Call Executor/CLI to act on TARGET/DESCRIPTION (implementation-specific).
#   4) On success: mark task completed in ai/backlog.yaml, append summary to logs/executor/<ts>.log, update metrics.json and last_run.log, set current_task.status=completed.
#   5) On failure: leave task unchecked (or add a note), log error, set current_task.status=failed.
#   6) Stop when no unchecked tasks remain or safety/iteration limit is hit.
# - This script currently prepares env/branch/config and is the place to embed the above loop logic in future iterations.
# - When invoked by codex_loop.sh, the following envs are provided for a single task attempt:
#   TASK_ID, TASK_TYPE, TASK_TARGET, TASK_DESC, LOG_FILE
#   Respect allowed paths: cluster/, infrastructure/, config/, scripts/, docs/, ai/ (no secrets; do not create new top-level dirs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$ROOT_DIR"

CLUSTER="${1:-prox-n100}"
shift || true
STAGE="${BOOTSTRAP_STAGE:-all}"
EXTRA_ARGS=()

# Parse an optional stage as the next non-flag arg, everything else becomes EXTRA_ARGS (e.g., -v/-vv).
if [ "${1:-}" ] && [[ "${1}" != -* ]]; then
  STAGE="$1"
  shift
fi
while [ "$#" -gt 0 ]; do
  EXTRA_ARGS+=("$1")
  shift
done
EXTRA_ARGS_STR="${EXTRA_ARGS[*]:-}"

CONFIG_YAML="config/clusters/${CLUSTER}.yaml"
ENV_FILE="config/env/${CLUSTER}.env"

if [ ! -f "$CONFIG_YAML" ]; then
  echo "Missing cluster config: $CONFIG_YAML" >&2
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "yq (v4) is required. Install from https://github.com/mikefarah/yq" >&2
  exit 1
fi

CONFIG_CTRL_IP="$(yq -e '.controller.ip' "$CONFIG_YAML")"
CONFIG_WORKERS_RAW="$(yq '.workers[]?' "$CONFIG_YAML" 2>/dev/null || true)"
CONFIG_WORKERS=()
while IFS= read -r line; do
  [ -n "$line" ] && CONFIG_WORKERS+=("$line")
done <<< "$CONFIG_WORKERS_RAW"
CONFIG_DOMAIN="$(yq -e '.domain' "$CONFIG_YAML")"
CONFIG_NFS_SERVER="$(yq -e '.nfs.server' "$CONFIG_YAML")"
CONFIG_NFS_PATH="$(yq -e '.nfs.path' "$CONFIG_YAML")"

if [ -f "$ENV_FILE" ]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +o allexport
else
  echo "WARN: env file not found at $ENV_FILE; continuing with template/defaults" >&2
fi

CTRL_IP="${CTRL_IP:-$CONFIG_CTRL_IP}"
DOMAIN="${DOMAIN:-$CONFIG_DOMAIN}"
NFS_SERVER="${NFS_SERVER:-$CONFIG_NFS_SERVER}"
NFS_PATH="${NFS_PATH:-$CONFIG_NFS_PATH}"
GIT_REPO="${GIT_REPO:-https://github.com/kyledprycejones/homelab}"
requested_branch="${GIT_BRANCH:-}"
detected_branch=""
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  detected_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -z "$detected_branch" ] || [ "$detected_branch" = "HEAD" ]; then
    detected_branch="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -n1)"
  fi
fi
if [ -z "$detected_branch" ]; then
  detected_branch="main"
fi

select_branch() {
  if [ -z "$requested_branch" ]; then
    GIT_BRANCH="$detected_branch"
    return
  fi

  if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
    GIT_BRANCH="$requested_branch"
    return
  fi

  if git show-ref --verify --quiet "refs/heads/$requested_branch" >/dev/null 2>&1; then
    GIT_BRANCH="$requested_branch"
    return
  fi

  if git show-ref --verify --quiet "refs/remotes/origin/$requested_branch" >/dev/null 2>&1; then
    GIT_BRANCH="$requested_branch"
    return
  fi

  if git ls-remote --exit-code --heads origin "$requested_branch" >/dev/null 2>&1; then
    GIT_BRANCH="$requested_branch"
    return
  fi

  echo "WARN: Requested GIT_BRANCH '$requested_branch' not found locally or on origin; using detected branch '$detected_branch'" >&2
  GIT_BRANCH="$detected_branch"
}

select_branch
GIT_BRANCH="${GIT_BRANCH}"
SSH_USER="${SSH_USER:-kyle}"
SSH_PASS="${SSH_PASS:-}"
SSH_PORT="${SSH_PORT:-22}"

WORKERS_RAW="${WORKERS:-}"
if [ -z "$WORKERS_RAW" ]; then
  WORKERS_RAW="${CONFIG_WORKERS[*]:-}"
fi

# We disable StrictHostKeyChecking and send host keys to /dev/null so automated runs
# by the Executor do not get stuck or spam known_hosts warnings on the operator's machine.
SSH_BASE_OPTS=(-T -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
SCP_BASE_OPTS=(-P "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
if [ -n "$SSH_PASS" ]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "sshpass is required when SSH_PASS is set" >&2
    exit 1
  fi
  SSH_CMD=(sshpass -p "$SSH_PASS" ssh "${SSH_BASE_OPTS[@]}")
  SCP_CMD=(sshpass -p "$SSH_PASS" scp "${SCP_BASE_OPTS[@]}")
else
  SSH_CMD=(ssh "${SSH_BASE_OPTS[@]}")
  SCP_CMD=(scp "${SCP_BASE_OPTS[@]}")
fi

TARGET="${SSH_USER}@${CTRL_IP}"

mkdir -p logs

quote() { printf "%q" "$1"; }

"${SCP_CMD[@]}" infrastructure/proxmox/cluster_bootstrap.sh "${TARGET}:/tmp/cluster_bootstrap.sh"
"${SSH_CMD[@]}" "$TARGET" "chmod +x /tmp/cluster_bootstrap.sh"

remote_env=(
  "CTRL_IP=$(quote "$CTRL_IP")"
  "WORKERS=$(quote "$WORKERS_RAW")"
  "DOMAIN=$(quote "$DOMAIN")"
  "NFS_SERVER=$(quote "$NFS_SERVER")"
  "NFS_PATH=$(quote "$NFS_PATH")"
  "GIT_REPO=$(quote "$GIT_REPO")"
  "GIT_BRANCH=$(quote "$GIT_BRANCH")"
  "SSH_USER=$(quote "$SSH_USER")"
  "SSH_PASS=$(quote "$SSH_PASS")"
  "SSH_PORT=$(quote "$SSH_PORT")"
  "CF_API_TOKEN=$(quote "${CF_API_TOKEN:-}")"
  "CF_TUNNEL_TOKEN=$(quote "${CF_TUNNEL_TOKEN:-}")"
  "CF_ORIGIN_CA_KEY=$(quote "${CF_ORIGIN_CA_KEY:-}")"
  "LE_EMAIL=$(quote "${LE_EMAIL:-}")"
)

env_string=""
for kv in "${remote_env[@]}"; do
  env_string+="${kv} "
done

cmd="${env_string}/tmp/cluster_bootstrap.sh"
timestamp="$(date +%Y%m%d-%H%M%S)"
run_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log_file="logs/${CLUSTER}-${STAGE}-${timestamp}.log"
latest_stage_link="logs/latest-${CLUSTER}-${STAGE}.log"
latest_cluster_link="logs/latest-${CLUSTER}.log"
latest_global_link="logs/latest.log"

echo "== HARNESS START == cluster=${CLUSTER} stage=${STAGE} target=${TARGET} log=${log_file}"
echo "HARNESS_START target=${CLUSTER} stage=${STAGE} time=$(date -Is 2>/dev/null || date)"
if [ -n "$EXTRA_ARGS_STR" ]; then
  echo "Passing extra args to bootstrap: ${EXTRA_ARGS_STR}"
fi
full_cmd="$cmd"
if [ -n "$EXTRA_ARGS_STR" ]; then
  full_cmd+=" ${EXTRA_ARGS_STR}"
fi
full_cmd+=" ${STAGE}"
echo "Remote bootstrap command: /tmp/cluster_bootstrap.sh${EXTRA_ARGS_STR:+ ${EXTRA_ARGS_STR}} ${STAGE}"

set +e
"${SSH_CMD[@]}" "$TARGET" "$full_cmd" | tee "$log_file"
pipe_status=("${PIPESTATUS[@]}")
set -e

run_rc=${pipe_status[0]:-0}
ln -sf "$log_file" "$latest_stage_link"
ln -sf "$log_file" "$latest_cluster_link"
ln -sf "$log_file" "$latest_global_link"

echo "Log symlinks: stage=$latest_stage_link cluster=$latest_cluster_link latest=$latest_global_link"
echo "HARNESS_END exit=${run_rc} log=${log_file}"

# Generate a compact run summary for observability.
ai/scripts/executor/run_summary.py \
  --run-id "$run_iso" \
  --run-label "$timestamp" \
  --log-file "$log_file" \
  --target "$CLUSTER" \
  --component "ai_harness" \
  --stage "stage_1" \
  --exit-code "$run_rc" \
  --status-file "ai/state/status.json" \
  --backlog-file "ai/backlog.yaml" \
  --last-run-file "ai/state/last_run.log" \
  --summary-limit 5 || true

exit "${run_rc}"
