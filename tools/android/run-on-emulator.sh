#!/usr/bin/env bash
# tools/android/run-on-emulator.sh
#
# Boot the virtual device, install OpenMW, push the game data and this mod, and
# launch. Mirrors the on-device layout documented in docs/deployment.md so the
# emulator and a real S23+ behave identically:
#
#   /storage/emulated/0/Morrowind/Data Files   <- Morrowind GOTY (yours, never committed)
#   /storage/emulated/0/Morrowind/Mods/idle_openmw
#
# The one thing that cannot be automated: OpenMW for Android asks *you* to pick
# the data folder the first time it starts (it uses the system file picker). Point
# it at /storage/emulated/0/Morrowind and it will remember.

set -euo pipefail

# MSYS (Git Bash) rewrites arguments that look like Unix paths into Windows ones,
# so `adb shell mkdir -p /storage/emulated/0/Morrowind` becomes
# `mkdir -p C:/Program Files/...` and fails with "Read-only file system".
#
# The fix has to be one-sided: device paths must reach adb untouched, but local
# paths passed to adb.exe (a Windows binary) must be Windows paths. So we disable
# conversion globally and convert the LOCAL paths ourselves with winpath().
export MSYS_NO_PATHCONV=1

# A Windows path for a local file, as adb.exe requires. Falls back to the input
# when cygpath is unavailable (e.g. running under WSL).
winpath() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }

AVD_NAME="${AVD_NAME:-idle_openmw}"
PKG="${PKG:-is.xyz.omw_nightly}"
DEVICE_ROOT="${DEVICE_ROOT:-/storage/emulated/0/Morrowind}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

find_sdk() {
  for candidate in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" \
                   "${LOCALAPPDATA:-}/Android/Sdk" "$HOME/AppData/Local/Android/Sdk"; do
    [ -n "$candidate" ] && [ -d "$candidate" ] && { echo "$candidate"; return 0; }
  done
  return 1
}
SDK="$(find_sdk)" || { echo "No Android SDK found." >&2; exit 1; }
ADB="$SDK/platform-tools/adb.exe"
EMULATOR="$SDK/emulator/emulator.exe"

# ---------------------------------------------------------------------------
# 1. the emulator
# ---------------------------------------------------------------------------
if "$ADB" devices | grep -q "emulator-.*device$"; then
  say "an emulator is already running"
else
  say "booting AVD '$AVD_NAME'"
  # -gpu swiftshader_indirect is the fallback if the host GPU path misbehaves;
  # OpenMW needs GLES 3.0 and the emulator must be able to provide it.
  nohup "$EMULATOR" -avd "$AVD_NAME" -no-snapshot-save -no-boot-anim \
        -gpu auto -memory 4096 >/tmp/emulator.log 2>&1 &
  disown || true
  "$ADB" wait-for-device
  say "waiting for boot (up to ${BOOT_TIMEOUT}s)"
  deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
      break
    fi
    sleep 5
  done
fi

"$ADB" shell getprop sys.boot_completed | tr -d '\r' | grep -q 1 \
  || { echo "emulator did not finish booting; see /tmp/emulator.log" >&2; exit 1; }
say "device ready: $("$ADB" shell getprop ro.build.version.release | tr -d '\r') (API $("$ADB" shell getprop ro.build.version.sdk | tr -d '\r'))"

# ---------------------------------------------------------------------------
# 2. the APK
# ---------------------------------------------------------------------------
APK="${APK:-$(ls -1t "$REPO"/build/android/*.apk 2>/dev/null | head -1 || true)}"
if [ -z "${APK:-}" ] || [ ! -f "$APK" ]; then
  cat >&2 <<'MSG'
No APK found.

Either download a released build:
  curl -L -o build/android/omw.apk \
    https://github.com/xyzz/openmw-android/releases/download/0.48.0-46-nightly/omw_release_0.48.0-46.apk

...or build one (needs the NDK + a Unix toolchain; see docs/android.md).
MSG
  exit 1
fi
say "installing $(basename "$APK")"
"$ADB" install -r -g "$(winpath "$APK")"

# ---------------------------------------------------------------------------
# 3. the game data
# ---------------------------------------------------------------------------
DATA_DIR="$REPO/gamedata"
if [ ! -f "$DATA_DIR/Data Files/Morrowind.esm" ] || [ ! -f "$DATA_DIR/Morrowind.ini" ]; then
  echo "Staged game data is incomplete or missing." >&2
  echo "Run: python tools/android/gamedata.py --import" >&2
  exit 1
fi

# The port's launcher requires a folder holding BOTH Morrowind.ini AND "Data
# Files" (GameInstaller.check()), and it parses that ini to generate openmw.cfg.
# So we push the staged tree as-is, root included.
say "pushing the game tree to '$DEVICE_ROOT' (this takes a minute)"
"$ADB" shell mkdir -p "'$DEVICE_ROOT'"
"$ADB" push "$(winpath "$DATA_DIR/Data Files")" "$DEVICE_ROOT/" >/dev/null
echo "  Data Files/ (6 files)"
"$ADB" push "$(winpath "$DATA_DIR/Morrowind.ini")" "$DEVICE_ROOT/" >/dev/null
echo "  Morrowind.ini"

# ---------------------------------------------------------------------------
# 4. the mod
# ---------------------------------------------------------------------------
# The launcher scans mods from the **Data Files** directory and only recognises
# plugins with the extensions esm/esp/omwaddon/omwgame (mods/ModsCollection.kt).
# `.omwscripts` is NOT among them, so the mod cannot be registered through the
# Mods UI on this 2021 build. Two consequences:
#
#   * the manifest and its scripts/ tree must live INSIDE Data Files, so the
#     data directory already covers them; and
#   * the `content=` line has to be injected into openmw.base.cfg, which the
#     launcher reads verbatim and re-concatenates into openmw.cfg on every
#     launch. Editing openmw.cfg directly does not survive a launch.
#
# This needs root (the config lives in app-private storage); `adb root` works on
# a google_apis image but not on a playstore one. See docs/android.md.
say "installing the mod into '$DEVICE_ROOT/Data Files'"
"$ADB" push "$(winpath "$REPO/mods/idle_openmw/idle_openmw.omwscripts")" \
       "$DEVICE_ROOT/Data Files/" >/dev/null
"$ADB" push "$(winpath "$REPO/mods/idle_openmw/scripts")" \
       "$DEVICE_ROOT/Data Files/" >/dev/null
echo "  idle_openmw.omwscripts + scripts/"

say "injecting the content line into openmw.base.cfg"
APP_DIR="/data/data/${PKG}/files/config"
BASE_CFG="$APP_DIR/openmw.base.cfg"
# OPT-IN, because on this OpenMW 0.48 build the engine then dies at startup with
# "Cannot load file: .../idle_openmw.omwscripts" -- .omwscripts content is not
# loadable by the 2021 APK (see docs/android.md, Finding C). Injecting it is
# correct for a newer engine; on 0.48 it breaks the launch. So: off by default.
if [ "${INJECT_CONTENT:-0}" != "1" ]; then
  echo "  SKIPPED (set INJECT_CONTENT=1 to enable)."
  echo "  The 2021 APK cannot load .omwscripts; see docs/android.md Finding C."
  echo "  The mod's files are installed, so a newer engine will pick them up."
elif "$ADB" shell "[ -f $BASE_CFG ]" 2>/dev/null; then
  if "$ADB" shell "grep -q idle_openmw.omwscripts $BASE_CFG" 2>/dev/null; then
    echo "  already present"
  else
    "$ADB" shell "printf 'data=\"$DEVICE_ROOT/Data Files\"\ncontent=idle_openmw.omwscripts\n' >> $BASE_CFG"
    echo "  appended"
  fi
else
  echo "  SKIPPED: $BASE_CFG not found."
  echo "  Launch the game once with the data folder configured, then re-run this"
  echo "  script, or add these lines to the user openmw.cfg by hand:"
  echo "      data=\"$DEVICE_ROOT/Data Files\""
  echo "      content=idle_openmw.omwscripts"
fi

# the exact cfg lines the device needs, written next to the data for reference
cat > "$DATA_DIR/openmw.cfg.android" <<EOF
# Generated by tools/android/run-on-emulator.sh
# Paste into openmw.cfg on the DEVICE (or select the folders in the launcher once).
data="$DEVICE_ROOT/Data Files"
data="$DEVICE_ROOT/Mods/idle_openmw"
content=Morrowind.esm
content=Tribunal.esm
content=Bloodmoon.esm
content=idle_openmw.omwscripts
EOF
"$ADB" push "$(winpath "$DATA_DIR/openmw.cfg.android")" "$DEVICE_ROOT/" >/dev/null
say "wrote $DEVICE_ROOT/openmw.cfg.android"

# ---------------------------------------------------------------------------
# 5. launch
# ---------------------------------------------------------------------------
say "launching $PKG"
"$ADB" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true

cat <<MSG

---------------------------------------------------------------
  On screen now: OpenMW's launcher.

  One-time manual step: tell it where the data is.
    Data files : $DEVICE_ROOT
    (it will pick up "Data Files" and "Mods/idle_openmw")

  Then enable content 'idle_openmw.omwscripts' and start the game.

  Watch the log:
    $ADB logcat | grep -iE "idle|lua|omw"

  Re-push after editing the mod (no reinstall needed):
    tools/android/run-on-emulator.sh
---------------------------------------------------------------
MSG
