#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

. ai/orchestrator/lib/util_yaml.sh
. ai/orchestrator/lib/util_logging.sh

comment_prefix(){
  local path="$1"
  case "$path" in
    *.sh|*.bash|*.zsh|*.env|*.cfg|*.ini)
      echo "#"
      ;;
    *.yaml|*.yml)
      echo "#"
      ;;
    *.md)
      echo "<!--"
      ;;
    *)
      echo "#"
      ;;
  esac
}

set_backlog_status(){
  local tid="$1" state="$2" note="$3"
  local payload
  payload="$(jq -n --arg status "$state" --arg note "$note" '{status:$status,note:$note}')"
  yaml_update_task "$tid" "$payload"
}

main(){
  if [ "$#" -lt 1 ]; then
    echo "Usage: persona_engineer.sh TASK_ID" >&2
    exit 1
  fi
  local task_id="$1"
  local task_json
  task_json="$(yaml_get_task "$task_id")" || { echo "Engineer task $task_id missing" >&2; exit 1; }
  local target summary detail
  target="$(echo "$task_json" | jq -r '.target // ""')"
  summary="$(echo "$task_json" | jq -r '.summary // "engineer task"')"
  detail="$(echo "$task_json" | jq -r '.detail // ""')"

  log_persona_event "engineer" "$task_id" "running" "$summary" >/dev/null
  set_backlog_status "$task_id" "running" "$summary"
  update_current_task "$task_id" "engineer" "running" "$summary" "{\"target\":\"$target\"}"

  if [ -z "$target" ]; then
    local note="Engineers require a target file"
    set_backlog_status "$task_id" "failed" "$note"
    update_current_task "$task_id" "engineer" "failed" "$note"
    log_persona_event "engineer" "$task_id" "failed" "$note"
    exit 0
  fi

  if [ ! -f "$target" ]; then
    local note="Target $target missing"
    set_backlog_status "$task_id" "failed" "$note"
    update_current_task "$task_id" "engineer" "failed" "$note"
    log_persona_event "engineer" "$task_id" "failed" "$note"
    exit 0
  fi

  local prefix
  prefix="$(comment_prefix "$target")"
  local marker="${prefix} PLANNER ${task_id}"
  if grep -qF "$marker" "$target"; then
    local note="Marker already present"
    set_backlog_status "$task_id" "success" "$note"
    update_current_task "$task_id" "engineer" "success" "$note"
    log_persona_event "engineer" "$task_id" "success" "$note"
    exit 0
  fi

  {
    printf '\n%s %s\n' "$marker" "$summary"
    printf '%s Detail: %s\n' "$prefix" "$detail"
    printf '%s applied at %s\n' "$prefix" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >> "$target"

  local note="Appended minimal comment"
  set_backlog_status "$task_id" "success" "$note"
  update_current_task "$task_id" "engineer" "success" "$note"
  log_persona_event "engineer" "$task_id" "success" "$note"
}

main "$@"
