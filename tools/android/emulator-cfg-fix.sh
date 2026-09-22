#!/usr/bin/env bash
# Un-break the OpenMW-Android launcher's content list, so the engine can launch.
#
# WHY THIS EXISTS
# ---------------
# The launcher regenerates the engine's `openmw.cfg` on every launch from a
# template it keeps in its private data dir:
#
#   /data/user/0/is.xyz.omw_nightly/files/config/openmw.base.cfg
#
# Anything left in that template -- including a `content=` line naming a plugin
# this engine cannot load -- is copied verbatim into the config the engine
# actually reads. A stale `content=idle_openmw.omwscripts` there makes the engine
# die at startup with
#
#   OpenMW: Fatal error
#   Cannot load file: /storage/emulated/0/omwmod/idle_openmw.omwscripts
#
# and NOTHING can run -- not the game, not the launcher's own Play button. The
# launcher's "Mods" screen cannot even show a `.omwscripts` entry to let you
# remove it (its plugin list is esm/esp/omwaddon/omwgame only), so the template is
# the only place to fix it.
#
# Requires `adb root` (works on a google_apis image, not on a PlayStore one).
#
# Usage:
#   bash tools/android/emulator-cfg-fix.sh            # show what would go
#   bash tools/android/emulator-cfg-fix.sh --apply    # back up, then remove

set -euo pipefail

PKG="${OMW_PKG:-is.xyz.omw_nightly}"
APPDIR="/data/user/0/${PKG}/files/config"
APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

adb_() { MSYS_NO_PATHCONV=1 adb "$@"; }

echo "== device =="
adb_ devices
adb_ root >/dev/null 2>&1 || true
adb_ wait-for-device

if ! adb_ shell "test -f ${APPDIR}/openmw.base.cfg" 2>/dev/null; then
  echo "!! ${APPDIR}/openmw.base.cfg not found -- is the app installed and run once?" >&2
  exit 1
fi

echo
echo "== stale entries in the launcher's template =="
adb_ shell "grep -nE '^(data|content)=' ${APPDIR}/openmw.base.cfg" || true

# Lines naming a plugin the engine cannot load, or a data dir from an old
# experiment. `specify-me!` is the launcher's own placeholder and is harmless.
PATTERN='^(data=".*/omwmod"|content=.*\.omwscripts)$'

if [[ "$APPLY" -eq 0 ]]; then
  echo
  echo "(dry run -- re-run with --apply to remove the lines matching: $PATTERN)"
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
for f in openmw.base.cfg openmw.cfg; do
  adb_ shell "cp ${APPDIR}/${f} ${APPDIR}/${f}.bak-${STAMP} 2>/dev/null || true"
  adb_ shell "sed -i -E '/${PATTERN}/d' ${APPDIR}/${f}"
  echo "cleaned ${f} (backup: ${f}.bak-${STAMP})"
done

echo
echo "== after =="
adb_ shell "grep -nE '^(data|content)=' ${APPDIR}/openmw.base.cfg" || true

echo
echo "Now force-stop and relaunch the app; the generated config is rebuilt clean."
