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
# THE DEPENDENCY TREE IS A PREBUILT ARCHIVE, and that is the recipe (CI/before_install.android.sh):
#
#     curl .../openmw-deps/-/raw/main/android/openmw-android-deps-20240812.tar.xz
#     tar -xJf it into the NDK sysroot's usr/
#
# Upstream extracts it INTO the sysroot. We instead keep it beside the build and pass the path,
# because CMakeLists.txt:73 adds OPENMW_DEPENDENCIES_DIR to CMAKE_FIND_ROOT_PATH and that is
# non-destructive -- it can be re-extracted or removed without touching the NDK.
#
# The archive is aarch64 / API 24, built by NDK r26b, and carries Boost 1.85 with full CMake
# config packages, SDL2, MyGUI, Bullet, ffmpeg, OpenAL, freetype, libpng16, libjpeg, gl4es, ICU,
# collada-dom and liblz4.a. LZ4 has NO CMake config, which is why openmw's own
# cmake/FindLZ4.cmake is what has to find it.
#
# NOTE the tree is extracted on Windows, where tar cannot create symlinks without privilege, so
# the archive's libpng.a -> libpng16.a style links come out MISSING and must be recreated as
# copies. tools/android/fix-deps-symlinks.sh does that.
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
DEPS="${OPENMW_DEPENDENCIES_DIR:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --abi) ABI="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --build-dir) BUILD_DIR="$2"; shift 2 ;;
    --deps) DEPS="$2"; shift 2 ;;
    --sdl2) SDL2_ROOT="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# SDL2 must come from OUR build, not the archive: the archive carries 2.24.0 and this source
# requires 2.26 (CMakeLists.txt:496). tools/android/build-sdl2.sh produces it.
if [ -z "${SDL2_ROOT:-}" ]; then
  SDL2_ROOT="$REPO_ROOT/build/android-sdl2/install"
  [ -d "$SDL2_ROOT" ] || SDL2_ROOT=""
fi
# SDL2 first, then the archive: CMAKE_PREFIX_PATH is searched in order, and the archive's older
# SDL2Config.cmake would otherwise win and be rejected by the version check.
PREFIX=""
[ -n "${SDL2_ROOT:-}" ] && PREFIX="$SDL2_ROOT"
[ -n "$DEPS" ] && PREFIX="${PREFIX:+$PREFIX;}$DEPS"

# clang is a Windows binary, so any path that ends up on a COMMAND LINE (not a CMake -D that CMake
# itself resolves) has to be in C:/... form. Used for -include and -L below.
DEPS_WIN="$DEPS"
if [ -n "$DEPS" ] && command -v cygpath >/dev/null 2>&1; then
  DEPS_WIN="$(cygpath -m "$DEPS")"
fi

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

# ---------------------------------------------------------------------------------------------
# FFmpeg versions, read from the dependency tree's OWN headers.
#
# openmw's cmake/FindFFmpeg.cmake never populates FFmpeg_<LIB>_VERSION, so the guard at
# CMakeLists.txt:345-367 ("FFmpeg version is too old, 4.0 is required") compares against EMPTY
# strings and can never pass. That is not hypothetical: upstream's own CI works around it by
# sed-patching the check out of CMakeLists (CI/before_script.android.sh, NOT FFVER_OK -> FALSE).
#
# Rather than patch the source, measure it. The versions are facts sitting in the archive, so read
# them and pass them, and the guard runs on the real numbers instead of being skipped.
# (ffmpeg >= 5 moved MAJOR into its own version_major.h.)
ffver() { # ffver <avlib> -> MAJOR.MINOR.MICRO, or nothing when the headers are absent
  local lib="$1" upper dir major minor micro
  # the tree's include directories keep the lib prefix: libavutil, libavformat, ...
  dir="$DEPS/include/lib$lib"
  [ -n "$DEPS" ] && [ -d "$dir" ] || return 1
  upper=$(echo "lib$lib" | tr 'a-z' 'A-Z')
  major=$(sed -n "s/^#define ${upper}_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$dir/version_major.h" 2>/dev/null | head -1)
  [ -n "$major" ] || major=$(sed -n "s/^#define ${upper}_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$dir/version.h" 2>/dev/null | head -1)
  minor=$(sed -n "s/^#define ${upper}_VERSION_MINOR[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$dir/version.h" 2>/dev/null | head -1)
  micro=$(sed -n "s/^#define ${upper}_VERSION_MICRO[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$dir/version.h" 2>/dev/null | head -1)
  [ -n "$major" ] && [ -n "$minor" ] && echo "$major.$minor.${micro:-100}"
}
FFMPEG_VERSION_FLAGS=()
for avlib in avutil avformat avcodec swscale swresample; do
  avver=$(ffver "$avlib" || true)
  if [ -n "$avver" ]; then
    FFMPEG_VERSION_FLAGS+=("-DFFmpeg_$(echo "$avlib" | tr 'a-z' 'A-Z')_VERSION=$avver")
    echo "ffmpeg   : lib$avlib $avver (from the dependency tree's headers)"
  fi
done

# WHICH OpenGL. Android has no desktop GL, and OpenMW's renderer needs it: 21 symbols such as
# glTexImage1D, glLoadMatrixd and glPolygonStipple are simply absent from GLES, so linking against
# libGLESv2 fails with "undefined symbol: glTexImage1D" (and 20 friends). The answer is gl4es, and
# the dependency archive already carries it: its lib/libGL.so IS gl4es (gl4es_GetProcAddress,
# gl4es_pre_swap), translating desktop GL onto GLES. Prefer it whenever the tree is present.
GL_LIBRARY="$LIBS/libGLESv2.so"
GL_INCLUDE="$SYSROOT/usr/include"
if [ -n "$DEPS" ] && [ -f "$DEPS/lib/libGL.so" ]; then
  GL_LIBRARY="$DEPS/lib/libGL.so"
  GL_INCLUDE="$DEPS/include"
  echo "OpenGL   : $DEPS/lib/libGL.so (gl4es -- desktop GL over GLES)"
fi

echo "NDK      : $NDK"
echo "ABI      : $ABI  (platform $PLATFORM)"
echo "GLES dir : $LIBS"
echo "deps     : ${DEPS:-(none -- expect the dependency list to stop it)}"
echo "build dir: $BUILD_DIR"
echo

# The fork's patches, applied here as well as in the desktop build. This used to be the desktop
# build's job alone, which meant the ANDROID engine silently lacked every fork change -- a missing
# binding is not a compile error, so nothing would have said so until a phone. See
# tools/dev/engine-build/apply-patches.sh.
bash "$REPO_ROOT/tools/dev/engine-build/apply-patches.sh" "$SRC" || exit 10
echo

LOG="$REPO_ROOT/build/android-configure.log"
# FindMyGUI has no CMake package to find, so it probes with HINTS on $ENV{MYGUI_HOME}. Point it at
# the dependency tree: the archive carries a PREBUILT libMyGUIEngineStatic.a, and that matters --
# MyGUI 3.4.3 does NOT compile against a modern NDK's libc++ ("implicit instantiation of undefined
# template 'std::char_traits<unsigned int>'" in MyGUI_UString.h, since the char_traits
# specialisations it relies on were removed). Using the prebuilt library avoids that entirely.
if [ -n "$DEPS" ]; then export MYGUI_HOME="$DEPS"; fi

# MyGUI 3.4.3's headers do not compile against a modern libc++: they build on
# std::basic_string<unsigned int>, whose char_traits specialisation libc++ removed. Force-include
# the shim that restores it (see the header for the full story).
COMPAT_HEADER="$REPO_ROOT/tools/android/compat/glibcxx_char_traits_unicode.h"
COMPAT_CXX_FLAGS=""
if [ -f "$COMPAT_HEADER" ]; then
  # clang is a WINDOWS binary: it cannot open a /c/... path, so hand it the C:/... form. (CMake
  # itself copes with POSIX paths elsewhere, which is why only this flag needs converting.)
  COMPAT_HEADER_WIN="$COMPAT_HEADER"
  if command -v cygpath >/dev/null 2>&1; then
    COMPAT_HEADER_WIN="$(cygpath -m "$COMPAT_HEADER")"
  fi
  COMPAT_CXX_FLAGS="-include $COMPAT_HEADER_WIN"
  echo "compat   : force-including $(basename "$COMPAT_HEADER") for the removed char_traits"
fi
# OSG's own extension lookup dlopen()s the system libGLESv2.so, bypassing gl4es and mixing two GL
# implementations (SIGSEGV in isGLExtensionOrVersionSupported). Wrap dlopen inside libopenmw.so so
# those probes land on gl4es. See tools/android/compat/gl_dlopen_wrap.c and docs/android.md.
GLWRAP_SRC="$REPO_ROOT/tools/android/compat/gl_dlopen_wrap.c"
GLWRAP_OBJ="$REPO_ROOT/build/gl_dlopen_wrap.o"
GLWRAP_FLAGS=""
if [ -f "$GLWRAP_SRC" ]; then
  mkdir -p "$REPO_ROOT/build"
  "$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe" --target="$TRIPLE$API" -fPIC -O2 \
    -c "$(cygpath -m "$GLWRAP_SRC" 2>/dev/null || echo "$GLWRAP_SRC")" \
    -o "$(cygpath -m "$GLWRAP_OBJ" 2>/dev/null || echo "$GLWRAP_OBJ")" || exit 11
  GLWRAP_FLAGS="-Wl,--wrap=dlopen -Wl,--wrap=dlsym $(cygpath -m "$GLWRAP_OBJ" 2>/dev/null || echo "$GLWRAP_OBJ") -llog"
  echo "glwrap   : dlopen(libGLESv2.so) -> gl4es, dlsym(glGetStringi) null-guarded inside libopenmw.so"
fi

cmake -S "$SRC" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM="$PLATFORM" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS="$COMPAT_CXX_FLAGS" \
  -DOPENGL_opengl_LIBRARY="$GL_LIBRARY" \
  -DOPENGL_gl_LIBRARY="$GL_LIBRARY" \
  -DOPENGL_glx_LIBRARY="$LIBS/libEGL.so" \
  -DOPENGL_INCLUDE_DIR="$GL_INCLUDE" \
  -DOPENMW_GL4ES_MANUAL_INIT=ON \
  -DBUILD_LAUNCHER=0 \
  -DBUILD_WIZARD=0 \
  -DBUILD_OPENCS=0 \
  -DBUILD_MWINIIMPORTER=0 \
  -DBUILD_ESSIMPORTER=0 \
  -DBUILD_BSATOOL=0 \
  -DBUILD_ESMTOOL=0 \
  -DBUILD_NIFTEST=0 \
  -DBUILD_NAVMESHTOOL=0 \
  -DBUILD_BULLETOBJECTTOOL=0 \
  -DBUILD_OPENCS_TESTS=0 \
  -DOPENMW_USE_SYSTEM_MYGUI=ON \
  -DMYGUI_STATIC=ON \
  -DOPENMW_USE_SYSTEM_OSG=ON \
  -DOSG_STATIC=ON \
  -DOPENMW_USE_SYSTEM_BULLET=ON \
  -DOPENMW_USE_SYSTEM_ICU=ON \
  -DOPENMW_USE_SYSTEM_YAML_CPP=OFF \
  -DOPENMW_USE_SYSTEM_SQLITE3=OFF \
  ${FFMPEG_VERSION_FLAGS[@]+"${FFMPEG_VERSION_FLAGS[@]}"} \
  ${DEPS:+-DCMAKE_SHARED_LINKER_FLAGS="-L$DEPS_WIN/lib $GLWRAP_FLAGS"} \
  ${DEPS:+-DCMAKE_EXE_LINKER_FLAGS="-L$DEPS_WIN/lib"} \
  ${DEPS:+-DOPENMW_DEPENDENCIES_DIR="$DEPS"} \
  ${DEPS:+-DPNG_PNG_INCLUDE_DIR="$DEPS/include/libpng16"} \
  ${DEPS:+-DPNG_LIBRARY="$DEPS/lib/libpng.a"} \
  ${DEPS:+-DJPEG_INCLUDE_DIR="$DEPS/include"} \
  ${DEPS:+-DJPEG_LIBRARY="$DEPS/lib/libjpeg.a"} \
  ${DEPS:+-DFREETYPE_INCLUDE_DIRS="$DEPS/include/freetype2"} \
  ${DEPS:+-DFREETYPE_LIBRARY="$DEPS/lib/libfreetype.a"} \
  ${PREFIX:+-DCMAKE_PREFIX_PATH="$PREFIX"} \
  ${SDL2_ROOT:+-DSDL2_DIR="$SDL2_ROOT/lib/cmake/SDL2"} \
  ${DEPS:+-DCMAKE_INCLUDE_PATH="$DEPS/include"} \
  ${DEPS:+-DCMAKE_LIBRARY_PATH="$DEPS/lib"} \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
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
