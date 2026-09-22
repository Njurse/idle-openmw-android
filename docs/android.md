# Running idle-openmw on a virtual phone

This is the drop-in-ready path: from "Morrowind is on Steam" to "OpenMW is running
on an emulator with the mod loaded". Everything that *can* be automated is
automated; the two things that cannot are named explicitly at the end.

> **The game data is yours and is never committed.** `gamedata/` is gitignored.
> It is copyright Bethesda, it is ~600 MB, and pushing it to GitHub would be both
> a licence violation and a terrible idea. Keep it local.

---

## TL;DR

```bash
python tools/android/gamedata.py --find      # locate your Morrowind install
python tools/android/gamedata.py --import    # stage the data into ./gamedata
python tools/android/tests/test_gamedata.py  # 24 unit tests, no game needed

bash tools/android/provision-emulator.sh     # SDK bits + a 4 KB-page AVD
bash tools/android/run-on-emulator.sh        # boot, install, push, launch
```

---

## What is already on this machine

Found by `provision-emulator.sh`; recorded here because it is not obvious:

| Piece | Where | State |
|---|---|---|
| Android SDK | `%LOCALAPPDATA%\Android\Sdk` | platforms 34/35/36/37, build-tools 35–37, platform-tools, emulator 36.5.11 |
| JDK 21 | `C:\Program Files\Java\jdk-21.0.11` | ✅ |
| Hypervisor | WHPX | ✅ installed **and usable** (`emulator -accel-check`) |
| CPU / RAM | 12 logical cores / 24 GB | ample |
| `sdkmanager` | — | ❌ fetched by the provision script (155 MB) |
| System image | only `android-37.0 google_apis_playstore_ps16k x86_64` | ❌ wrong kind — see below |
| NDK, Gradle, `make` | — | ❌ only needed to *build* OpenMW, not to run it |

Existing AVD `Medium_Phone` is deliberately **not** used.

## The 16 KB page-size trap (the finding that shaped this)

`Medium_Phone` runs a `page_size_16kb` system image (Android 15+ requirement).
OpenMW's native libraries are **4 KB-aligned**, so a 16 KB device refuses to load
them — you would get a link failure with nothing obviously wrong in the mod:

```
$ python tools/android/gamedata.py --find && unzip -o -q omw.apk 'lib/x86_64/*'
max PT_LOAD align across libs: 0x1000 (4096 bytes)
16KB-page-safe: NO
  4KB-only: libopenmw.so 0x1000
  4KB-only: libSDL2.so   0x1000
  4KB-only: libc++_shared.so 0x1000     (8 of 8 libs)
```

So `provision-emulator.sh` creates a **separate AVD on a 4 KB-page image**
(`android-34;google_apis;x86_64`). It also raises RAM to 4 GB and the data
partition to 8 GB — the game data alone is ~600 MB.

## The APK: use the released one, and know its limits

`run-on-emulator.sh` installs a released build automatically if you have not
provided one:

```
https://github.com/xyzz/openmw-android/releases/download/0.48.0-46-nightly/omw_release_0.48.0-46.apk
```

Facts about it, all verified rather than assumed:

- package `is.xyz.omw_nightly`, versionName `0.48.0-46-nightly`, **targetSdk 29**;
- ships **`arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64`** — the x86_64 set is why it
  can run on an x86_64 emulator at all, and it is the reason this path works;
- built in **July 2021**, and `xyzz/openmw-android` is now marked *"No longer
  under development"*. It is an unsupported binary.

Consequences worth stating plainly:

- The engine is **OpenMW 0.48**, so the Lua API surface is 0.48's. Everything in
  `docs/openmw-lua-api.md` was verified against a **current** checkout, so if a
  call misbehaves on this build, check whether it landed after 0.48.
- A 2021 APK on a 2026 emulator is not a supported combination. Expect to fight
  the GPU path before you fight anything in the mod.

## Two things that cannot be automated

1. **Picking the data folder.** OpenMW for Android asks *you* to choose the data
   directory on first run, through the system file picker. The script pushes
   everything to `/storage/emulated/0/Morrowind` and writes
   `openmw.cfg.android` there; point the launcher at that folder once and it is
   remembered. The layout matches `docs/deployment.md` exactly, so the emulator
   and a real S23+ behave identically.
2. **Owning Morrowind.** `gamedata.py` finds a Steam/GOG install or takes
   `--source <path>`. It will not download one.

## Building OpenMW for Android (the big, blocked path)

Only needed if you want an engine *newer* than 0.48, or x86_64 rebuilt from
current source. It is genuinely large:

1. `xyzz/openmw-android`'s `buildscripts/build.sh` downloads the Android NDK and
   compiles Boost, OpenSceneGraph, MyGUI, Bullet, ICU, SDL2, FFmpeg and more for
   the target ABI. **Hours.**
2. It requires a **Unix toolchain**: `bash`, `gcc`, `g++`, `sha256sum`, `unzip`
   and **`make`**. This machine has MSYS + a clang shim but **no `make`** and no
   WSL, so it cannot run here without installing MSYS2 or WSL2 first.
3. Mainline OpenMW has only token Android support (`CMakeLists.txt:73`, a couple
   of `#ifdef ANDROID`); the port is a fork, and an abandoned one.
4. On a **16 KB** device the result also needs
   `-Wl,-z,max-page-size=16384` and an NDK that defaults to it (r27+).

None of this blocks the Lua work, which is why the effort went there first: the
mod is engine-version-agnostic Lua and it runs identically on desktop OpenMW.

## Faster sanity checks that need no emulator

Most regressions are caught long before a device is involved:

```bash
python tools/run_tests.py --all      # 322 Lua specs, LuaJIT + Lua 5.1 + Lua 5.4
python tools/run_tests.py --sim      # 1000-game-hour invariant run
python tools/android/tests/test_gamedata.py   # 24 data-staging unit tests
```

The only thing the emulator can prove that these cannot is **pixels**: whether
`ui.create` draws the console legibly on a real screen.

## Desktop OpenMW is the better first target

You already have `F:\Games\OpenMW Latest`. Pointing it at the staged data is
one line, and it exercises the same Lua against a real engine with a real GPU:

```bash
python tools/android/gamedata.py --print-cfg ./gamedata   # paste into your user openmw.cfg
```

That is worth doing *before* wrestling the emulator: it separates "the mod is
broken" from "the 2021 APK on a 2026 emulator is grumpy".
