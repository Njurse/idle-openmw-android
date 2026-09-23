#!/usr/bin/env bash
# Put the engine straight into the WORLD, with the world running (not paused at chargen).
#
# WHY THIS IS A SEPARATE SCRIPT FROM new-game.sh
# `new-game.sh` runs the real character creation and then pokes the console to skip it. That is
# the faithful flow, and it is what you want when the thing under test is chargen itself.
#
# This script exists for when the thing under test is the WORLD: walking, pathfinding, looking,
# using doors. It relies on a documented engine behaviour: `--skip-menu=1` WITHOUT `--new-game`
# makes the state manager bypass character creation outright
# (apps/openmw/apps/openmw/engine.cpp:1029 -> StateManager::newGame(bypass=true), and
# statemanagerimp.cpp:164 sets chargenstate = -1), so the game loads into the starting cell with
# the world ticking and `dt > 0`.
#
# That is a test shortcut, not the real flow: it skips chargen rather than driving it. Anything
# that needs chargen itself must use new-game.sh.
#
# Usage:
#   bash tools/dev/desktop/into-world.sh            # launch into the world, wait for it
#   bash tools/dev/desktop/into-world.sh --keep-log # do not truncate openmw.log first
#   bash tools/dev/desktop/into-world.sh --stop     # kill any running engine and exit

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
EXE="${OMW_EXE:-F:/Games/OpenMW-0.51/openmw.exe}"
CONFIG_DIR="${OMW_CONFIG_DIR:-$USERPROFILE/Documents/My Games/OpenMW}"
LOG="$CONFIG_DIR/openmw.log"

winpath() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$p"; else echo "$p"; fi
}
psarg() {
  local p="$1"
  if [[ "$p" == *" "* ]]; then printf '"%s"' "$p"; else printf '%s' "$p"; fi
}

stop_engine() {
  powershell.exe -NoProfile -Command \
    "Stop-Process -Name openmw -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
}

if [[ "${1:-}" == "--stop" ]]; then
  stop_engine
  echo "== engine stopped"
  exit 0
fi

keep_log=0
cell=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-log) keep_log=1; shift ;;
    # --cell NAME starts the player inside that cell. Combined with --skip-menu=1 (which bypasses
    # character creation) this is how you get a RUNNING world inside the ship, which is the only
    # state in which "walk out of the ship" can be tested: chargen leaves the world paused.
    --cell) cell="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -x "$EXE" && ! -f "$EXE" ]]; then
  echo "no engine at $EXE (set OMW_EXE)" >&2
  exit 2
fi

stop_engine
sleep 3

if [[ $keep_log -eq 1 ]]; then
  echo "== keeping the old log"
else
  # Truncate rather than delete: a running engine holds the handle, and a stale log makes every
  # pattern-wait below match the PREVIOUS run's lines and report success instantly.
  : > "$LOG" 2>/dev/null || true
  if [[ -s "$LOG" ]]; then
    echo "could not truncate $LOG -- is an engine still running?" >&2
    exit 3
  fi
fi

where="the default start"
[[ -n "$cell" ]] && where="$cell"
echo "== launching into the world (--skip-menu=1, chargen bypassed, start: $where)"
# A PowerShell ARRAY, not a comma-joined string: with `-ArgumentList '--start=Imperial Prison
# Ship'` PowerShell splits on the space and the engine looks for a cell called "Imperial"
# ("Failed to start new game: Interior cell is not found: 'Imperial'"). Inside @(...) each
# element is passed as one argument and the spaces survive.
args="@('--skip-menu=1'"
if [[ -n "$cell" ]]; then
  # quoted: cell names contain spaces ("Imperial Prison Ship"), and PowerShell splits on them
  # The DOUBLE quotes have to be part of the element: Start-Process joins -ArgumentList back
  # into one command line, so quotes that only existed around the PowerShell element are gone by
  # the time the engine parses it -- which is why it looked for a cell called "Imperial".
  args="$args,'--start=\"$cell\"'"
fi
args="$args,'--user-data',$(psarg "$(winpath "$CONFIG_DIR")"))"
powershell.exe -NoProfile -Command \
  "Start-Process -FilePath '$(winpath "$EXE")' -ArgumentList $args" \
  >/dev/null 2>&1

# Wait for the MOD to say it is in the world, not merely for the process to exist: the mod's
# phase line is the only evidence that the Lua we are testing actually loaded.
deadline=$((SECONDS + 90))
while [[ $SECONDS -lt $deadline ]]; do
  if grep -q "idle-openmw: world running" "$LOG" 2>/dev/null; then
    echo "== in the world after $((90 - (deadline - SECONDS)))s"
    grep -oE "idle-openmw: .{0,90}" "$LOG" | tail -4
    exit 0
  fi
  sleep 2
done

echo "== TIMED OUT waiting for 'world running'; last lines:" >&2
tail -12 "$LOG" >&2
exit 4
