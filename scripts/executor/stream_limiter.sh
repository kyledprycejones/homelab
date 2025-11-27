#!/usr/bin/env bash
# Filters noisy Codex stdout when AI_VERBOSITY=normal.
set -euo pipefail

VERBOSITY="${AI_VERBOSITY:-normal}"

if [ "$VERBOSITY" = "verbose" ]; then
  cat
  exit 0
fi

while IFS= read -r line; do
  trimmed="${line#"${line%%[![:space:]]*}"}"
  if [[ "$trimmed" =~ ^(===|CMD|RES|FILE|SUMMARY|Persona:|Task:|Objective:|Result:).* ]]; then
    printf '%s\n' "$line"
  elif [[ "$trimmed" =~ ([Ff]ail|[Ee]rror|[Bb]lock|[Ww]arn) ]]; then
    printf '%s\n' "$line"
  fi
done
