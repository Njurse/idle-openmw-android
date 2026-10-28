#!/usr/bin/env bash
# tools/dev/engine-build/apply-patches.sh
#
# Apply the fork's engine patches to a checkout of OpenMW. Idempotent, and loud when it cannot.
#
# WHY THIS IS A SCRIPT RATHER THAN A BLOCK IN build.sh
# ---------------------------------------------------
# There are TWO engines in this project, and they are built by two different scripts:
#
#   desktop  tools/dev/engine-build/build.sh          (MSVC + vcpkg, the fork the mod iterates on)
#   Android  tools/android/configure-android.sh       (NDK r29 + the published dependency archive)
#
# Until this existed, only the DESKTOP build applied tools/dev/engine-build/patches/. The Android
# engine therefore built happily WITHOUT the fork's changes, and nothing said so -- because a
# missing Lua binding is not a build error. It is a runtime error on a phone, which is the most
# expensive place in this project to find one.
#
# The patches are the fork. Anything the fork changes has to reach both builds, so the application
# step lives in one place and both scripts call it.
#
# Usage:
#   bash tools/dev/engine-build/apply-patches.sh [<openmw checkout>]
#
# Default checkout: $OMW_SRC, else .research/openmw.
#
# Exit codes: 0 all patches applied (or already were); 10 a patch does not apply cleanly, meaning
# the checkout has drifted from what the patch expects. That is a stop-the-build condition: a
# half-patched engine is worse than an unpatched one.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
PATCH_DIR="$REPO/tools/dev/engine-build/patches"
SRC="${1:-${OMW_SRC:-$REPO/.research/openmw}}"

if [ ! -d "$SRC" ]; then
  echo "== no OpenMW checkout at $SRC (skip)" >&2
  exit 0
fi

if [ ! -d "$PATCH_DIR" ]; then
  echo "== no patch directory at $PATCH_DIR (skip)" >&2
  exit 0
fi

# Sorted, so the order is the file names -- which is why they are numbered. 0002 depends on 0001
# having been applied only in the sense that both touch apps/openmw/CMakeLists.txt.
for p in "$PATCH_DIR"/*.patch; do
  [ -e "$p" ] || continue
  name="$(basename "$p")"

  # Three states, and they must be told apart rather than assumed:
  #   applies forward   -> it is not applied yet, apply it
  #   applies in reverse -> it is already applied, leave it alone
  #   neither            -> the checkout has drifted, stop
  if (cd "$SRC" && patch -p1 --forward --silent --dry-run < "$p" >/dev/null 2>&1); then
    (cd "$SRC" && patch -p1 --forward --silent < "$p") && echo "== applied patch $name"
  elif (cd "$SRC" && patch -p1 --reverse --silent --dry-run < "$p" >/dev/null 2>&1); then
    echo "== patch $name already applied"
  else
    echo "!! patch $name does not apply cleanly to $SRC" >&2
    echo "   the checkout has drifted from what the patch expects" >&2
    exit 10
  fi
done
