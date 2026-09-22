#!/usr/bin/env bash
# tools/android/provision-emulator.sh
#
# Make this machine able to run OpenMW on a virtual device, using the Android SDK
# that is already installed. Idempotent: safe to re-run, and it skips anything
# already present.
#
# Two things this deliberately does NOT do:
#   * it never installs Morrowind (that is yours to own) -- run
#     `python tools/android/gamedata.py --import` for the data step;
#   * it does not build OpenMW. See docs/android.md: the engine binary is a
#     separate, much larger job.
#
# Why a *new* AVD rather than the existing Medium_Phone: that one uses a
# `page_size_16kb` system image, and OpenMW's native libraries are 4 KB-aligned
# (verified: every .so in the released APK has PT_LOAD align 0x1000). A 16 KB
# device refuses to load them, so the mod would fail with a link error rather
# than anything diagnosable. A 4 KB-page image is required.

set -euo pipefail

AVD_NAME="${AVD_NAME:-idle_openmw}"
API_LEVEL="${API_LEVEL:-34}"
IMAGE_TAG="${IMAGE_TAG:-google_apis}"
IMAGE_ABI="${IMAGE_ABI:-x86_64}"
SYSTEM_IMAGE="system-images;android-${API_LEVEL};${IMAGE_TAG};${IMAGE_ABI}"

# absolute, because some steps below cd elsewhere
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DL_DIR="$REPO/build/dl"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. find the SDK
# ---------------------------------------------------------------------------
find_sdk() {
  for candidate in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" \
                   "${LOCALAPPDATA:-}/Android/Sdk" "$HOME/AppData/Local/Android/Sdk" \
                   "/c/Android/Sdk"; do
    [ -n "$candidate" ] && [ -d "$candidate" ] && { echo "$candidate"; return 0; }
  done
  return 1
}

SDK="$(find_sdk)" || { echo "No Android SDK found. Set ANDROID_SDK_ROOT." >&2; exit 1; }
say "SDK: $SDK"
export ANDROID_SDK_ROOT="$SDK" ANDROID_HOME="$SDK"

ADB="$SDK/platform-tools/adb.exe"
EMULATOR="$SDK/emulator/emulator.exe"

# ---------------------------------------------------------------------------
# 2. cmdline-tools (provides sdkmanager / avdmanager)
# ---------------------------------------------------------------------------
if [ ! -f "$SDK/cmdline-tools/latest/bin/sdkmanager.bat" ]; then
  say "installing Android command-line tools"
  mkdir -p "$DL_DIR"
  ZIP="$(ls -1 "$DL_DIR"/commandlinetools-win-*_latest.zip 2>/dev/null | head -1 || true)"
  if [ -z "$ZIP" ]; then
    URL=$(curl -s https://dl.google.com/android/repository/repository2-3.xml \
          | grep -o 'commandlinetools-win-[0-9]*_latest.zip' | head -1)
    ZIP="$DL_DIR/$URL"
    echo "  downloading $URL"
    curl -sSL -o "$ZIP" "https://dl.google.com/android/repository/$URL"
  fi
  echo "  unpacking $(basename "$ZIP")"
  rm -rf "$SDK/cmdline-tools/_tmp"
  mkdir -p "$SDK/cmdline-tools/_tmp"
  (cd "$SDK/cmdline-tools/_tmp" && unzip -q "$ZIP")
  rm -rf "$SDK/cmdline-tools/latest"
  mv "$SDK/cmdline-tools/_tmp/cmdline-tools" "$SDK/cmdline-tools/latest"
  rm -rf "$SDK/cmdline-tools/_tmp"
else
  say "command-line tools already present"
fi

SDKMANAGER="$SDK/cmdline-tools/latest/bin/sdkmanager.bat"
AVDMANAGER="$SDK/cmdline-tools/latest/bin/avdmanager.bat"
[ -f "$SDKMANAGER" ] || { echo "sdkmanager missing at $SDKMANAGER" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 3. licences + packages
# ---------------------------------------------------------------------------
say "accepting SDK licences"
yes | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true

say "installing $SYSTEM_IMAGE (+ platform 34)"
# shellcheck disable=SC2086
"$SDKMANAGER" --install "platform-tools" "platforms;android-${API_LEVEL}" "$SYSTEM_IMAGE"

# ---------------------------------------------------------------------------
# 4. the AVD
# ---------------------------------------------------------------------------
if "$AVDMANAGER" list avd 2>/dev/null | grep -q "Name: ${AVD_NAME}$"; then
  say "AVD '$AVD_NAME' already exists"
else
  say "creating AVD '$AVD_NAME' ($SYSTEM_IMAGE)"
  echo no | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE" --device pixel_5
fi

# Give the AVD enough room to hold the game data (~600 MB) and a save.
CFG="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
if [ -f "$CFG" ]; then
  say "tuning AVD config (RAM, data partition, 4 KB pages)"
  grep -q '^hw.ramSize'        "$CFG" || echo 'hw.ramSize=4096'    >> "$CFG"
  grep -q '^disk.dataPartition.size' "$CFG" || echo 'disk.dataPartition.size=8192M' >> "$CFG"
  grep -q '^hw.keyboard'       "$CFG" || echo 'hw.keyboard=yes'    >> "$CFG"
fi

say "done"
echo "  SDK    : $SDK"
echo "  AVD    : $AVD_NAME"
echo
echo "Next:"
echo "  tools/android/run-on-emulator.sh          # boot, install, push data + mod"
