#!/usr/bin/env bash
# tools/android/tests/ui-loop.sh
#
# The fast loop: boot the emulator, build and install the UI, launch it, screenshot it, and read the
# screenshot back as numbers.
#
# WHY THIS IS THE LOOP
# -------------------
# The APK is arm64-v8a (the published OpenMW dependency archive is) and QEMU2 will not emulate arm64
# on an x86_64 host (docs/android.md), so the engine can never run on this machine. The UI can:
# build-apk.sh --ui-only produces the SAME Java with no native libraries, LauncherActivity routes to
# AppActivity, and the result is the real view tree with either a fixture or a placeholder in the
# viewport. That makes the native UI reviewable from here, which is the whole point of it.
#
# What this CANNOT prove, and does not pretend to: that the engine renders into the top-third
# viewport, that the bridge carries live state, or anything about framerate and heat. Those need the
# arm64 phone. This loop proves layout, insets, tap targets, colour, and that a tap reaches the sink.
#
# USAGE
#   bash tools/android/tests/ui-loop.sh                     # build --ui-only, install, launch, shoot
#   bash tools/android/tests/ui-loop.sh --no-build          # use the APK that is already there
#   bash tools/android/tests/ui-loop.sh --no-boot           # an emulator is already running
#   bash tools/android/tests/ui-loop.sh --apk build/android-out/idle-openmw.apk --activity .MainActivity
#                                                           # the real arm64 APK, on a real device
#
# PATH CONVERSION, and why it is NOT disabled here
#
# tools/android/run-on-emulator.sh exports MSYS_NO_PATHCONV=1 because it pushes device paths
# (`/sdcard/...`) that Git Bash would otherwise rewrite into Windows paths. This script deliberately
# does NOT: it hands nothing but local paths to adb, and it calls build-apk.sh, which passes
# `tools/android/add-to-apk.py` to a WINDOWS python.exe and depends on the usual conversion to turn
# that POSIX path into C:/... With the conversion off, python is handed `/c/Users/...` and reports
# `can't open file 'C:\c\Users\...'` for a file that exists. If a device path is ever needed here,
# set the variable for THAT command rather than for the whole script.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
AVD="${AVD_NAME:-idle_openmw}"
PKG=is.xyz.idle_openmw
ACTIVITY="$PKG/.AppActivity"
APK="$REPO_ROOT/build/android-out/idle-openmw-ui-only-x86_64.apk"
BUILD=1
BOOT=1
OUT_DIR="$REPO_ROOT/build/device"

while [ $# -gt 0 ]; do
  case "$1" in
    --apk) APK="$2"; shift 2 ;;
    --activity) ACTIVITY="$2"; shift 2 ;;
    --avd) AVD="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --no-boot) BOOT=0; shift ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

win() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
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
[ -x "$ADB" ] || ADB="$SDK/platform-tools/adb"

if [ "$BUILD" = "1" ]; then
  say "building the UI-only APK"
  bash "$REPO_ROOT/tools/android/build-apk.sh" --ui-only || exit 1
fi

if [ ! -f "$APK" ]; then
  echo "no APK at $APK -- run without --no-build, or pass --apk" >&2
  exit 2
fi

if [ "$BOOT" = "1" ]; then
  if "$ADB" devices | grep -q "emulator-.*device$"; then
    say "an emulator is already running"
  else
    say "booting AVD '$AVD' (no window: the screenshots are the point)"
    nohup "$SDK/emulator/emulator.exe" -avd "$AVD" -no-window -no-snapshot-save -no-boot-anim \
          -gpu swiftshader_indirect -memory 4096 >/dev/null 2>&1 &
    disown || true
  fi

  "$ADB" wait-for-device
  # `sys.boot_completed` is the only honest readiness signal: the device answers adb long before the
  # framework can install anything.
  for _ in $(seq 1 60); do
    [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
    sleep 5
  done
fi

say "installing $APK"
# -r, not an uninstall first: the debug keystore is stable across builds
# (build/android-keystore/debug.keystore, outside the wiped work directory) so an upgrade works.
"$ADB" install -r "$(win "$APK")" 2>&1 | tail -2

say "launching $ACTIVITY"
"$ADB" logcat -c
"$ADB" shell am start -n "$ACTIVITY" >/dev/null 2>&1
sleep 6

say "which activity is up"
"$ADB" shell dumpsys activity activities 2>/dev/null | grep -E "topResumedActivity" | head -2

mkdir -p "$OUT_DIR"
STAMP="$(date +%H%M%S)"
SHOT="$OUT_DIR/loop-$STAMP.png"
"$ADB" exec-out screencap -p > "$SHOT"
say "screenshot: $SHOT"

say "crashes?"
"$ADB" logcat -d -s AndroidRuntime:E 2>&1 | head -6

say "what the screenshot shows"
python "$REPO_ROOT/tools/android/tests/read_screen.py" "$SHOT"
