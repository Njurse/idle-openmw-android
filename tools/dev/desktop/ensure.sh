#!/usr/bin/env bash
# Make sure exactly one OpenMW dev instance is running, and wait for its window.
#
# Needed because a launched engine does not always survive between tool calls; this
# makes every later step idempotent -- `ensure.sh && input ... && shot.ps1` works
# whether or not the engine was already up.
#
# Usage:
#   bash tools/dev/desktop/ensure.sh [--fresh-log] [--timeout 60]

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FRESH=""
TIMEOUT=60
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fresh-log) FRESH="--fresh-log" ;;
    --timeout) TIMEOUT="$2"; shift ;;
  esac
  shift
done

window_up() {
  powershell.exe -NoProfile -Command \
    "(Get-Process -Name openmw -ErrorAction SilentlyContinue | Where-Object { \$_.MainWindowHandle -ne 0 } | Measure-Object).Count" \
    2>/dev/null | tr -d '\r\n ' | grep -q '^[1-9]'
}

if window_up; then
  echo "engine already up"
else
  echo "engine not running -- launching"
  bash "$REPO/tools/dev/desktop/run.sh" $FRESH >/dev/null 2>&1
fi

for _ in $(seq 1 "$TIMEOUT"); do
  window_up && { echo "window ready"; exit 0; }
  sleep 1
done
echo "!! no OpenMW window after ${TIMEOUT}s" >&2
exit 1
