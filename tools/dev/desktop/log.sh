#!/usr/bin/env bash
# Show the OpenMW engine log (openmw.log lives in the user config dir).
#
# Usage:
#   bash tools/dev/desktop/log.sh            # last 40 lines
#   bash tools/dev/desktop/log.sh 200        # last 200 lines
#   bash tools/dev/desktop/log.sh --grep idle   # lines matching a pattern
#   bash tools/dev/desktop/log.sh --follow   # tail -f

set -euo pipefail

CONFIG_DIR="${OMW_CONFIG_DIR:-$USERPROFILE/Documents/My Games/OpenMW}"
LOG="$CONFIG_DIR/openmw.log"

[[ -f "$LOG" ]] || { echo "no log at $LOG (has the engine run?)" >&2; exit 1; }
echo "# $LOG  ($(wc -l < "$LOG") lines, mtime $(date -r "$LOG" '+%H:%M:%S'))"
echo

case "${1:-}" in
  --follow) tail -f "$LOG" ;;
  --grep)   grep -n -i -- "${2:-}" "$LOG" || echo "(no match: $2)" ;;
  "")       tail -n 40 "$LOG" ;;
  *)        tail -n "$1" "$LOG" ;;
esac
