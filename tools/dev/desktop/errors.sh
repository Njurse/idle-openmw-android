#!/usr/bin/env bash
# Scan the OpenMW log for the things that mean the mod is broken.
#
# This is the fast pass/fail for "does the mod load and run cleanly on the real
# engine". A Lua error in a PLAYER script shows up here as a traceback, and the
# engine keeps running -- so a green screenshot can hide a broken script. That is
# exactly the failure this script exists to catch.
#
# Usage:
#   bash tools/dev/desktop/errors.sh          # exit 1 if anything is wrong
#   bash tools/dev/desktop/errors.sh --all    # also print the matching lines

set -euo pipefail

CONFIG_DIR="${OMW_CONFIG_DIR:-$USERPROFILE/Documents/My Games/OpenMW}"
LOG="$CONFIG_DIR/openmw.log"
SHOW_ALL=0
[[ "${1:-}" == "--all" ]] && SHOW_ALL=1

[[ -f "$LOG" ]] || { echo "no log at $LOG (has the engine run?)" >&2; exit 1; }

# Patterns that mean a real problem. Kept deliberately narrow: OpenMW logs plenty
# of noise (missing optional sounds, shader permutations on some GPUs) that is
# not ours to fix.
PATTERN='idle_openmw|scripts\.idle|scripts\.runtime|Lua error|Lua warning|stack traceback|Traceback|attempt to (index|call|perform|compare)|nil value|bad argument|onUpdate|onLoad'

hits="$(grep -n -i -E "$PATTERN" "$LOG" || true)"

# Distinguish "our content loaded" (good, must be present) from errors.
loaded="$(grep -c -E 'Loading content file .*idle_openmw\.omwscripts' "$LOG" || true)"
# Exclude the bridge's own ANSWER channel (`IDLEAPI {...}`) from the error scan: a JSON string may
# legitimately contain words like "bad argument" -- that is an engine error we are REPORTING, not
# a Lua error we are dying from. A real Lua traceback never arrives on that channel, so filtering
# it keeps this scan about the mod's scripts and removes a false positive that hid them.
errors="$(grep -n -i -E 'Lua error|stack traceback|Traceback|attempt to |bad argument|nil value' "$LOG" | grep -v 'IDLEAPI ' || true)"

echo "== content =="
if [[ "${loaded:-0}" -ge 1 ]]; then
  echo "  ok    idle_openmw.omwscripts was loaded"
else
  echo "  FAIL  idle_openmw.omwscripts was NOT loaded (check openmw.cfg + data path)"
fi

echo
echo "== lua =="
if [[ -n "$errors" ]]; then
  echo "  FAIL  Lua errors found:"
  printf '%s\n' "$errors" | sed 's/^/    /'
else
  echo "  ok    no Lua errors"
fi

if [[ "$SHOW_ALL" -eq 1 ]]; then
  echo
  echo "== all mod-related lines =="
  if [[ -n "$hits" ]]; then printf '%s\n' "$hits" | sed 's/^/  /'; else echo "  (none)"; fi
fi

if [[ "${loaded:-0}" -ge 1 && -z "$errors" ]]; then
  echo
  echo "OK"
  exit 0
fi
echo
echo "PROBLEMS"
exit 1
