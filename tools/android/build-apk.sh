#!/usr/bin/env bash
# tools/android/build-apk.sh
#
# Package libopenmw.so into an installable APK -- WITHOUT Gradle.
#
# WHY NOT GRADLE
# --------------
# Nothing here needs it. The app is one activity (an SDLActivity subclass), no libraries, no
# resources worth resolving, and every tool the job needs is already in the Android SDK:
#
#   javac (JDK)  ->  d8  ->  aapt2  ->  zip  ->  zipalign  ->  apksigner
#
# Gradle would add a download, a wrapper, a plugin resolution and a daemon to that list, and the
# project has a standing rule against adding a dependency to something a script can do.
#
# A WINDOWS DETAIL THAT COSTS AN HOUR IF YOU MISS IT
# --------------------------------------------------
# All the Android tools are Windows binaries. A path handed to one as an ARGUMENT has to be in
# C:/... form -- a Git Bash /c/... path is read as the relative path "c/..." and produces a
# confusing "file not found" for a file that plainly exists. -D-style variables that CMake resolves
# itself are fine either way; command arguments are not. So every path that becomes an argument
# goes through `win()` below.
#
# WHAT IT NEEDS ON DISK
#   build/android-out/lib/arm64-v8a/*.so   the engine and its shared dependencies
#   build/android-sdl2/SDL2-<ver>/         SDL2's Java side (from build-sdl2.sh)
# see docs/android.md for how those are produced.
#
# USAGE
#   bash tools/android/build-apk.sh                 # the real thing: arm64 + the engine
#   bash tools/android/build-apk.sh --abi x86_64
#   bash tools/android/build-apk.sh --ui-only       # the shell with NO engine, for the emulator
#
# --ui-only exists because the APK is arm64-v8a (the published dependency archive is) and QEMU2
# refuses to emulate arm64 on an x86_64 host (docs/android.md), so the local AVD cannot run the
# real thing. It CAN run the same Java with no native libraries, which is how the UI is reviewed
# from this machine instead of only on a phone. The app notices: LauncherActivity starts
# AppActivity when libopenmw.so is absent.
set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APK_SRC="$REPO_ROOT/tools/android/apk"
ABI="arm64-v8a"
ABI_GIVEN=0
UI_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --abi) ABI="$2"; ABI_GIVEN=1; shift 2 ;;
    --ui-only) UI_ONLY=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# A UI-only APK is for the emulator, so default it there rather than to the phone's ABI. Say so
# instead of doing it silently: the ABI decides which device can install this file.
if [ "$UI_ONLY" = "1" ] && [ "$ABI_GIVEN" = "0" ]; then
  ABI="x86_64"
  echo "--ui-only: defaulting --abi to x86_64 (the emulator's architecture)"
fi

# P:\ -> P:/ so the Windows tools can open it. Falls back to the input when cygpath is absent.
win() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

# --- SDK toolchain -------------------------------------------------------------------------
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$USERPROFILE/AppData/Local/Android/Sdk}}"
SDK="${SDK//\\//}"
BT="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)"
PLATFORM="$(ls -d "$SDK"/platforms/android-* 2>/dev/null | sort -V | tail -1)"
[ -n "$BT" ] || { echo "no build-tools in $SDK/build-tools" >&2; exit 2; }
[ -n "$PLATFORM" ] || { echo "no platforms in $SDK/platforms" >&2; exit 2; }

ANDROID_JAR="$(win "$PLATFORM/android.jar")"
AAPT2="$BT/aapt2.exe";     [ -f "$AAPT2" ]     || AAPT2="$BT/aapt2"
D8="$BT/d8.bat";           [ -f "$D8" ]        || D8="$BT/d8"
ZIPALIGN="$BT/zipalign.exe"; [ -f "$ZIPALIGN" ] || ZIPALIGN="$BT/zipalign"
APKSIGNER="$BT/apksigner.bat"; [ -f "$APKSIGNER" ] || APKSIGNER="$BT/apksigner"
JAVAC="${JAVAC:-javac}"
# keytool ships with the JDK but is NOT always on PATH (on this machine java/javac are shimmed
# through Oracle's javapath and keytool is not shimmed at all), so find it next to the JDK that
# JAVA_HOME names before giving up.
KEYTOOL="${KEYTOOL:-}"
if [ -z "$KEYTOOL" ]; then
  if command -v keytool >/dev/null 2>&1; then
    KEYTOOL="keytool"
  elif [ -n "${JAVA_HOME:-}" ] && [ -f "$JAVA_HOME/bin/keytool.exe" ]; then
    KEYTOOL="$JAVA_HOME/bin/keytool.exe"
  elif [ -n "${JAVA_HOME:-}" ] && [ -f "$JAVA_HOME/bin/keytool" ]; then
    KEYTOOL="$JAVA_HOME/bin/keytool"
  else
    KEYTOOL="keytool"
  fi
fi

# --- inputs --------------------------------------------------------------------------------
LIBS_DIR="$REPO_ROOT/build/android-out/lib/$ABI"
SDL_SRC="$(ls -d "$REPO_ROOT"/build/android-sdl2/SDL2-* 2>/dev/null | grep -v '\.tar\.gz' | sort -V | tail -1 || true)"
WORK="$REPO_ROOT/build/android-apk"
if [ "$UI_ONLY" = "1" ]; then
  OUT="$REPO_ROOT/build/android-out/idle-openmw-ui-only-$ABI.apk"
else
  OUT="$REPO_ROOT/build/android-out/idle-openmw.apk"
fi

if [ "$UI_ONLY" = "1" ]; then
  : # no engine to check for; the packaging step passes an empty staging dir instead
else
  [ -f "$LIBS_DIR/libopenmw.so" ] || { echo "no $LIBS_DIR/libopenmw.so -- build the engine first (docs/android.md)" >&2; exit 2; }
  # libopenal.so and libcollada-dom need the NDK's shared C++ runtime; without it SDL's loadLibrary
  # fails ("libc++_shared.so not found"). Always refresh it from the newest NDK.
  case "$ABI" in arm64-v8a) TRIPLE=aarch64-linux-android;; x86_64) TRIPLE=x86_64-linux-android;; armeabi-v7a) TRIPLE=arm-linux-androideabi;; *) TRIPLE=;; esac
  SDK_DIR="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-${LOCALAPPDATA:-$HOME/AppData/Local}/Android/Sdk}}"
  LIBCXX="$(ls -d "$SDK_DIR"/ndk/*/toolchains/llvm/prebuilt/*/sysroot/usr/lib/$TRIPLE/libc++_shared.so 2>/dev/null | sort -V | tail -1 || true)"
  if [ -n "$TRIPLE" ] && [ -f "$LIBCXX" ]; then cp -f "$LIBCXX" "$LIBS_DIR/"; else echo "warning: libc++_shared.so not found in NDK" >&2; fi
fi
# SDL2's Java side is needed either way: SDLActivity and friends are compiled into the dex, and the
# shell is a subclass of SDLActivity (an empty library list is fine, a missing class is not).
if [ -z "${SDL_SRC:-}" ] || [ ! -d "$SDL_SRC/android-project" ]; then
  echo "no SDL2 source tree -- run: bash tools/android/build-sdl2.sh" >&2
  exit 2
fi

echo "build-tools : $BT"
echo "platform    : $PLATFORM"
echo "ABI         : $ABI"
if [ "$UI_ONLY" = "1" ]; then
  echo "libraries   : (none -- UI-only build, no engine)"
else
  echo "libraries   : $(ls "$LIBS_DIR" | tr '\n' ' ')"
fi
echo

rm -rf "$WORK"; mkdir -p "$WORK/java" "$WORK/classes" "$WORK/dex" "$WORK/res"

# --- 1. Java: SDL2's own classes + ours ----------------------------------------------------
cp -r "$APK_SRC/src/." "$WORK/java/"
cp -r "$SDL_SRC/android-project/app/src/main/java/." "$WORK/java/"

echo "== javac =="
# Listing sources through win() and using a response file: a few hundred SDL2 files would blow
# Windows' command-line limit, and the file it writes has to be readable by a Windows javac.
find "$WORK/java" -name "*.java" | while read -r f; do win "$f"; done > "$WORK/sources.txt"
"$JAVAC" -nowarn --release 11 \
  -classpath "$ANDROID_JAR" \
  -d "$(win "$WORK/classes")" \
  "@$(win "$WORK/sources.txt")" 2>&1 | grep -vE "^Note:|^warning:" || true
[ -f "$WORK/classes/is/xyz/idle_openmw/LauncherActivity.class" ] \
  || { echo "LauncherActivity did not compile" >&2; exit 1; }
[ -f "$WORK/classes/is/xyz/idle_openmw/MainActivity.class" ] \
  || { echo "MainActivity did not compile" >&2; exit 1; }

echo "== d8 =="
find "$WORK/classes" -name "*.class" | while read -r f; do win "$f"; done > "$WORK/classes.txt"
"$D8" --min-api 24 --release --lib "$ANDROID_JAR" \
  --output "$(win "$WORK/dex")" "@$(win "$WORK/classes.txt")" 2>&1 | tail -3
[ -f "$WORK/dex/classes.dex" ] || { echo "d8 produced no classes.dex" >&2; exit 1; }

echo "== aapt2 =="
# No resources are compiled. The manifest uses literal labels rather than @string/app_name, so
# there is nothing for aapt2 to merge; passing a resource archive here made aapt2 treat it as an
# OVERLAY and refuse ("failed to merge resource table ... use --auto-add-overlay") for resources
# the manifest never referenced. Fewer moving parts, and the app has no UI resources of its own.
"$AAPT2" link \
  -o "$(win "$WORK/base.apk")" \
  -I "$ANDROID_JAR" \
  --manifest "$(win "$APK_SRC/AndroidManifest.xml")" \
  --min-sdk-version 24 \
  --target-sdk-version 34 \
  --version-code 1 --version-name 0.52.0-idle \
  2>&1 | tail -3
[ -f "$WORK/base.apk" ] || { echo "aapt2 link produced no apk" >&2; exit 1; }

# --- 2. Strip the native libraries ------------------------------------------------------------
# The dependency archive ships its shared libraries WITH debug info: libcollada-dom2.5-dp.so came in
# at 77.8 MB and libopenal.so at 9.5 MB, which together were more than a third of the APK. None of
# that belongs on a phone, and stripping is lossless for behaviour. It took the payload from 189 MB
# to 115 MB. (libopenmw.so was already stripped, by the build itself.)
#
# Stripping happens into a staging directory rather than in place, so the build tree stays exactly
# as the compiler produced it and a re-run is idempotent.
echo "== stripping the native libraries =="
if [ "$UI_ONLY" = "1" ]; then
  echo "  (UI-only build: there are none)"
fi
STRIP_TOOL="${NDK:-}/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-strip.exe"
if [ ! -f "$STRIP_TOOL" ]; then
  SDK_NDK="$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1)"
  STRIP_TOOL="$SDK_NDK/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-strip.exe"
fi
STRIPPED="$WORK/lib-stripped"
mkdir -p "$STRIPPED"
# Both loops below must be skipped for a UI-only build. An unmatched glob in a `for` list expands to
# the PATTERN itself rather than to nothing, so with `set -e` a cp of ".../no-libraries/*.so" would
# abort the build -- the empty directory has to be handled by not looping, not by globbing it.
if [ "$UI_ONLY" != "1" ]; then
  for so in "$LIBS_DIR"/*.so; do
    cp "$so" "$STRIPPED/"
  done
  if [ -f "$STRIP_TOOL" ]; then
    for so in "$STRIPPED"/*.so; do
      before=$(stat -c %s "$so" 2>/dev/null || echo 0)
      "$STRIP_TOOL" --strip-unneeded "$so" >/dev/null 2>&1 || true
      after=$(stat -c %s "$so" 2>/dev/null || echo 0)
      printf '  %-30s %10s -> %10s\n' "$(basename "$so")" "$before" "$after"
    done
  else
    echo "  (no llvm-strip found; packaging unstripped -- expect a much larger APK)" >&2
  fi
fi

# --- 3. Add the dex and the native libraries ------------------------------------------------
echo "== packaging (dex + jniLibs) =="
mkdir -p "$(dirname "$OUT")"
python "$REPO_ROOT/tools/android/add-to-apk.py" \
  "$WORK/base.apk" "$OUT" \
  "$WORK/dex/classes.dex" \
  "$STRIPPED" "$ABI"

# --- 3. Align and sign ----------------------------------------------------------------------
# The keystore lives OUTSIDE $WORK on purpose: the work directory is wiped at the top of every
# build, so a keystore inside it would be regenerated each time, and a re-signed APK with a
# different key makes `adb install -r` fail with a signature mismatch -- exactly the command the
# emulator loop uses. Debug key, stable across builds, install-upgrade works.
KS="$REPO_ROOT/build/android-keystore/debug.keystore"
if [ ! -f "$KS" ]; then
  mkdir -p "$(dirname "$KS")"
  echo "== generating a debug keystore =="
  "$KEYTOOL" -genkeypair -v -keystore "$(win "$KS")" -storepass android -keypass android \
    -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
fi
echo "== zipalign + apksigner =="
ALIGNED="${OUT%.apk}-aligned.apk"
"$ZIPALIGN" -f -p 4 "$(win "$OUT")" "$(win "$ALIGNED")"
mv "$ALIGNED" "$OUT"
"$APKSIGNER" sign --ks "$(win "$KS")" --ks-pass pass:android --key-pass pass:android \
  --ks-key-alias androiddebugkey "$(win "$OUT")" 2>&1 | tail -2
"$APKSIGNER" verify "$(win "$OUT")" 2>&1 | tail -3 || true

echo
echo "APK: $OUT  ($(du -h "$OUT" | cut -f1))"
if [ "$UI_ONLY" = "1" ]; then
  echo "     UI-only: no engine. Install on an emulator to review the shell (AppActivity)."
  echo "     Confirm it carries no native libraries: unzip -l \"$OUT\" | grep -c 'lib/'"
fi
