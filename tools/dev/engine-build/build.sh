#!/usr/bin/env bash
# Build OpenMW from source, for the fork.
#
# WHY THIS EXISTS
# Three of the five causes of a stopped world are invisible to Lua
# (apps/openmw/mwworld/datetimemanager.cpp:259 -- isPostProcessorHudVisible,
# isInteractiveMessageBoxActive, State_NoGame), and chargen cannot be driven from Lua at all
# because the dialogs are native widgets. A build we own is the only place either of those can be
# changed, and it is also the only route to a modern Android engine: the published APK predates
# .omwscripts (docs/android.md).
#
# The recipe is the project's own CI, adapted: .github/workflows/windows.yml downloads a prebuilt
# vcpkg tree from the openmw-deps project and configures with Ninja. We skip the launcher, the
# wizard, OpenCS, the importers and the tests, which means **no Qt download** -- we run
# openmw.exe directly with our own config (tools/dev/desktop/setup-cfg.sh).
#
# Usage:
#   bash tools/dev/engine-build/build.sh --deps        # download + verify + extract only
#   bash tools/dev/engine-build/build.sh --configure   # configure only
#   bash tools/dev/engine-build/build.sh               # configure + build
#   bash tools/dev/engine-build/build.sh --release     # CMAKE_BUILD_TYPE=Release (default RelWithDebInfo)
#   bash tools/dev/engine-build/build.sh --jobs 8
#
# Env overrides: OMW_SRC, OMW_BUILD_DIR, OMW_DEPS_DIR

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC="${OMW_SRC:-$REPO/.research/openmw}"
BUILD_DIR="${OMW_BUILD_DIR:-/f/OpenMW-build}"
DEPS_DIR="${OMW_DEPS_DIR:-$BUILD_DIR/deps}"

# The deps archive is named and hashed by the openmw-deps project. The token is the `msvc` input
# of the CI workflow, whose default is "2022" (NOT "vs2022" -- that 404s).
VCPKG_TAG="2026-09-09"
MSVC_TOKEN="2022"
DEP_NAME="vcpkg-x64-windows-${MSVC_TOKEN}-${VCPKG_TAG}"
DEP_URL="https://github.com/OpenMW/openmw-deps-build/releases/download/${VCPKG_TAG}/${DEP_NAME}.7z"
# SHA512, from CI/deps_versions.msvc.sh's companion manifest (vcpkg-...-manifest.txt)
DEP_SHA512="facc7c219c70b80521aab49c5802da33cc6570ab727cf5778a000b9a4e57d6e23a7f83a23a8504a519e7808a47aa9fae2c4b2332e0a4904f9ba7d4b47fadd850"

CXX_FLAGS_TYPE="RelWithDebInfo"
JOBS=""
DO_DEPS=0
DO_CONFIGURE=0
DO_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deps) DO_DEPS=1; shift ;;
    --configure) DO_CONFIGURE=1; shift ;;
    --release) CXX_FLAGS_TYPE="Release"; shift ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --help|-h) sed -n '3,25p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [[ $DO_DEPS -eq 0 && $DO_CONFIGURE -eq 0 ]]; then DO_CONFIGURE=1; DO_BUILD=1; fi

find_7z() {
  for candidate in "$(command -v 7z 2>/dev/null)" \
                   "/c/Program Files/7-Zip/7z.exe" \
                   "/c/Program Files (x86)/7-Zip/7z.exe"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}

find_vcvars() {
  for edition in Community BuildTools Professional Enterprise; do
    for year in 18 2022 2019; do
      local candidate="/c/Program Files/Microsoft Visual Studio/$year/$edition/VC/Auxiliary/Build/vcvarsall.bat"
      if [[ -f "$candidate" ]]; then echo "$candidate"; return 0; fi
      candidate="/c/Program Files (x86)/Microsoft Visual Studio/$year/$edition/VC/Auxiliary/Build/vcvarsall.bat"
      if [[ -f "$candidate" ]]; then echo "$candidate"; return 0; fi
    done
  done
  return 1
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
CMAKE_DIR="/c/Users/Jaret/.local/share/retcomm/toolchains/cmake-clang-v1/latest/bin"
CMAKEEXE="$(command -v cmake 2>/dev/null || echo "$CMAKE_DIR/cmake.exe")"
NINJA_DIR="$(dirname "$CMAKEEXE")"
SEVENZIP="$(find_7z)" || { echo "no 7z found (install 7-Zip)" >&2; exit 3; }
VCVARS="$(find_vcvars)" || { echo "no MSVC vcvarsall.bat found" >&2; exit 3; }

echo "== source      : $SRC"
echo "== build dir   : $BUILD_DIR"
echo "== deps        : $DEPS_DIR"
echo "== cmake       : $CMAKEEXE"
echo "== 7z          : $SEVENZIP"
echo "== MSVC        : $VCVARS"
echo "== build type  : $CXX_FLAGS_TYPE"

if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
  echo "no CMakeLists.txt at $SRC (set OMW_SRC)" >&2; exit 3
fi
mkdir -p "$DEPS_DIR" "$BUILD_DIR/build"

# ---------------------------------------------------------------------------
# deps
# ---------------------------------------------------------------------------
deps_ok() { [[ -d "$DEPS_DIR/$DEP_NAME/installed/x64-windows" ]]; }

if [[ $DO_DEPS -eq 1 || $DO_CONFIGURE -eq 1 ]]; then
  if deps_ok && [[ $DO_DEPS -eq 0 ]]; then
    echo "== deps already extracted"
  else
    archive="$DEPS_DIR/$DEP_NAME.7z"
    if [[ ! -s "$archive" ]]; then
      echo "== downloading $DEP_NAME.7z (~1 GB)"
      curl --fail --retry 3 -L -o "$archive" "$DEP_URL" || { echo "download failed" >&2; exit 4; }
    fi
    echo "== verifying sha512"
    actual="$(sha512sum "$archive" | awk '{print $1}')"
    if [[ "$actual" != "$DEP_SHA512" ]]; then
      echo "deps hash mismatch: expected $DEP_SHA512, got $actual" >&2
      echo "(delete $archive and re-run; a partial download looks exactly like this)" >&2
      exit 5
    fi
    echo "== extracting"
    "$SEVENZIP" x -y "-o$DEPS_DIR/$DEP_NAME" "$archive" >/dev/null || { echo "extract failed" >&2; exit 6; }
    deps_ok || { echo "extracted, but $DEP_NAME/installed/x64-windows is missing" >&2; exit 7; }
    echo "== deps ready"
  fi
fi

# ---------------------------------------------------------------------------
# fork patches
# ---------------------------------------------------------------------------
# The fork's changes live in the PROJECT as patch files and are applied to the checkout, so the
# engine we build is reproducible from this repo rather than being whatever the working tree
# happens to contain. `patch --forward` is idempotent: an already-applied patch is skipped
# instead of aborting the build.
PATCH_DIR="$REPO/tools/dev/engine-build/patches"
if [[ -d "$PATCH_DIR" ]]; then
  for p in "$PATCH_DIR"/*.patch; do
    [[ -e "$p" ]] || continue
    name="$(basename "$p")"
    if ( cd "$SRC" && patch -p1 --forward --silent --dry-run < "$p" >/dev/null 2>&1 ); then
      ( cd "$SRC" && patch -p1 --forward --silent < "$p" ) && echo "== applied patch $name"
    elif ( cd "$SRC" && patch -p1 --reverse --silent --dry-run < "$p" >/dev/null 2>&1 ); then
      echo "== patch $name already applied"
    else
      echo "!! patch $name does not apply cleanly to $SRC" >&2
      echo "   the checkout has drifted from what the patch expects" >&2
      exit 10
    fi
  done
fi

[[ $DO_CONFIGURE -eq 1 ]] || { echo "== done (deps only)"; exit 0; }

# ---------------------------------------------------------------------------
# configure + build, through a .bat so vcvars and CMake agree on the environment
# ---------------------------------------------------------------------------
BAT="$BUILD_DIR/build-msvc.bat"
VCPKG_TOOLCHAIN="$(cygpath -w "$DEPS_DIR/$DEP_NAME/scripts/buildsystems/vcpkg.cmake" 2>/dev/null || echo "$DEPS_DIR/$DEP_NAME/scripts/buildsystems/vcpkg.cmake")"
VCPKG_INC="$(cygpath -w "$DEPS_DIR/$DEP_NAME/installed/x64-windows/include/luajit" 2>/dev/null)"
VCPKG_LIB="$(cygpath -w "$DEPS_DIR/$DEP_NAME/installed/x64-windows/lib/lua51.lib" 2>/dev/null)"
SRC_W="$(cygpath -w "$SRC" 2>/dev/null || echo "$SRC")"
BUILD_W="$(cygpath -w "$BUILD_DIR/build" 2>/dev/null || echo "$BUILD_DIR/build")"

cat > "$BAT" <<BAT_EOF
@echo off
call "$(cygpath -w "$VCVARS" 2>/dev/null || echo "$VCVARS")" x64 || exit /b 1

REM Ninja goes on the END of PATH, and the compiler is named explicitly. With the Ninja
REM toolchain's own bin in FRONT, CMake found cc.exe/c++.exe (clang) instead of MSVC's cl.exe and
REM cheerfully configured a clang build that would then link against MSVC-built libraries.
set "PATH=%PATH%;$(cygpath -w "$NINJA_DIR" 2>/dev/null || echo "$NINJA_DIR")"

cmake -S "$SRC_W" -B "$BUILD_W" -G Ninja ^
  -D CMAKE_C_COMPILER=cl ^
  -D CMAKE_CXX_COMPILER=cl ^
  -D CMAKE_MAKE_PROGRAM="$(cygpath -w "$NINJA_DIR" 2>/dev/null || echo "$NINJA_DIR")\\ninja.exe" ^
  -D CMAKE_BUILD_TYPE=$CXX_FLAGS_TYPE ^
  -D CMAKE_TOOLCHAIN_FILE="$VCPKG_TOOLCHAIN" ^
  -D LuaJit_INCLUDE_DIR="$VCPKG_INC" ^
  -D LuaJit_LIBRARY="$VCPKG_LIB" ^
  -D OPENMW_USE_SYSTEM_YAML_CPP=OFF ^
  -D OPENMW_USE_SYSTEM_SQLITE3=OFF ^
  -D BUILD_LAUNCHER=OFF ^
  -D BUILD_WIZARD=OFF ^
  -D BUILD_OPENCS=OFF ^
  -D BUILD_ESSIMPORTER=OFF ^
  -D BUILD_MWINIIMPORTER=OFF ^
  -D BUILD_BSATOOL=OFF ^
  -D BUILD_ESMTOOL=OFF ^
  -D BUILD_NIFTEST=OFF ^
  -D BUILD_BENCHMARKS=OFF ^
  -D BUILD_COMPONENTS_TESTS=OFF ^
  -D BUILD_OPENMW_TESTS=OFF ^
  -D BUILD_DOCS=OFF || exit /b 2
BAT_EOF

if [[ $DO_BUILD -eq 1 ]]; then
  echo "cmake --build \"$BUILD_W\" --config $CXX_FLAGS_TYPE" >> "$BAT"
fi
echo "exit /b 0" >> "$BAT"

echo "== running $BAT"
if [[ $DO_BUILD -eq 1 ]]; then
  # a build is long: let the caller see it live
  cmd //c "$(cygpath -w "$BAT" 2>/dev/null || echo "$BAT")" || { echo "build failed" >&2; exit 8; }
else
  cmd //c "$(cygpath -w "$BAT" 2>/dev/null || echo "$BAT")" || { echo "configure failed" >&2; exit 8; }
  echo "== configured (not built). Now: bash tools/dev/engine-build/build.sh"
  exit 0
fi

EXE="$BUILD_DIR/build/openmw.exe"
if [[ -f "$EXE" ]]; then
  echo "== built: $EXE"
  echo "   run it with:  OMW_EXE=$EXE bash tools/dev/desktop/into-world.sh --cell \"Imperial Prison Ship\""
else
  echo "== build finished but no openmw.exe at $EXE" >&2; exit 9
fi
