#!/usr/bin/env bash
set -euo pipefail

BACKLOG_PATH="${1:-ai/backlog.yaml}"

validate_yaml(){
  python3 - <<PY
import pathlib
import sys
import yaml

path = pathlib.Path("$BACKLOG_PATH")
text = path.read_text(encoding="utf-8")
try:
    yaml.safe_load(text)
    sys.exit(0)
except yaml.YAMLError as exc:
    mark = getattr(exc, "problem_mark", None)
    line_no = mark.line + 1 if mark else None
    col_no = mark.column + 1 if mark else None
    print(f"ERROR: invalid YAML in {path}", file=sys.stderr)
    if line_no is not None and col_no is not None:
      print(f" line {line_no} column {col_no}", file=sys.stderr)
    else:
      print(" line/column not available", file=sys.stderr)
    lines = text.splitlines()
    if line_no is not None:
        start = max(0, line_no - 3)
        end = min(len(lines), line_no + 2)
    else:
        start = 0
        end = min(5, len(lines))
    print("\nContext (±2 lines):", file=sys.stderr)
    for idx in range(start, end):
        prefix = ">" if line_no is not None and idx == line_no - 1 else " "
        print(f"{prefix} {idx+1:4}: {lines[idx]}", file=sys.stderr)
    if not lines and mark:
        print("[line missing]", file=sys.stderr)
    sys.exit(1)
PY
}

validate_yaml
