#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG="${BACKEND_LOG:-${REPO_ROOT}/.local/logs/backend.log}"

for _ in $(seq 1 120); do
  if curl -4 -fsS http://127.0.0.1:8065/api/agent/list >/dev/null 2>&1; then
    echo READY
    exit 0
  fi
  if grep -q 'Started DataAgentApplication' "$LOG" 2>/dev/null; then
    echo STARTED
    exit 0
  fi
  if grep -qE 'BUILD FAILURE|APPLICATION FAILED' "$LOG" 2>/dev/null; then
    echo FAILED
    tail -30 "$LOG"
    exit 1
  fi
  sleep 5
done
echo TIMEOUT
tail -30 "$LOG"
exit 1
