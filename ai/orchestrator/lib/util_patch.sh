#!/usr/bin/env bash
set -euo pipefail

apply_patch_file(){
  local patch_file="$1" log_file="$2"
  if ! patch -p1 < "$patch_file" >> "$log_file" 2>&1; then
    return 1
  fi
  return 0
}
