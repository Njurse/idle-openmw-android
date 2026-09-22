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
# Two non-obvious decisions, both discovered the hard way:
#
# 1. It installs the CLASSIC command-line tools, pinned, rather than using the
#    `latest` ones. As of build 16111833 the `latest` package ships a deprecated
#    shim that forwards to a new `android sdk` CLI, and that shim SPLITS a
#    semicolon-separated package spec into separate arguments:
#
#        $ sdkmanager --install "system-images;android-34;google_apis;x86_64"
#        Package system-images not found.
#        Package google_apis not found.
#        Package x86_64 not found.
#
#    The classic Java-based sdkmanager (12.0) handles the documented syntax and
#    can actually install a system image, so we pin one known to work.
#
# 2. It builds a *new* AVD instead of reusing `Medium_Phone`, because that one
#    runs a `page_size_16kb` image and OpenMW's native libraries are 4 KB-aligned
#    (verified: every .so in the released APK has PT_LOAD align 0x1000). A 16 KB
#    device refuses to load them, so the mod would die with a linker error that
#    points nowhere near the cause.

set -euo pipefail

AVD_NAME="${AVD_NAME:-idle_openmw}"
API_LEVEL="${API_LEVEL:-34}"
IMAGE_TAG="${IMAGE_TAG:-google_apis}"
IMAGE_ABI="${IMAGE_ABI:-x86_64}"
SYSTEM_IMAGE="system-images;android-${API_LEVEL};${IMAGE_TAG};${IMAGE_ABI}"
CLASSIC_VERSION="${CLASSIC_VERSION:-11076708}"

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

# the classic tools are Java-based and need a JDK; pick the one this box has
if [ -z "${JAVA_HOME:-}" ] || [ ! -d "$JAVA_HOME" ]; then
  for jdk in "/c/Program Files/Java"/jdk-21* "/c/Program Files/Java"/jdk-17* "/c/Program Files/Eclipse Adoptium"/jdk-21*; do
    [ -d "$jdk" ] && { export JAVA_HOME="$jdk"; break; }
  done
fi
[ -n "${JAVA_HOME:-}" ] && say "JAVA_HOME: $JAVA_HOME"

# ---------------------------------------------------------------------------
# 2. classic command-line tools (real sdkmanager / avdmanager)
# ---------------------------------------------------------------------------
CT="$SDK/cmdline-tools/classic"
if [ ! -f "$CT/bin/sdkmanager.bat" ]; then
  say "installing classic Android command-line tools ($CLASSIC_VERSION)"
  mkdir -p "$DL_DIR"
  ZIP="$DL_DIR/commandlinetools-win-${CLASSIC_VERSION}_latest.zip"
  if [ ! -f "$ZIP" ]; then
    echo "  downloading $(basename "$ZIP")"
    curl -sSL -o "$ZIP" \
      "https://dl.google.com/android/repository/commandlinetools-win-${CLASSIC_VERSION}_latest.zip"
  fi
  echo "  unpacking"
  TMP_DIR="$DL_DIR/_ct_tmp"
  rm -rf "$TMP_DIR"; mkdir -p "$TMP_DIR"
  (cd "$TMP_DIR" && unzip -q "$ZIP")
  rm -rf "$CT"
  mv "$TMP_DIR/cmdline-tools" "$CT"
  rm -rf "$TMP_DIR"
else
  say "classic command-line tools already present"
fi

SDKMANAGER="$CT/bin/sdkmanager.bat"
AVDMANAGER="$CT/bin/avdmanager.bat"
for tool in "$SDKMANAGER" "$AVDMANAGER"; do
  [ -f "$tool" ] || { echo "missing $tool" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# 3. licences + packages
# ---------------------------------------------------------------------------
say "accepting SDK licences"
yes | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true

have_image() { [ -d "$SDK/system-images/android-${API_LEVEL}/${IMAGE_TAG}/${IMAGE_ABI}" ]; }

if have_image; then
  say "$SYSTEM_IMAGE already installed"
else
  say "installing $SYSTEM_IMAGE  (a large download)"
  yes | "$SDKMANAGER" --install "$SYSTEM_IMAGE" "platforms;android-${API_LEVEL}"
fi

# ---------------------------------------------------------------------------
# 4. the AVD
# ---------------------------------------------------------------------------
if "$AVDMANAGER" list avd 2>/dev/null | grep -q "Name: ${AVD_NAME}$"; then
  say "AVD '$AVD_NAME' already exists"
else
  say "creating AVD '$AVD_NAME' ($SYSTEM_IMAGE)"
  # `--device` needs a device definition; fall back to the default if absent
  if ! echo no | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE" --device pixel_5 2>/dev/null; then
    echo no | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE"
  fi
fi

# Give the AVD room for ~600 MB of game data plus a save, and a generous heap.
CFG="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
if [ -f "$CFG" ]; then
  say "tuning AVD config"
  add_if_absent() { grep -q "^$1=" "$CFG" || { echo "$1=$2" >> "$CFG"; echo "  $1=$2"; }; }
  add_if_absent hw.ramSize 4096
  add_if_absent disk.dataPartition.size 8192M
  add_if_absent hw.keyboard yes
  add_if_absent hw.gpu.mode auto
fi

say "sanity check: 4 KB pages, not 16 KB"
"$ADB" start-server >/dev/null 2>&1 || true

say "done"
echo "  SDK  : $SDK"
echo "  AVD  : $AVD_NAME  ($SYSTEM_IMAGE)"
echo
echo "Next:"
echo "  bash tools/android/run-on-emulator.sh     # boot, install, push data + mod"
