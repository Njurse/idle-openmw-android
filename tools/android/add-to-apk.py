"""tools/android/add-to-apk.py

Put classes.dex and the native libraries into an APK that aapt2 already produced.

aapt2 can package resources and a manifest, and (with -A) assets, but it has no notion of a dex
file or of jniLibs -- those are Android Gradle Plugin conventions, not APK format features. The APK
format itself is just a zip with agreed-upon entry names, so this does it directly and keeps the
build free of Gradle.

Everything is written with STORED (uncompressed) entries for the .so files, which is what
android:extractNativeLibs="true" plus page alignment want: a compressed library cannot be mmapped
from inside the archive.
"""

import shutil
import sys
import zipfile


def main() -> int:
    if len(sys.argv) != 6:
        print(__doc__)
        print("usage: add-to-apk.py <base.apk> <out.apk> <classes.dex> <libdir> <abi>")
        return 2

    base_apk, out_apk, dex_path, lib_dir, abi = sys.argv[1:6]

    # Copy the aapt2 output, then append. Rewriting rather than editing in place keeps the
    # original as evidence of what aapt2 alone produced.
    shutil.copyfile(base_apk, out_apk)

    added = []
    with zipfile.ZipFile(out_apk, "a", zipfile.ZIP_DEFLATED) as apk:
        apk.write(dex_path, "classes.dex")
        added.append("classes.dex")

    # The libraries go in a second pass so they can be STORED rather than deflated.
    with zipfile.ZipFile(out_apk, "a", zipfile.ZIP_STORED) as apk:
        import os

        for name in sorted(os.listdir(lib_dir)):
            if not name.endswith(".so"):
                continue
            entry = "lib/%s/%s" % (abi, name)
            info = zipfile.ZipInfo(entry)
            info.compress_type = zipfile.ZIP_STORED
            # 4-byte alignment is what zipalign enforces afterwards; storing uncompressed here is
            # what lets it do so without recompressing the multi-hundred-megabyte library.
            info.external_attr = 0o644 << 16
            with open(os.path.join(lib_dir, name), "rb") as fh:
                apk.writestr(info, fh.read())
            added.append(entry)

    print("  packaged:", ", ".join(added))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
