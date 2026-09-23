#!/usr/bin/env bash
# Launch (or stop) the OpenMW dev engine with our user config.
#
# Detached by default so the shell returns immediately and the engine keeps
# running for later `log.sh` / `shot.ps1` calls.
#
# Usage:
#   bash tools/dev/desktop/run.sh              # launch (detached)
#   bash tools/dev/desktop/run.sh --fresh-log  # move the old log aside first
#   bash tools/dev/desktop/run.sh --stop       # kill any running openmw.exe
#   bash tools/dev/desktop/run.sh --wait 60    # launch, then wait up to 60s for the log

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
EXE="${OMW_EXE:-F:/Games/OpenMW-0.51/openmw.exe}"
CONFIG_DIR="${OMW_CONFIG_DIR:-$USERPROFILE/Documents/My Games/OpenMW}"
LOG="$CONFIG_DIR/openmw.log"

winpath() { # bash path -> Windows path, for cmd/start
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$p"; else echo "$p"; fi
}

# Quote an argument for PowerShell's -ArgumentList. Without this a path containing a
# space is split, and the engine silently uses a TRUNCATED directory: "Documents/My
# Games/OpenMW" became "Documents/My", so screenshots went to Documents/My/screenshots
# and saves would have gone somewhere wrong too.
psarg() {
  local p="$1"
  if [[ "$p" == *" "* ]]; then printf '"%s"' "$p"; else printf '%s' "$p"; fi
}

fresh=0; wait_secs=0; stop=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fresh-log) fresh=1 ;;
    --stop) stop=1 ;;
    --wait) wait_secs="${2:-60}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ "$stop" -eq 1 ]]; then
  taskkill //IM "$(basename "$EXE")" //F 2>/dev/null || echo "(nothing to stop)"
  exit 0
fi

[[ -x "$EXE" || -f "$EXE" ]] || { echo "!! engine not found: $EXE" >&2; exit 1; }
[[ -f "$CONFIG_DIR/openmw.cfg" ]] || { echo "!! no openmw.cfg in $CONFIG_DIR -- run setup-cfg.sh" >&2; exit 1; }

if [[ "$fresh" -eq 1 ]]; then
  # Truncate rather than delete/move: a dying engine can still hold the handle, and on
  # Windows the removal then fails quietly -- leaving the previous run's lines for the
  # next wait to match against. Clearing the content is what we actually want.
  : > "$LOG" 2>/dev/null || true
  if [[ -s "$LOG" ]]; then
    echo "!! could not clear $LOG -- stale lines may fool log waits" >&2
  else
    echo "cleared previous log"
  fi
fi

echo "launching $(basename "$EXE") --user-data <$CONFIG_DIR>"
# Start-Process detaches properly. `cmd /c start` looks detached but the child
# inherits our stdout/stderr, so a piped caller (… | tail) blocks until the GAME
# exits -- which made every harness call hang until it was killed.
powershell.exe -NoProfile -Command \
  "Start-Process -FilePath '$(winpath "$EXE")' -ArgumentList '--user-data','$(psarg "$(winpath "$CONFIG_DIR")")'" \
  >/dev/null 2>&1 </dev/null

if [[ "$wait_secs" -gt 0 ]]; then
  echo "waiting up to ${wait_secs}s for $LOG ..."
  for _ in $(seq 1 "$wait_secs"); do
    [[ -f "$LOG" ]] && break
    sleep 1
  done
fi

echo "log: $LOG"
[[ -f "$LOG" ]] && tail -n 5 "$LOG" || echo "(no log yet)"
