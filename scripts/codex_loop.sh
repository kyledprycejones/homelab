#!/usr/bin/env bash
# Thin wrapper for backward compatibility; delegates to orchestrator_loop.sh
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/orchestrator_loop.sh" "$@"
