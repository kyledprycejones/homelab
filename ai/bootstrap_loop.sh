#!/usr/bin/env bash
# Orchestrator v2 - Bootstrap Loop (Plumbing Layer)
#
# This script is the main entry point for running stages. It is deliberately
# "dumb" - it runs commands, logs results, computes error hashes, and decides
# when to escalate. It does NOT make intelligent decisions.
#
# Usage: ./ai/bootstrap_loop.sh <stage> [options]
# Stages: vms, talos, infra, apps, ingress, obs
#
# Safety: This file is considered plumbing and should only be modified by humans.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# =============================================================================
# Configuration
# =============================================================================
: "${CONTEXT_MAP:=ai/context_map.yaml}"
: "${STATE_DIR:=ai/state}"
: "${LOG_DIR:=ai/logs}"
: "${ESCALATION_DIR:=ai/escalations}"
: "${ERRORS_JSON:=${STATE_DIR}/errors.json}"
: "${STAGE_STATUS_JSON:=${STATE_DIR}/stage_status.json}"
: "${EXECUTOR_RUNNER:=ai/executor_runner.sh}"
: "${API_CLIENT:=ai/api_client.sh}"
: "${CASE_FILE_GENERATOR:=ai/case_file_generator.sh}"
: "${DIAGNOSTICS_RUNNER:=ai/diagnostics_runner.sh}"

# Escalation thresholds
: "${EXECUTOR_RETRY_THRESHOLD:=3}"
: "${API_CALL_BUDGET:=3}"

# Branch for AI-driven changes
: "${AI_BRANCH:=ai/orchestrator-stage1}"

# =============================================================================
# Helpers
# =============================================================================
log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[%s] %s\n' "$ts" "$*"
}

log_to_file() {
  local file="$1"
  shift
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[%s] %s\n' "$ts" "$*" >> "$file"
}

ensure_directories() {
  mkdir -p "$STATE_DIR" "$LOG_DIR" "$ESCALATION_DIR"
  mkdir -p "$LOG_DIR/talos" "$LOG_DIR/vms" "$LOG_DIR/infra" "$LOG_DIR/apps" "$LOG_DIR/ingress" "$LOG_DIR/obs"
  mkdir -p "$LOG_DIR/diagnostics"
}

ensure_state_files() {
  if [ ! -f "$ERRORS_JSON" ]; then
    echo '{}' > "$ERRORS_JSON"
  fi
  if [ ! -f "$STAGE_STATUS_JSON" ]; then
    cat > "$STAGE_STATUS_JSON" <<'EOF'
{
  "vms": "idle",
  "talos": "idle",
  "infra": "idle",
  "apps": "idle",
  "ingress": "idle",
  "obs": "idle"
}
EOF
  fi
}

# =============================================================================
# Error Hashing
# =============================================================================
compute_error_hash() {
  local log_file="$1"
  local tail_lines="${2:-100}"
  if [ ! -f "$log_file" ]; then
    echo "no_log_file"
    return
  fi
  tail -n "$tail_lines" "$log_file" | md5 2>/dev/null || tail -n "$tail_lines" "$log_file" | md5sum | awk '{print $1}'
}

get_error_attempts() {
  local stage="$1"
  local error_hash="$2"
  local key="${stage}_${error_hash}"
  if [ ! -f "$ERRORS_JSON" ]; then
    echo "0"
    return
  fi
  python3 -c "
import json, sys
try:
    data = json.load(open('$ERRORS_JSON'))
    key = '$key'
    if key in data:
        print(data[key].get('attempts', 0))
    else:
        print(0)
except:
    print(0)
"
}

get_error_last_source() {
  local stage="$1"
  local error_hash="$2"
  local key="${stage}_${error_hash}"
  if [ ! -f "$ERRORS_JSON" ]; then
    echo "none"
    return
  fi
  python3 -c "
import json
try:
    data = json.load(open('$ERRORS_JSON'))
    key = '$key'
    if key in data:
        print(data[key].get('last_source', 'none'))
    else:
        print('none')
except:
    print('none')
"
}

get_api_call_count() {
  local stage="$1"
  local error_hash="$2"
  local key="${stage}_${error_hash}"
  if [ ! -f "$ERRORS_JSON" ]; then
    echo "0"
    return
  fi
  python3 -c "
import json
try:
    data = json.load(open('$ERRORS_JSON'))
    key = '$key'
    if key in data:
        print(data[key].get('api_calls', 0))
    else:
        print(0)
except:
    print(0)
"
}

update_error_state() {
  local stage="$1"
  local error_hash="$2"
  local source="$3"  # executor or api
  local increment_api="${4:-false}"
  local key="${stage}_${error_hash}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  python3 - "$ERRORS_JSON" "$key" "$source" "$ts" "$increment_api" <<'PY'
import json
import sys

path, key, source, ts, increment_api = sys.argv[1:6]
try:
    with open(path, 'r') as f:
        data = json.load(f)
except:
    data = {}

if key not in data:
    data[key] = {"attempts": 0, "api_calls": 0, "last_source": "none", "last_transition": ""}

data[key]["attempts"] = data[key].get("attempts", 0) + 1
data[key]["last_source"] = source
data[key]["last_transition"] = ts

if increment_api == "true":
    data[key]["api_calls"] = data[key].get("api_calls", 0) + 1

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
PY
}

reset_error_state() {
  local stage="$1"
  local error_hash="$2"
  local key="${stage}_${error_hash}"

  python3 - "$ERRORS_JSON" "$key" <<'PY'
import json
import sys

path, key = sys.argv[1:3]
try:
    with open(path, 'r') as f:
        data = json.load(f)
except:
    data = {}

if key in data:
    del data[key]

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
PY
}

# =============================================================================
# Stage Status Management
# =============================================================================
get_stage_status() {
  local stage="$1"
  if [ ! -f "$STAGE_STATUS_JSON" ]; then
    echo "idle"
    return
  fi
  python3 -c "
import json
try:
    data = json.load(open('$STAGE_STATUS_JSON'))
    print(data.get('$stage', 'idle'))
except:
    print('idle')
"
}

set_stage_status() {
  local stage="$1"
  local status="$2"  # idle, running, green, failed, give_up

  python3 - "$STAGE_STATUS_JSON" "$stage" "$status" <<'PY'
import json
import sys

path, stage, status = sys.argv[1:4]
try:
    with open(path, 'r') as f:
        data = json.load(f)
except:
    data = {}

data[stage] = status

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
PY
}

# =============================================================================
# Stage Commands
# =============================================================================
get_stage_command() {
  local stage="$1"
  case "$stage" in
    vms)
      echo "infrastructure/proxmox/vms.sh"
      ;;
    talos)
      echo "infrastructure/proxmox/cluster_bootstrap.sh talos"
      ;;
    infra)
      echo "infrastructure/proxmox/cluster_bootstrap.sh infra"
      ;;
    apps)
      echo "infrastructure/proxmox/cluster_bootstrap.sh apps"
      ;;
    ingress)
      echo "infrastructure/proxmox/cluster_bootstrap.sh apps"  # ingress is part of apps via GitOps
      ;;
    obs)
      echo "infrastructure/proxmox/cluster_bootstrap.sh apps"  # obs is part of apps via GitOps
      ;;
    *)
      echo ""
      ;;
  esac
}

# =============================================================================
# Stage Execution
# =============================================================================
run_stage() {
  local stage="$1"
  local attempt="$2"
  local timestamp
  timestamp="$(date -u +%Y%m%d-%H%M%S)"
  local log_file="${LOG_DIR}/${stage}/${stage}_${timestamp}_attempt${attempt}.log"

  local cmd
  cmd="$(get_stage_command "$stage")"
  if [ -z "$cmd" ]; then
    log "ERROR: Unknown stage '$stage'"
    return 1
  fi

  log "Running stage '$stage' (attempt $attempt)"
  log "Command: $cmd"
  log "Log file: $log_file"

  set_stage_status "$stage" "running"

  set +e
  # Run the command and capture output
  (
    cd "$REPO_ROOT"
    eval "$cmd"
  ) > "$log_file" 2>&1
  local rc=$?
  set -e

  log_to_file "$log_file" "Exit code: $rc"

  echo "$log_file"
  return $rc
}

# =============================================================================
# Executor Handoff
# =============================================================================
call_executor() {
  local stage="$1"
  local log_file="$2"
  local error_hash="$3"

  log "Handing off to Executor for local fix attempt"

  if [ ! -x "$EXECUTOR_RUNNER" ]; then
    log "ERROR: Executor runner not found or not executable: $EXECUTOR_RUNNER"
    return 1
  fi

  "$EXECUTOR_RUNNER" "$stage" "$log_file" "$error_hash"
}

# =============================================================================
# API Escalation
# =============================================================================
trigger_api_escalation() {
  local stage="$1"
  local log_file="$2"
  local error_hash="$3"
  local case_version="${4:-1}"
  local diagnostics_dir="${5:-}"

  log "Triggering API escalation (case v${case_version})"

  local timestamp
  timestamp="$(date -u +%Y%m%d-%H%M%S)"
  local case_file="${ESCALATION_DIR}/${stage}_${timestamp}_case_v${case_version}.md"

  # Generate case file
  if [ ! -x "$CASE_FILE_GENERATOR" ]; then
    log "ERROR: Case file generator not found: $CASE_FILE_GENERATOR"
    return 1
  fi

  if [ "$case_version" = "1" ]; then
    "$CASE_FILE_GENERATOR" "$stage" "$log_file" "$case_file"
  else
    "$CASE_FILE_GENERATOR" "$stage" "$log_file" "$case_file" "$diagnostics_dir"
  fi

  # Call API
  if [ ! -x "$API_CLIENT" ]; then
    log "ERROR: API client not found: $API_CLIENT"
    return 1
  fi

  local patch_file="${ESCALATION_DIR}/${stage}_${timestamp}_patch.diff"
  local response_file="${ESCALATION_DIR}/${stage}_${timestamp}_response.json"

  "$API_CLIENT" "$case_file" "$patch_file" "$response_file"
  local api_rc=$?

  # Check response type
  if [ "$api_rc" -eq 0 ] && [ -f "$response_file" ]; then
    local response_type
    response_type="$(python3 -c "import json; print(json.load(open('$response_file')).get('type', 'unknown'))" 2>/dev/null || echo "unknown")"

    if [ "$response_type" = "patch" ] && [ -f "$patch_file" ]; then
      echo "patch:$patch_file"
      return 0
    elif [ "$response_type" = "diagnostics" ]; then
      echo "diagnostics:$response_file"
      return 0
    fi
  fi

  echo "error"
  return 1
}

# =============================================================================
# Diagnostics Execution
# =============================================================================
run_diagnostics() {
  local stage="$1"
  local response_file="$2"

  log "Running diagnostics requested by API"

  if [ ! -x "$DIAGNOSTICS_RUNNER" ]; then
    log "ERROR: Diagnostics runner not found: $DIAGNOSTICS_RUNNER"
    return 1
  fi

  local timestamp
  timestamp="$(date -u +%Y%m%d-%H%M%S)"
  local diag_dir="${LOG_DIR}/diagnostics/${stage}_${timestamp}"

  "$DIAGNOSTICS_RUNNER" "$response_file" "$diag_dir"

  echo "$diag_dir"
}

# =============================================================================
# Patch Application
# =============================================================================
apply_patch() {
  local patch_file="$1"

  log "Applying patch: $patch_file"

  # Ensure we're on the AI branch
  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"

  if [ "$current_branch" != "$AI_BRANCH" ]; then
    log "Switching to AI branch: $AI_BRANCH"
    git checkout -B "$AI_BRANCH" 2>/dev/null || git checkout "$AI_BRANCH" 2>/dev/null || {
      log "Creating new AI branch from current HEAD"
      git checkout -b "$AI_BRANCH"
    }
  fi

  # Apply the patch
  if git apply --check "$patch_file" 2>/dev/null; then
    git apply "$patch_file"
    git add -A
    local commit_msg="[orchestrator] Apply patch from API escalation

Source: $patch_file
Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    git commit -m "$commit_msg"
    log "Patch applied and committed"
    return 0
  else
    log "ERROR: Patch does not apply cleanly"
    return 1
  fi
}

# =============================================================================
# Main Orchestration Loop for a Single Stage
# =============================================================================
orchestrate_stage() {
  local stage="$1"

  log "=== Orchestrating stage: $stage ==="

  ensure_directories
  ensure_state_files

  local current_status
  current_status="$(get_stage_status "$stage")"

  if [ "$current_status" = "green" ]; then
    log "Stage '$stage' is already green. Skipping."
    return 0
  fi

  if [ "$current_status" = "give_up" ]; then
    log "Stage '$stage' is in give_up state. Human intervention required."
    return 1
  fi

  local attempt=1
  local max_total_attempts=20  # Safety limit

  while [ "$attempt" -le "$max_total_attempts" ]; do
    log "--- Attempt $attempt for stage '$stage' ---"

    # Run the stage
    local log_file
    set +e
    log_file="$(run_stage "$stage" "$attempt")"
    local stage_rc=$?
    set -e

    if [ "$stage_rc" -eq 0 ]; then
      log "Stage '$stage' succeeded!"
      set_stage_status "$stage" "green"
      return 0
    fi

    log "Stage '$stage' failed (rc=$stage_rc)"
    set_stage_status "$stage" "failed"

    # Compute error hash
    local error_hash
    error_hash="$(compute_error_hash "$log_file")"
    log "Error hash: $error_hash"

    # Get current error state
    local error_attempts
    error_attempts="$(get_error_attempts "$stage" "$error_hash")"
    local last_source
    last_source="$(get_error_last_source "$stage" "$error_hash")"
    local api_calls
    api_calls="$(get_api_call_count "$stage" "$error_hash")"

    log "Error state: attempts=$error_attempts, last_source=$last_source, api_calls=$api_calls"

    # Decision: New error or repeated error?
    if [ "$error_attempts" -lt "$EXECUTOR_RETRY_THRESHOLD" ]; then
      # New/recent error - Executor handles it
      log "Error is new/recent (attempts < $EXECUTOR_RETRY_THRESHOLD). Executor will attempt fix."
      update_error_state "$stage" "$error_hash" "executor"

      set +e
      call_executor "$stage" "$log_file" "$error_hash"
      local executor_rc=$?
      set -e

      if [ "$executor_rc" -ne 0 ]; then
        log "Executor did not produce a fix"
      fi

    else
      # Repeated error - escalate to API
      if [ "$api_calls" -ge "$API_CALL_BUDGET" ]; then
        log "API call budget exhausted ($api_calls >= $API_CALL_BUDGET). Marking as give_up."
        set_stage_status "$stage" "give_up"
        return 1
      fi

      log "Error is repeated (attempts >= $EXECUTOR_RETRY_THRESHOLD). Escalating to API."
      update_error_state "$stage" "$error_hash" "api" "true"

      # First API call with Case File v1
      set +e
      local api_response
      api_response="$(trigger_api_escalation "$stage" "$log_file" "$error_hash" "1")"
      set -e

      local response_type="${api_response%%:*}"
      local response_data="${api_response#*:}"

      if [ "$response_type" = "patch" ]; then
        # Apply the patch
        set +e
        apply_patch "$response_data"
        local patch_rc=$?
        set -e

        if [ "$patch_rc" -eq 0 ]; then
          # Reset error counters for this hash - we got a new fix
          reset_error_state "$stage" "$error_hash"
          log "Patch applied. Re-running stage."
        else
          log "Failed to apply patch"
        fi

      elif [ "$response_type" = "diagnostics" ]; then
        # Run diagnostics and send Case File v2
        local diag_dir
        diag_dir="$(run_diagnostics "$stage" "$response_data")"

        api_calls="$(get_api_call_count "$stage" "$error_hash")"
        if [ "$api_calls" -ge "$API_CALL_BUDGET" ]; then
          log "API call budget exhausted after diagnostics. Marking as give_up."
          set_stage_status "$stage" "give_up"
          return 1
        fi

        update_error_state "$stage" "$error_hash" "api" "true"

        set +e
        api_response="$(trigger_api_escalation "$stage" "$log_file" "$error_hash" "2" "$diag_dir")"
        set -e

        response_type="${api_response%%:*}"
        response_data="${api_response#*:}"

        if [ "$response_type" = "patch" ]; then
          set +e
          apply_patch "$response_data"
          patch_rc=$?
          set -e

          if [ "$patch_rc" -eq 0 ]; then
            reset_error_state "$stage" "$error_hash"
            log "Patch applied after diagnostics. Re-running stage."
          fi
        fi
      fi
    fi

    attempt=$((attempt + 1))
  done

  log "Maximum attempts reached for stage '$stage'. Marking as give_up."
  set_stage_status "$stage" "give_up"
  return 1
}

# =============================================================================
# Main Entry Point
# =============================================================================
main() {
  if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <stage> [options]"
    echo ""
    echo "Stages:"
    echo "  vms      - Proxmox VM creation/config"
    echo "  talos    - Talos bootstrap"
    echo "  infra    - Flux + core platform components"
    echo "  apps     - Homelab applications"
    echo "  ingress  - Ingress, Cloudflare, DNS"
    echo "  obs      - Observability stack"
    echo "  all      - Run all stages in order"
    echo "  status   - Show current stage status"
    echo ""
    echo "Options:"
    echo "  --reset  - Reset error state for the stage"
    exit 1
  fi

  local stage="$1"
  local reset_mode="${2:-}"

  ensure_directories
  ensure_state_files

  if [ "$stage" = "status" ]; then
    echo "Current stage status:"
    cat "$STAGE_STATUS_JSON"
    echo ""
    echo "Error state:"
    cat "$ERRORS_JSON"
    exit 0
  fi

  if [ "$reset_mode" = "--reset" ]; then
    log "Resetting stage '$stage' to idle"
    set_stage_status "$stage" "idle"
    # Clear all error states for this stage
    python3 - "$ERRORS_JSON" "$stage" <<'PY'
import json
import sys

path, stage = sys.argv[1:3]
try:
    with open(path, 'r') as f:
        data = json.load(f)
except:
    data = {}

keys_to_remove = [k for k in data if k.startswith(stage + "_")]
for k in keys_to_remove:
    del data[k]

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
PY
    log "Reset complete"
    exit 0
  fi

  if [ "$stage" = "all" ]; then
    local stages=("vms" "talos" "infra" "apps" "ingress" "obs")
    for s in "${stages[@]}"; do
      if ! orchestrate_stage "$s"; then
        log "Stage '$s' failed. Stopping."
        exit 1
      fi
    done
    log "All stages completed successfully!"
    exit 0
  fi

  # Validate stage name
  case "$stage" in
    vms|talos|infra|apps|ingress|obs)
      orchestrate_stage "$stage"
      ;;
    *)
      echo "ERROR: Unknown stage '$stage'"
      exit 1
      ;;
  esac
}

main "$@"
