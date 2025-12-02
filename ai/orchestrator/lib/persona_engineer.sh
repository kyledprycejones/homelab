#!/usr/bin/env bash
set -euo pipefail

_comment_prefix_for(){
  local path="$1"
  case "$path" in
    *.sh|*.bash|*.env|*.cfg|*.ini) echo "#";;
    *.yaml|*.yml) echo "#";;
    *.md) echo "<!--";;
    *) echo "#";;
  esac
}

engineer_generate_patch(){
  local tid="$1" target="$2" desc="$3" err_tail="$4" err_type="$5"
  local patch_file="${PATCH_DIR}/${tid}.diff"
  local prefix
  prefix=$(_comment_prefix_for "$target")
  local note
  note="${prefix} Engineer note for ${tid}: ${desc}; error_type=${err_type}; tail=${err_tail}"
  if [ ! -f "$target" ]; then
    cat > "$patch_file" <<PATCH
*** Begin Patch
*** Add File: $target
+$note
*** End Patch
PATCH
    echo "$patch_file"
    return
  fi
  # grab first ~120 lines for context (best-effort)
  local tmp_context
  tmp_context=$(python3 - "$target" <<'PY'
import sys
path=sys.argv[1]
lines=open(path,encoding='utf-8').read().splitlines()
print("\n".join(lines[:120]))
PY
)
  cat > "$patch_file" <<PATCH
*** Begin Patch
*** Update File: $target
@@
+$note
*** End Patch
PATCH
  echo "$patch_file"
}

persona_engineer_handle(){
  local tid="$1" type="$2" target="$3" desc="$4" ts="$5" log_file="$6"
  set_task_status "$tid" "running"
  update_current_task "$tid" "engineer" "running" "$desc"

  # Allowed paths
  local allowed forbidden
  allowed=$(yaml_get_persona_config engineer allowed_paths "[]")
  forbidden=$(yaml_get_persona_config engineer forbidden_paths "[]")
  path_allowed(){
    local path="$1"; local ok=1
    for p in $(echo "$allowed" | jq -r '.[]'); do [[ "$path" == "$p"* ]] && ok=0 && break; done
    if [ "$ok" -ne 0 ]; then return 1; fi
    for f in $(echo "$forbidden" | jq -r '.[]'); do [[ "$path" == "$f"* ]] && return 1; done
    return 0
  }
  if [ -n "$target" ] && ! path_allowed "$target"; then
    set_task_status "$tid" "failed" "engineer: target not allowed"
    update_current_task "$tid" "engineer" "failed" "$desc"
    append_last_run "[$ts] ${tid} failed (target not allowed)"
    return 1
  fi

  # Gather error context
  local err_tail err_type err_hash
  err_tail="$(jq -r '.stderr_tail // ""' "$LAST_ERROR_FILE" 2>/dev/null)"
  err_type="$(jq -r '.classification // "unknown"' "$LAST_ERROR_FILE" 2>/dev/null)"
  err_hash="$(jq -r '.error_hash // ""' "$LAST_ERROR_FILE" 2>/dev/null)"

  local patch_file
  patch_file=$(engineer_generate_patch "$tid" "$target" "$desc" "$err_tail" "$err_type")

  # Move to review and enqueue planner task
  set_task_status "$tid" "review" "patch generated"
  append_planner_task "$tid" "$patch_file"
  append_last_run "[$ts] ${tid} patch ready for review"
  update_current_task "$tid" "engineer" "review" "$desc"
}
