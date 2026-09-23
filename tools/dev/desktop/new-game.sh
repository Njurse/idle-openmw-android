#!/usr/bin/env bash
# Get from "engine not running" to "in the world, at the start of the game", with no
# menu and no intro, and optionally leave behind a save to reload instantly.
#
# WHY THIS EXISTS
# ---------------
# Driving Morrowind's main menu and its five character-creation dialogs by hand is slow
# and fragile. The engine has flags that remove almost all of it:
#
#   --skip-menu=1     do not show the main menu at all
#   --new-game=1      run the new game sequence straight away (needs skip-menu)
#
# That still runs the chargen dialogs, so this script finishes them the way a player
# would with the console: `set chargenstate -1` marks character creation complete and
# `EnablePlayerControls` gives control back. Our mod reads the same flag
# (types.Player.isCharGenFinished == chargenstate == -1), so the mod's phase flips to
# `world` and its console appears.
#
# Then, if asked, it quicksaves (F5) so later runs can start instantly with
# `--load-savegame` instead of redoing any of this.
#
# Usage:
#   bash tools/dev/desktop/new-game.sh              # new game -> in the world
#   bash tools/dev/desktop/new-game.sh --save       # ... and quicksave for later
#   bash tools/dev/desktop/new-game.sh --no-skip    # let chargen run (to test the gate)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
EXE="${OMW_EXE:-F:/Games/OpenMW-0.51/openmw.exe}"
CONFIG_DIR="${OMW_CONFIG_DIR:-$USERPROFILE/Documents/My Games/OpenMW}"
LOG="$CONFIG_DIR/openmw.log"
SAVE=0
SKIP=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --save) SAVE=1 ;;
    --no-skip) SKIP=0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

IN="$REPO/tools/dev/desktop/input.py"

echo "== stopping any running engine"
taskkill //IM openmw.exe //F >/dev/null 2>&1 || true
sleep 2

# Clear the log by TRUNCATING it, not deleting: on Windows `rm` fails silently while a
# dying process still holds the handle, and the stale content then makes every
# pattern-wait match instantly against the PREVIOUS run's lines. That looked exactly
# like "the game started" and sent me chasing a dialog that was not there.
: > "$LOG" || true
if [[ -s "$LOG" ]]; then
  echo "!! could not clear $LOG (still $(wc -c < "$LOG") bytes); stale lines will fool waits" >&2
  exit 1
fi

echo "== launching a new game (--skip-menu=1 --new-game=1)"
powershell.exe -NoProfile -Command \
  "Start-Process -FilePath '$(cygpath -w "$EXE" 2>/dev/null || echo "$EXE")' -ArgumentList '--skip-menu=1','--new-game=1','--user-data','$(cygpath -w "$CONFIG_DIR" 2>/dev/null || echo "$CONFIG_DIR")'" \
  >/dev/null 2>&1 </dev/null

echo "== waiting for the world to start loading"
python tools/dev/desktop/wait.py --log-regex "Loading cell|Starting a new game" \
  --timeout 180 --interval 1 || { echo "!! the game never started"; exit 1; }

# give the chargen dialogs a moment to actually appear before typing at them
python tools/dev/desktop/wait.py --log-regex "chargen" --timeout 60 --interval 0.5 || true
sleep 3

# pin the window to the primary screen: a window on a secondary monitor renders nothing
# capturable, and the click/tap coordinate maths assumes one known space.
python "$IN" --place 40,40 --probe 2>&1 | tail -3

if [[ "$SKIP" -eq 1 ]]; then
  echo "== skipping character creation via the console"
  # OpenMW's console is the grave/backtick key (bindingsmanager.cpp:268).
  python "$IN" --key GRAVE >/dev/null
  sleep 1
  python "$IN" --type "set chargenstate -1" >/dev/null
  python "$IN" --key ENTER >/dev/null
  sleep 1
  python "$IN" --type "EnablePlayerControls" >/dev/null
  python "$IN" --key ENTER >/dev/null
  sleep 1
  python "$IN" --key GRAVE >/dev/null
  sleep 2
fi

echo "== waiting for the mod to report the world phase"
if python tools/dev/desktop/wait.py --log-regex "idle-openmw: phase -> world" \
     --timeout 90 --interval 0.5; then
  echo "   in the world; the console should be up"
else
  echo "   (phase line not seen -- is the mod installed? check tools/dev/desktop/errors.sh)"
fi

if [[ "$SAVE" -eq 1 ]]; then
  echo "== quicksaving (F5) so later runs can --load-savegame"
  python "$IN" --key F5 >/dev/null
  sleep 3
  ls -t "$CONFIG_DIR/saves/" 2>/dev/null | head -3 | sed 's/^/   /'
fi

echo
echo "== log, last few mod lines"
grep -oE "idle-openmw: .*" "$LOG" | tail -5 || true
echo
echo "== screenshot"
python "$IN" --key F12 >/dev/null 2>&1 || true
sleep 2
ls -t "$CONFIG_DIR/screenshots/"*.png 2>/dev/null | head -1
