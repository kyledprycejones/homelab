#!/usr/bin/env bash
set -euo pipefail

LOG_FILE=${1:-}
if [ -z "$LOG_FILE" ]; then
  LOG_FILE=$(ls -1t logs/executor/executor-*.log 2>/dev/null | head -n1 || true)
  if [ -z "$LOG_FILE" ]; then
    # Legacy hands logs fallback
    LOG_FILE=$(ls -1t logs/hands/hands-*.log 2>/dev/null | head -n1 || true)
  fi
fi
if [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ]; then
  echo "No executor log available" >&2
  exit 1
fi

PROMPT="You are the Narrator. Summarize these CLI run logs into a human-friendly story.\nKeep it under 300 tokens. Do not include raw commands unless essential.\n"

cat "$LOG_FILE" | codex exec --sandbox workspace-write --message "$PROMPT"
