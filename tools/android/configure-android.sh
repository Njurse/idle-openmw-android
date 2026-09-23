#!/usr/bin/env bash
# tools/android/configure-android.sh
#
# Configure OUR OpenMW source for Android, with openmw-android's Linux-only superbuild BYPASSED.
#
# WHY THIS EXISTS
# ---------------
# The upstream port is a superbuild that downloads the LINUX NDK zip and builds its whole
# dependency set itself, pinned to NDK r21e and 2019-2021 releases, from
# `toolchains/llvm/prebuilt/linux-x86_64/bin`. None of that runs on Windows -- but the NDK's
# Windows toolchain does, and this script uses it directly to answer the only question that
# matters first: how far does our OWN source get with a modern NDK?
#
# It gets to the dependency list. That is the finding (docs/android.md):
#
#   * the compiler phase SUCCEEDS (Clang is identified as the Android cross-compiler);
#   * `find_package(OpenGL REQUIRED)` at CMakeLists.txt:278 wants desktop GL, which Android does
#     not have -- satisfied here with the NDK's own GLES, so it is a configure-time obstacle
#     rather than a porting job;
#   * the next REQUIRED dependency stops it: `Could NOT find LZ4` at CMakeLists.txt:281, the first
#     of OSG, Boost, SDL2, MyGUI, Bullet, ffmpeg, OpenAL and the rest.
#
# So the one thing still blocking this is an Android dependency tree for a modern NDK:
#
#     cmake ... -DOPENMW_DEPENDENCIES_DIR=<tree>
#
# CMakeLists.txt:73 adds that path to CMAKE_FIND_ROOT_PATH. Produce it and this script carries on
# to the next failure; do not expect it to configure today.
#
# USAGE
#   bash tools/android/configure-android.sh                 # newest installed NDK
#   NDK=/path/to/ndk bash tools/android/configure-android.sh
#   bash tools/android/configure-android.sh --abi x86_64    # emulator ABI
#
# EXIT: nonzero when the configure fails, with the first error printed. That is the expected
# outcome until the dependency tree exists, so a failing run is informative rather than broken.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO_ROOT/.research/openmw"
BUILD_DIR="$REPO_ROOT/build/android-configure"

ABI="arm64-v8a"
PLATFORM="android-24"
while [ $# -gt 0 ]; do
  case "$1" in
    --abi) ABI="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --build-dir) BUILD_DIR="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# Locate the NDK: an explicit one wins, then the newest side-by-side install.
if [ -z "${NDK:-}" ]; then
  SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$USERPROFILE/AppData/Local/Android/Sdk}}"
  SDK="${SDK//\\//}"
  if [ -d "$SDK/ndk" ]; then
    NDK="$SDK/ndk/$(ls "$SDK/ndk" | sort -V | tail -1)"
  fi
fi
if [ -z "${NDK:-}" ] || [ ! -f "$NDK/build/cmake/android.toolchain.cmake" ]; then
  echo "No NDK found. Install one: sdkmanager \"ndk;29.0.14206865\"" >&2
  echo "Or pass NDK=/path/to/ndk." >&2
  exit 2
fi

SYSROOT="$NDK/toolchains/llvm/prebuilt/windows-x86_64/sysroot"

# The sysroot is laid out by ABI TRIPLE ("aarch64-linux-android"), not by the ABI name CMake uses
# ("arm64-v8a"). Getting this wrong is silent: the -D paths below simply point at nothing.
case "$ABI" in
  arm64-v8a)   TRIPLE="aarch64-linux-android" ;;
  armeabi-v7a) TRIPLE="arm-linux-androideabi" ;;
  x86_64)      TRIPLE="x86_64-linux-android" ;;
  x86)         TRIPLE="i686-linux-android" ;;
  *)           TRIPLE="$ABI" ;;
esac
# CMake takes the platform as "android-24"; the sysroot directory is just "24".
API="${PLATFORM#android-}"
LIBS="$SYSROOT/usr/lib/$TRIPLE/$API"
if [ ! -d "$LIBS" ]; then
  # the API level directory may be a sibling; take the highest present
  LIBS="$(ls -d "$SYSROOT"/usr/lib/"$TRIPLE"/*/ 2>/dev/null | sort -V | tail -1)"
  LIBS="${LIBS%/}"
fi
if [ ! -f "$LIBS/libGLESv2.so" ]; then
  echo "warning: no libGLESv2.so under $LIBS -- CMake >= 3.27 finds GLES for Android itself," >&2
  echo "         so the overrides below are a fallback rather than a requirement." >&2
fi

echo "NDK      : $NDK"
echo "ABI      : $ABI  (platform $PLATFORM)"
echo "GLES dir : $LIBS"
echo "build dir: $BUILD_DIR"
echo

LOG="$REPO_ROOT/build/android-configure.log"
cmake -S "$SRC" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM="$PLATFORM" \
  -DCMAKE_BUILD_TYPE=Release \
  -DOPENGL_opengl_LIBRARY="$LIBS/libGLESv2.so" \
  -DOPENGL_gl_LIBRARY="$LIBS/libGLESv2.so" \
  -DOPENGL_glx_LIBRARY="$LIBS/libEGL.so" \
  -DOPENGL_INCLUDE_DIR="$SYSROOT/usr/include" \
  ${OPENMW_DEPENDENCIES_DIR:+-DOPENMW_DEPENDENCIES_DIR="$OPENMW_DEPENDENCIES_DIR"} \
  > "$LOG" 2>&1
STATUS=$?

if [ $STATUS -eq 0 ]; then
  echo "CONFIGURED. Next: cmake --build $BUILD_DIR"
else
  echo "Configure stopped (expected until the dependency tree exists). First error:"
  echo
  grep -m1 -A6 "CMake Error" "$LOG" || tail -8 "$LOG"
  echo
  echo "Full log: $LOG"
fi
exit $STATUS
