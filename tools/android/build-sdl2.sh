#!/usr/bin/env bash
# tools/android/build-sdl2.sh
#
# Build SDL2 for Android, because the published dependency archive is one version short.
#
# WHY THIS EXISTS
# ---------------
# openmw-android-deps-20240812.tar.xz carries SDL2 **2.24.0**, but OpenMW 0.52 asks for
# `find_package(SDL2 2.26 REQUIRED)` (CMakeLists.txt:496), so the configure stops there:
#
#   Could not find a configuration file for package "SDL2" that is compatible with requested
#   version "2.26".  The following configuration files were considered but not accepted:
#     .../lib/cmake/SDL2/SDL2Config.cmake, version: 2.24.0
#
# Everything else in the archive satisfies its requirement -- OSG 3.6.5 for 3.6.5, Boost 1.85 for
# 1.70, and the FFmpeg 6.1 headers comfortably beat the 4.0 floor. SDL2 is the single shortfall,
# and SDL2 is the easiest of them to build: it cross-compiles with nothing but the NDK toolchain
# file.
#
# USAGE
#   bash tools/android/build-sdl2.sh              # arm64-v8a, android-24
#   bash tools/android/build-sdl2.sh --abi x86_64 # emulator ABI
#
# Installs to build/android-sdl2/install, which tools/android/configure-android.sh picks up.
set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ABI="arm64-v8a"
PLATFORM="android-24"
SDL_VERSION="${SDL_VERSION:-2.30.12}"
WORK="$REPO_ROOT/build/android-sdl2"

while [ $# -gt 0 ]; do
  case "$1" in
    --abi) ABI="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --version) SDL_VERSION="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "${NDK:-}" ]; then
  SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$USERPROFILE/AppData/Local/Android/Sdk}}"
  SDK="${SDK//\\//}"
  [ -d "$SDK/ndk" ] && NDK="$SDK/ndk/$(ls "$SDK/ndk" | sort -V | tail -1)"
fi
if [ -z "${NDK:-}" ] || [ ! -f "$NDK/build/cmake/android.toolchain.cmake" ]; then
  echo "No NDK found. Install one: sdkmanager \"ndk;29.0.14206865\"" >&2
  exit 2
fi

mkdir -p "$WORK"
TARBALL="$WORK/SDL2-$SDL_VERSION.tar.gz"
SRC="$WORK/SDL2-$SDL_VERSION"

if [ ! -d "$SRC" ]; then
  if [ ! -f "$TARBALL" ]; then
    echo "== downloading SDL2 $SDL_VERSION =="
    curl -fSL --retry 3 -o "$TARBALL" \
      "https://github.com/libsdl-org/SDL/releases/download/release-$SDL_VERSION/SDL2-$SDL_VERSION.tar.gz"
  fi
  echo "== extracting =="
  tar -xzf "$TARBALL" -C "$WORK"
fi

INSTALL="$WORK/install"
echo "NDK      : $NDK"
echo "ABI      : $ABI  (platform $PLATFORM)"
echo "SDL2     : $SDL_VERSION"
echo "install  : $INSTALL"
echo

# STATIC: the Android app links one .so of its own; a vendored shared libSDL2 would then need
# shipping and loading alongside it. OpenMW's own Android build links SDL2 statically too.
cmake -S "$SRC" -B "$WORK/build-$ABI" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM="$PLATFORM" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL" \
  -DSDL_SHARED=OFF \
  -DSDL_STATIC=ON \
  -DSDL_TEST=OFF \
  -DSDL_TESTS=OFF \
  > "$WORK/sdl2-configure.log" 2>&1 || {
    echo "SDL2 configure FAILED:"; tail -20 "$WORK/sdl2-configure.log"; exit 1; }

cmake --build "$WORK/build-$ABI" --target install -j "$(nproc 2>/dev/null || echo 4)" \
  > "$WORK/sdl2-build.log" 2>&1 || {
    echo "SDL2 build FAILED:"; tail -20 "$WORK/sdl2-build.log"; exit 1; }

echo "SDL2 installed. The config CMake will find:"
find "$INSTALL" -name "SDL2Config.cmake" -o -name "sdl2-config.cmake" 2>/dev/null | head -3
grep -m1 -rE "set\(SDL2_VERSION|SDL_VERSION_STRING" "$INSTALL/lib/cmake/SDL2/SDL2Config.cmake" 2>/dev/null \
  || grep -m1 "SDL_MAJOR_VERSION\|SDL_MINOR_VERSION\|SDL_PATCHLEVEL" "$INSTALL/include/SDL2/SDL_version.h" 2>/dev/null
