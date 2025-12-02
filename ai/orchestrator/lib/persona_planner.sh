#!/usr/bin/env bash
set -euo pipefail

persona_planner_handle(){
  local tid="$1" type="$2" target="$3" desc="$4" ts="$5" log_file="$6"
  set_task_status "$tid" "running"
  update_current_task "$tid" "planner" "running" "$desc"

  if [ ! -f "$target" ]; then
    set_task_status "$tid" "failed" "patch missing"
    append_last_run "[$ts] ${tid} failed (missing patch)"
    update_current_task "$tid" "planner" "failed" "$desc"
    return 1
  fi

  # Load auto-approve paths
  local auto_paths
  auto_paths=$(yaml_get_planner_autoapprove_paths)

  # Basic size/paths checks
  local patch_lines orig_target=""
  patch_lines=$(wc -l < "$target" | tr -d ' ')
  local touched_ok=1
  while read -r line; do
    [[ "$line" =~ ^\*\*\*\ Update\ File:\  ]] || continue
    file="${line#*** Update File: }"
    [ -z "$orig_target" ] && orig_target="$file"
    ok=1
    for p in $(echo "$auto_paths" | jq -r '.[]'); do
      [[ "$file" == "$p"* ]] && ok=0 && break
    done
    if [ "$ok" -ne 0 ]; then touched_ok=0; break; fi
  done < "$target"

  if [ "$touched_ok" -eq 0 ] || [ "$patch_lines" -gt 200 ]; then
    # reject, request revision
    set_task_status "$tid" "failed" "planner rejected; needs revision"
    local rev_target
    rev_target="${orig_target:-${target##ai/patches/}}"
    append_revision_task "$tid" "$rev_target" "Planner rejected patch"
    append_last_run "[$ts] ${tid} rejected"
    update_current_task "$tid" "planner" "failed" "$desc"
    return 1
  fi

  # approve
  set_task_status "$tid" "completed" "approved by planner"
  append_apply_task "$tid" "$target"
  append_last_run "[$ts] ${tid} approved"
  update_current_task "$tid" "planner" "completed" "$desc"
}
