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

---

# Verified on the emulator (what actually happened)

Everything below was observed on a real virtual device, not inferred. The
milestones are listed in the order they were reached, with the evidence.

| # | Milestone | Evidence |
|---|---|---|
| 1 | Virtual device boots, right shape for OpenMW | `Android 14 (API 34)`, `abi=x86_64`, `PAGE_SIZE=4096` |
| 2 | OpenMW 0.48 installs and **renders** | screenshot 1080x2340, 270 distinct colours, grey/white launcher UI |
| 3 | The port accepts the game data | Setup shows `Game files → /storage/emulated/0/Morrowind`, no error |
| 4 | The **engine runs** | OpenAL context created, `openmw.cfg` (66 KB) + `openmw.base.cfg` generated |
| 5 | Our mod enters the content list | regenerated config contains `content=idle_openmw.omwscripts` |

## Finding A — the launcher needs the install ROOT, not `Data Files`

The first attempt pointed "Game files" at `.../Morrowind/Data Files` and got:

> **Error locating data files** — *"Please select a directory which contains both
> the \"Morrowind.ini\" file and the \"Data Files\" directory."*

From the port's source (`app/src/main/java/file/GameInstaller.kt`):

```kotlin
fun check(): Boolean {
    if (!dir.exists() || !dir.isDirectory) return false
    return findCaseInsensitive(INI_NAME) != null     // morrowind.ini
        && findCaseInsensitive(DATA_NAME) != null    // "Data Files"
}
```

It then **parses that ini** (`convertIni`) to generate `openmw.cfg`. So
`Morrowind.ini` is not optional, and it belongs beside `Data Files`, not inside
it. `tools/android/gamedata.py` now stages exactly that tree, and its unit tests
cover the case-insensitivity the launcher uses.

## Finding B — this launcher cannot register `.omwscripts` at all

`app/src/main/java/mods/ModsCollection.kt`:

```kotlin
private var extensions: Array<String> = if (type == ModType.Resource)
    arrayOf("bsa")
else
    arrayOf("esm", "esp", "omwaddon", "omwgame")
```

`.omwscripts` is **not** in that list, and the scan is a non-recursive
`File(dataFiles).listFiles()`. So the Mods screen can never show our manifest,
and the only way in is to inject the `content=` line by hand.

`openmw.cfg` is **regenerated from scratch on every launch**:

```kotlin
var output = base + "\n" + fallback + "\n"     // base = openmw.base.cfg, read verbatim
plugins.mods.filter { it.enabled }.forEach { output += "content=${it.filename}\n" }
File(Constants.OPENMW_CFG).writeText(output)
```

Hand-editing `openmw.cfg` is therefore pointless; `openmw.base.cfg` is the durable
hook, and that is what `run-on-emulator.sh` writes to.

## Finding C — and the engine still cannot load the file

With the line injected, OpenMW failed at startup with a dialog (which is easy to
miss — the process stays alive behind it, so the app **looks** like it started):

```
OpenMW: Fatal error
Cannot load file: /storage/emulated/0/Morrowind/Data Files/idle_openmw.omwscripts
```

The isolating test: **remove the line and the error disappears** and the engine
runs on. So the location is perfectly readable (`Morrowind.esm` loads from that
same directory) — **this OpenMW 0.48 build cannot load `.omwscripts` content.**

That is a hard incompatibility between our manifest format and this 2021 APK, not
a configuration mistake. Options, in order of preference:

1. **Build OpenMW ≥ 0.49 for Android** (the `.omwscripts` support and the Lua API
   this mod is written against). Needs the NDK + a Unix toolchain — see below.
2. **Ship a legacy `.esp`-free fallback**: register the mod through a content type
   the launcher *does* accept. `omwaddon`/`omwgame` are recognised extensions, but
   they are record files, not script manifests, so this means generating a stub
   addon that carries no records — workable but a hack.
3. **Patch the launcher** to add `omwscripts` to its extensions array and rebuild
   the APK (small change; still needs the Android build).

## Finding D — the game renders sideways (confirmed)

```
framebuffer  : 2340x1080        (the device is portrait)
mBounds      : Rect(0, 0 - 2340, 1080)
mAppBounds   : Rect(136, 0 - 2340, 1014)
mRotation    : ROTATION_90
```

OpenMW forces landscape, so on a phone it is sideways, and the system applies the
cutout/nav inset on the *left* (`mAppBounds.x = 136`) because it thinks it is
landscape. Fixing this is C++/manifest work in the port, not Lua:

- set portrait in the port's `AndroidManifest.xml` activity config;
- stop SDL forcing a landscape mode (the port sets it for the SDLWindow);
- honour `displayCutout` + `navigationBars` insets for the top and the gesture bar.

## Finding E — the architecture this wants (the framework request)

The changes above are all *port-level* edits, and they will need to be re-applied
whenever the port is rebuilt. So they should live in one place rather than being
scattered: a thin **`android/patch/` layer** — a small set of documented,
idempotent patches (manifest, orientation, insets, the mod-registration fix)
applied by script after any upstream refresh, plus a **native host view** that
sits below a portrait game surface and hosts our own menu.

That is the natural next phase, and it is *not* Lua work: it is the Android shell
plus one patch layer. It is the right way to make "rotate to portrait, put our
menu underneath" survive the next build.

---

# Where this stopped, and exactly what is needed

## Finding C (settled) — the engine predates `.omwscripts` itself

My first claim was right, my hedge was wrong, and now there is proof rather than
confidence. `.omwscripts` support arrived with **OpenMW 0.48.0**, and this APK is
older than that release by two years:

| Fact | Value |
|---|---|
| `omw_release_0.48.0-46.apk` published | **2021-07-18** |
| OpenMW **0.48.0** released | **2023-07-22** |
| `files/data/builtin.omwscripts` at `openmw-0.47.0` | **absent** (`files/data` 404s) |
| `files/data/builtin.omwscripts` at `openmw-0.48.0` | **present** |
| `.omwscripts` entries inside the APK | **0** |

The port's "0.48.0-46" is the **port's own** version numbering, not OpenMW's. The
engine inside is a July 2021 master snapshot, which is *before* the feature
existed. That is also why the APK's `assets/libopenmw/resources/vfs/` holds
`openmw_aux/util.lua` but no `builtin.omwscripts` — there was nothing to ship.

So every file-level explanation is ruled out, each by experiment:

| Hypothesis | Verdict |
|---|---|
| Wrong folder selected (data dir vs root) | ruled out — root works, `check()` passes |
| File permissions | ruled out — identical to `Morrowind.esm`, which loads |
| The space in "Data Files" | **ruled out by experiment** — same failure at `/storage/emulated/0/omwmod/` |
| Lua missing from the build | ruled out — `ExternalProject_Add(luajit)`; but that is *Lua*, not the `.omwscripts` loader |
| Data-dir/VFS resolution | consistent with everything, but moot: the loader does not exist in this build |

**Consequence: no configuration change can make this APK load the mod.** It needs
an engine built from OpenMW ≥ 0.48 with the port's Android changes on top — which
is exactly the build described below. It also means the "patch the launcher's
extensions array" idea, on its own, would not have been enough: the launcher would
list the file and the engine would still refuse it.

The practical upshot, and worth saying plainly: **desktop OpenMW runs this mod
today** (`python tools/android/gamedata.py --print-cfg`), and the emulator work
is banked for the day a modern engine is built.

## Why the build cannot start on this machine yet

The port's build system is **Linux-only**, by construction:

```bash
# buildscripts/include/download-ndk.sh
curl "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux-x86_64.zip"
# buildscripts/include/setup-ndk.sh
pushd toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
```

The NDK version is pinned in `buildscripts/include/version.sh`:

```
NDK_VERSION="r21e"  ANDROID_API="21"
```

NDK r21e does ship Windows host binaries, so the pin is not itself the problem —
the *scripts* are (Linux NDK zip, `prebuilt/linux-x86_64`, `bash -c`, `pushd`,
`sed -i`, and a `patches/` tree of Unix diffs). Getting this to build means
either:

- **WSL2 with a distro** — the straightforward route. It is **not installed**:
  `wsl --status`, `--version` and `--list` all print the usage banner, i.e. only
  the inbox stub is present, and `Microsoft-Windows-Subsystem-Linux` /
  `VirtualMachinePlatform` are not enabled. Enabling them **needs Administrator
  and normally a reboot** — which is why it was not done automatically. This is
  the one step that needs you.
- **A Linux VM or container** (Docker is not installed either).
- **Porting the build scripts to Windows + NDK r21e-win** — possible, but it means
  rewriting the dependency superbuild, and it would diverge from upstream.

## The good news: the port already has a patch layer

`buildscripts/patches/` is exactly the mechanism the framework request asked for:

```
bullet-fix-cmake.patch   mygui-dont-set-debug-postfix.patch
clang-ccache.sh          sdl2-android-120hz-gyroscope.patch
gas-preprocessor.pl      openmw/   osg/   gl4es/
```

Patches are applied during the build, so they survive an upstream refresh by
construction. The work for portrait + our menu belongs there:

| Change | Where |
|---|---|
| Portrait orientation | the port's `AndroidManifest.xml` (`android:screenOrientation`) + SDL window flags |
| Cutout / gesture-bar insets | `android:windowLayoutInDisplayCutoutMode`, plus inset handling in the activity |
| `omwscripts` in the Mods list | `mods/ModsCollection.kt` — add `"omwscripts"` to the plugin extensions array |
| Our menu hosted below the game | a native view under the SDL surface, or a second activity holding a portrait surface |

## What is verified and durable regardless

None of the above invalidates the platform work, which is done and reproducible
from the scripts in `tools/android/`:

- the AVD, image and page-size choices are correct and boot;
- the data stager produces the tree the launcher demands (root + `Morrowind.ini`);
- the launcher is configured reproducibly (`ui-drive.py`);
- the engine runs on the device and renders;
- and the mod is one `content=` line away from loading on any engine that supports it.

## Finding F — a stale `content=` line aborts the launch entirely (fixed, scripted)

Re-verified on the emulator: with `content=idle_openmw.omwscripts` present, the
engine does not merely *skip* the mod — it dies before the game starts:

```
OpenMW: Fatal error
Cannot load file: /storage/emulated/0/omwmod/idle_openmw.omwscripts
```

The line is not in `Morrowind.ini` (its `[Game Files]` holds only the three ESMs)
and not in the launcher's prefs; it is copied from the launcher's private
template, which is regenerated into the config the engine reads on every launch:

```
/data/user/0/is.xyz.omw_nightly/files/config/openmw.base.cfg   <- the template
/data/user/0/is.xyz.omw_nightly/files/config/openmw.cfg        <- generated from it
```

The launcher's **Mods** screen cannot remove it: its plugin list is
esm/esp/omwaddon/omwgame only (**Finding B**), so a `.omwscripts` entry is
invisible there. The template is the only place to fix it, and editing the
generated `openmw.cfg` does not stick — it is rewritten on the next launch.

Fix, scripted and idempotent (`adb root` required; a `google_apis` image allows it,
a PlayStore image does not):

```bash
bash tools/android/emulator-cfg-fix.sh            # show the stale lines
bash tools/android/emulator-cfg-fix.sh --apply    # back up, then remove them
```

After it, the launcher's **Play** button reaches `ui.activity.GameActivity` and
the engine loads content:

```
I] Loading content file Morrowind.esm
I] Loading content file Tribunal.esm
I] Loading content file Bloodmoon.esm
```

## Finding G — the emulator's GLES2 path stalls the renderer (not a mod problem)

With F fixed the engine boots and loads Morrowind, but the frame never advances.
Two `screencap`s six seconds apart (and one across a tap) are **byte-identical**,
while the process stays alive — the render loop is stalled, not crashed. The
engine's own log shows why:

```
W] ERROR: 0:3: 'dFdx' : built-in functions cannot be redefined
W] glLinkProgram ... FAILED
W] Program Link Failed for unknown reason.
```

The 2021 build's shaders expect desktop GLSL; the emulator's GLES2 translator
rejects them. So on this emulator the game is a frozen frame — before any mod
question arises. Two independent walls, then, both engine-side:

1. the engine **cannot load** `.omwscripts` (Findings B/C), and
2. the engine **cannot render** under the emulator's GLES path (this finding).

Neither is the mod's fault, and neither can be fixed from Lua or from data.

## What the device still proves, and what it cannot

Proven today, on the emulator:

- the AVD boots, the launcher runs, and `adb` can drive it and screenshot it;
- our staged data root satisfies the launcher (`/storage/emulated/0/Morrowind`);
- with the stale line removed the engine loads all three ESMs;
- the failure modes are **engine** failure modes, reproducible on demand.

Not provable here: that the console, tap-to-move, or the layout overrides look
right — the renderer never draws a second frame. That check needs a real device or
an engine built for it (`docs/ui-overhaul.md`, `docs/theme.md`), which is exactly
what `tools/preview_console.py` exists to substitute for until then.

Evidence frames: `build/device/` (`01-openmw-launch`, `03-boot`, `05-menu`,
`08-a`/`08-b` the identical pair).

---

## Current status (re-measured)

Checked again on this host, so the next session does not re-derive it:

- **The AVD `idle_openmw` boots in ~35s** (`emulator -avd idle_openmw -no-snapshot-save`,
  `adb wait-for-device` + `getprop sys.boot_completed`). `adb devices` shows
  `emulator-5554 device`.
- **The installed engine is still the 2021 build:** `is.xyz.omw_nightly`,
  `versionName = 0.48.0-46-nightly`. That "0.48.0-46" is the *port's* numbering; it predates
  OpenMW's `.omwscripts` support, which is the whole wall above.
- **The device is already fully staged** from an earlier session:
  `/storage/emulated/0/Morrowind/{Data Files,Mods/idle_openmw,Morrowind.ini,openmw.cfg.android}`,
  with `idle_openmw.omwscripts` and the mod's `scripts/` tree present in **both** `Data Files`
  and `Mods/idle_openmw`.
- **The NDK is installable on this Windows host.** `sdkmanager --list` offers
  `ndk;16.1.4479499` … `ndk;<newer>` as side-by-side packages. This corrects the assumption
  that an Android engine build needs a Linux toolchain: the *NDK itself ships for Windows*.
  What is genuinely Linux-shaped is `openmw-android`'s **build scripts** (they fetch a
  `prebuilt/linux-x86_64` tree and drive a CMake superbuild), not the compiler.

**So the next real step is concrete:** with an NDK installed, take the two tracks that
already exist in this repo and point them at Android instead of x86-windows — the fork
patches (`tools/dev/engine-build/patches/`) are the same engine either way — and produce an
APK whose engine is **≥ 0.49** (the mod's floor, `docs/openmw-lua-api.md`) so `.omwscripts`
loads. Until that APK exists, the emulator can prove the *device and data layout*, and
desktop OpenMW (or the forked build, `docs/engine-build.md`) is what plays the mod.

## The NDK works on Windows (measured)

`ndk;29.0.14206865` installed through `sdkmanager` (2.4 GB), and it cross-compiles from this host
without WSL:

```
$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe --version
  Android (13989888, based on r563880c) clang version 21.0.0
  Target: x86_64-w64-windows-gnu

clang --target=aarch64-linux-android24 -c t.c -o t.o   ->   COMPILED OK
```

So the missing piece was never the toolchain. It is the **build scripts**, and after reading
`buildscripts/CMakeLists.txt` the reason is bigger than the Linux paths noted below: the project
is a **superbuild** that downloads and builds its whole dependency set itself, pinned to
2019-2021 releases —

```
LIBJPEG_TURBO 1.5.3   LIBPNG 1.6.37   FREETYPE2 2.10.4   OPENAL 1.21.1
BOOST 1.69.0          FFMPEG 4.4      SDL2 2.0.12        BULLET 3.17
MYGUI 3.4.0           GL4ES v1.1.4
```

— against `NDK_VERSION="r21e" ANDROID_API="21"`, downloaded as the **Linux** NDK zip
(`android-ndk-${NDK_VERSION}-linux-x86_64.zip`) and driven from
`toolchains/llvm/prebuilt/linux-x86_64/bin`. A modern NDK (r27+ is what fixes the 16 KB page
size) plus the C++20 this OpenMW needs would mean bumping nearly every one of those pins too,
and diverging from upstream while doing it.

That is the real shape of the task, and it is why the next step is a **configure attempt against
the NDK toolchain with the superbuild bypassed**, not a script port: it answers "how far does our
own source get with a modern NDK" without first rewriting a decade of pinned dependencies.

## First Android configure, measured (the plan, in order)

The attempt, the superbuild bypassed and the NDK toolchain used directly:

```bash
NDK=$ANDROID_HOME/ndk/29.0.14206865
cmake -S .research/openmw -B build/android-configure -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 \
  -DCMAKE_BUILD_TYPE=Release
```

What it proves, step by step:

1. **The compiler phase succeeds.** CMake identifies Clang 21 as the cross-compiler, detects its
   ABI and features, and finds Git. Nothing about this host is in the way.
2. **The first real blocker is GL.** `CMakeLists.txt:278` does an unconditional
   `find_package(OpenGL REQUIRED)` — desktop OpenGL, which Android does not have. Pointing it at
   the NDK's own GLES (`libGLESv2.so` / `libEGL.so` / sysroot headers) satisfies it, and the
   configure moves on, so this is a *configure-time* obstacle rather than a porting job:
   `Found OpenGL: .../aarch64-linux-android/24/libGLESv2.so`.
3. **Then the dependency list.** With GL satisfied, the very next line stops it:
   `Could NOT find LZ4 (missing: LZ4_LIBRARY LZ4_INCLUDE_DIR LZ4_VERSION)` at
   `CMakeLists.txt:281`. LZ4 is the first of OSG, Boost, SDL2, MyGUI, Bullet, ffmpeg, OpenAL and
   the rest — every one of them REQUIRED, each one stopping the configure in turn.

**The conclusion this pins down:** OpenMW's CMake expects an Android dependency tree handed to it
via `OPENMW_DEPENDENCIES_DIR` (`CMakeLists.txt:73` adds it to `CMAKE_FIND_ROOT_PATH`). Its own
source is not the problem; the dependencies are. And the only thing in this project that produces
such a tree is `openmw-android`'s superbuild — pinned to NDK r21e and 2019-2021 libraries.

So the order of work is:

1. **Produce an Android dependency tree for a modern NDK.** Either port the superbuild (bumping
   Boost 1.69, ffmpeg 4.4, MyGUI 3.4, SDL2 2.0.12, gl4es and the rest one at a time), or build the
   set by hand for r29, or run the existing superbuild on a Linux host/CI where its scripts work
   unmodified — Docker is not installed here, and WSL2 needs an administrator.
2. **Point `OPENMW_DEPENDENCIES_DIR` at it** and re-run the configure above. Expect the GLES
   variables to move from the command line into the dependency tree.
3. **Then** the fork's own patches (`buildscripts/patches/`) and the Lua API revision this mod
   needs (>= 0.49 for `.omwscripts`; the fork is 0.52, revision 160).

Step 1 is the whole task, and it is a dependency-porting job, not a first-build-blocker like the
ones earlier in this project. That is worth knowing before starting it: the failure mode is slow
and additive, not a wall.

The log of this attempt is at `build/android-configure.log` (gitignored).

## Where this stands, and the one follow-up worth naming

**Done and measured on this host:** the emulator boots and is drivable; the device tree is staged;
the mod runs on desktop today; the NDK cross-compiles; and the Android configure has been taken as
far as it goes without a dependency tree, with both failures captured.

**The task, in one line:** produce an Android dependency tree (`OPENMW_DEPENDENCIES_DIR`) for a
modern NDK. Everything else on the engine side follows from it.

**Blocked on something else entirely:** even with a modern APK, unattended play on Android still
needs character creation to be finishable without a human. The fork must expose
`CharacterCreation`'s `mCreationStage` to Lua (or provide a scripted path that drives it) — see
`docs/chargen.md`, which records why: `chargenstate` is set to `-1` by Morrowind's own `CharGen`
script, and that script only runs while the world is **unpaused**, which is the opposite of the
state character creation holds. No amount of Lua can break that loop.

So a modern APK alone would still land on the same wall. The two are independent, and the chargen
hook is the cheaper of the two — it is also the half that would let the desktop path stop relying
on `--skip-menu=1`, which is how the world is reached today.

## The recipe (reproducible)

`bash tools/android/configure-android.sh` — it locates the newest installed NDK, maps the ABI to
the sysroot's ABI **triple** (`arm64-v8a` -> `aarch64-linux-android`, a mapping that fails
silently if you get it wrong: the `-D` paths just point at nothing), and reports the first error
rather than a wall of CMake output.

```
NDK      : .../ndk/29.0.14206865
ABI      : arm64-v8a  (platform android-24)
GLES dir : .../sysroot/usr/lib/aarch64-linux-android/24

Configure stopped (expected until the dependency tree exists). First error:
  Could NOT find LZ4 (missing: LZ4_LIBRARY LZ4_INCLUDE_DIR LZ4_VERSION)
```

A failing run is the informative outcome today, and `--abi x86_64` targets the emulator's
architecture. Passing `OPENMW_DEPENDENCIES_DIR=<tree>` adds the dependency search root
(CMakeLists.txt:73) and is the whole of the remaining work.

---

# IT BUILDS: `libopenmw.so` for Android, from Windows

Everything above is history. This is the state now, and it is measured:

```
build/android-out/lib/arm64-v8a/libopenmw.so
  ELF 64-bit LSB shared object, ARM aarch64, for Android 24,
  built by NDK r29 (14206865)
  924 MB with debug info  ->  104 MB stripped
```

Two scripts, run in order:

```bash
bash tools/android/configure-android.sh --deps "$(pwd)/build/android-deps/root"
bash tools/android/build-sdl2.sh                              # only needed once
cmake --build build/android-configure --target openmw -j 12
```

## Where the dependencies actually come from

`CI/before_install.android.sh` had the answer all along, and it is not a superbuild:

```bash
curl -fSL -R -J https://gitlab.com/OpenMW/openmw-deps/-/raw/main/android/
    openmw-android-deps-20240812.tar.xz      # 166 MB
tar -xJf it into the NDK sysroot's usr/
```

Upstream extracts it **into** the NDK sysroot. We keep it beside the build and pass
`OPENMW_DEPENDENCIES_DIR`, which `CMakeLists.txt:73` adds to `CMAKE_FIND_ROOT_PATH` — the same
effect, but non-destructive and re-extractable.

The archive (aarch64, API 24, NDK r26b) carries: **OSG 3.6.5** with every component and plugin,
**Boost 1.85** with full CMake config packages, **Bullet**, **SDL2 2.24**, **MyGUI 3.4.3**,
**ffmpeg 6.1**, **OpenAL**, **FreeType**, **libpng16**, **libjpeg**, **zlib**, **bzip2**,
**ICU 70.1**, **collada-dom**, **LuaJIT**, **liblz4.a**, and **gl4es**.

The other half is `extern/CMakeLists.txt`, which `FetchContent`s whatever the archive lacks:
yaml-cpp, sqlite3, recastnavigation, googletest.

## The six things that actually stopped it

Each was a message from a tool, not a guess. They are listed in the order they appeared.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | `Could NOT find OpenGL` | Android has no desktop GL; `find_package(OpenGL REQUIRED)` at CMakeLists.txt:278 | point `OPENGL_*` at gl4es |
| 2 | `Could NOT find LZ4` | no LZ4 CMake config; openmw's own `cmake/FindLZ4.cmake` does the work | satisfied by the archive's `liblz4.a` once the tree is on the search path |
| 3 | `FFmpeg version is too old, 4.0 is required` | `cmake/FindFFmpeg.cmake` never populates `FFmpeg_<LIB>_VERSION`, so the guard compares against **empty** and can never pass | **read the versions out of the archive's headers** and pass them |
| 4 | `Could not find a package configuration file provided by "QT"` | `USE_QT` is derived from `BUILD_LAUNCHER`/`BUILD_OPENCS`/`BUILD_WIZARD`/`BUILD_OPENCS_TESTS`, all of which default ON | turn the desktop tools off |
| 5 | `undefined template 'std::char_traits<unsigned int>'` | MyGUI 3.4.3's headers are built on `std::basic_string<unsigned int>`, and modern libc++ **removed** those `char_traits` specialisations | `tools/android/compat/glibcxx_char_traits_unicode.h`, force-included |
| 6 | 21 × `undefined symbol: glTexImage1D` (and friends) | those are desktop GL, absent from GLES | the archive's `lib/libGL.so` **is gl4es** — link that |
| 7 | 13 × `undefined symbol: FT_Init_FreeType` | the archive ships **static** OSG, but `OSG_STATIC` defaults OFF, and OSG_STATIC is what makes `components/CMakeLists.txt:708-711` link FreeType/JPEG/PNG | `OSG_STATIC=ON` (also what makes OSG plugins `--whole-archive`, which their registration needs) |
| 8 | `unable to find library -lcollada-dom2.5-dp` | a bare `-l` name needs the directory on the **link** line, which `CMAKE_LIBRARY_PATH` does not do | `-L` via the linker flags |

Plus one version shortfall worth naming: the archive's **SDL2 is 2.24.0** and this source asks for
**2.26** (`CMakeLists.txt:496`). It is the only dependency that needed building by hand, which is
what `tools/android/build-sdl2.sh` is for (SDL2 2.30.12, static).

## Windows notes that cost time

- **tar cannot create symlinks here without privilege**, so the archive's `libpng.a -> libpng16.a`
  style links come out *missing*. Recreate them as copies before configuring, or `find_package(PNG)`
  fails with a confusing "missing PNG_LIBRARY".
- **clang is a Windows binary.** A path that reaches a *command line* — `-include`, `-L` — must be
  in `C:/...` form. POSIX `/c/...` works for `-D` variables (CMake resolves those itself) but not
  for flags, and the failure looks like a broken compiler rather than a bad path.
- **`MYGUI_HOME`** is how `FindMyGUI` is pointed at the tree, since MyGUI ships no CMake package.
  With `MYGUI_STATIC=ON` it finds `libMyGUIEngineStatic.a` and — importantly — never compiles
  MyGUI, which is what sidesteps the libc++ problem in the first place.

## What is left for an APK

`libopenmw.so` is a *shared library*, not an executable: OpenMW's Android build is loaded by an
SDL2-based activity, the same shape as upstream's `openmw-android`. Still to do:

1. **Shrink it.** 104 MB stripped, because OSG, Boost, Bullet and ffmpeg are all linked in
   statically. `--gc-sections` and a size-oriented build type are the obvious first lever.
2. **Bundle its shared dependencies** into `lib/arm64-v8a/`: `libopenal.so`,
   `libcollada-dom2.5-dp.so`, `libbz2.so`, `libz.so`, `libGL.so` (gl4es), and our `libSDL2.a` is
   static so it does not ship. The `NEEDED` list above is exactly this shopping list.
3. **The activity**: SDL2's `android-project` scaffolding (SDLActivity + the Java side) wired to
   `libopenmw.so` with `SDL_MAIN_READY`/`main`, plus the game data staged the way
   `tools/android/provision-emulator.sh` already does it.
4. **Re-measure the floor**: the mod needs **>= 0.49** for `.omwscripts`, and this is 0.52, so that
   is satisfied by construction.

---

# AND IT PACKAGES: a signed APK

```
build/android-out/idle-openmw.apk     115 MB
  is.xyz.idle_openmw, versionCode 1, minSdk 24, targetSdk 34
  verified: APK Signature Scheme v2 + v3
  classes.dex + lib/arm64-v8a/{libopenmw,libopenal,libcollada-dom2.5-dp,libbz2,libz,libGL}.so
```

```bash
bash tools/android/build-apk.sh
```

## No Gradle, deliberately

The app is one activity. Every tool needed is already in the SDK:

```
javac (JDK) -> d8 -> aapt2 -> zip -> zipalign -> apksigner
```

Gradle would add a download, a wrapper, a plugin resolution and a daemon to that list. The APK
format is just a zip with agreed entry names, and `tools/android/add-to-apk.py` writes the two
entries aapt2 does not know about (`classes.dex` and `jniLibs`), with the `.so` files **stored**
rather than deflated so they can be mmapped after install.

## The activity is three overrides

OpenMW's Android build is a *shared library*, and its entry point is
`extern "C" int SDL_main(int, char**)` (`apps/openmw/main.cpp:238`). SDL2's `SDLActivity` is the
supported thing that loads such a library and calls a symbol in it, so
`tools/android/apk/src/is/xyz/idle_openmw/MainActivity.java` just names ours:

```java
protected String[] getLibraries()     { return new String[] { "openmw" }; }
protected String getMainSharedObject(){ ... nativeLibraryDir + "/libopenmw.so"; }
protected String getMainFunction()    { return "SDL_main"; }
```

**SDL2 is linked into `libopenmw.so` statically**, which is why `getLibraries()` names only
`openmw` — there is no `libSDL2.so` to load. The JNI bridge it needs is exported from our library,
which is checkable rather than assumed:

```
$ llvm-nm -D --defined-only libopenmw.so | grep SDLActivity
T JNI_OnLoad
T Java_org_libsdl_app_SDLActivity_nativeAddTouch
T Java_org_libsdl_app_SDLActivity_nativeFocusChanged
...
```

If that ever stops being true the failure is an `UnsatisfiedLinkError` at launch, so those symbols
are the thing to check, not the manifest.

## Three more Windows-tool traps, all of which cost time

1. **A path in a command ARGUMENT must be `C:/...`.** Git Bash hands the tools `/c/...`, which a
   Windows binary reads as the *relative* path `c/...`, and the error is a plain "file not found"
   for a file that obviously exists. The script routes every argument through `cygpath -m`. (Paths
   inside `-D` variables are fine, because CMake resolves those itself.)
2. **`--` is illegal inside an XML comment**, so a manifest comment containing a dash-dash
   (`statically -- see ...`) fails `aapt2` with "not well-formed (invalid token)" pointing at the
   comment's line. It is a real XML rule and the message does not say so.
3. **Do not pass resources the manifest never references.** Compiling a `strings.xml` and handing
   it to `aapt2 link -R` makes aapt2 treat it as an *overlay* and refuse: "failed to merge resource
   table ... use --auto-add-overlay". With literal labels in the manifest there is nothing to
   merge, so the step is simply absent.
4. **`keytool` is not on PATH** even where `java`/`javac` are (on this machine they are shimmed
   through Oracle's `javapath` and keytool is not shimmed at all). `build-apk.sh` looks in
   `$JAVA_HOME/bin` when `command -v keytool` comes up empty.

## Which ABI, and where it can be tested

The APK is **arm64-v8a**, because that is what the published dependency archive is
(aarch64, API 24, NDK r26b — it has no x86_64 tree at all).

**No emulator on this machine can run it, and that is now measured rather than assumed.** The path
was followed to the end: the arm64 system image installs (2.7 GB), an arm64 AVD is created
successfully (`tools/android/install-arm64-image.bat`, `tools/android/create-arm64-avd.bat`), and
then the emulator refuses outright:

```
$ emulator -avd idle_openmw_arm64 -no-window -gpu swiftshader_indirect
FATAL | Avd's CPU Architecture 'arm64' is not supported by the QEMU2 emulator on x86_64 host.
        System image must match the host architecture.
```

So there is no "slow but functional" arm64 emulator to fall back on — QEMU2 will not attempt it. The
two real options are:

- **A real arm64 phone**, which can install this APK directly (`adb install`). This is the cheap
  test, and it is the one worth doing first, because "does it launch and find the game data" is
  what everything else about the app is downstream of.
- **An x86_64 APK**, which is what would make the local emulator usable. It needs an x86_64
  dependency tree, which the archive does not provide, so Boost, OSG, ffmpeg, MyGUI, OpenAL,
  FreeType, ICU and the rest would have to be built for x86_64.
  `tools/android/configure-android.sh --abi x86_64` is already parameterised for that day.

## Still open

- **Size.** 115 MB, and the first pass is already in: stripping the bundled shared libraries took
  it down from 189 MB for nothing but discarded symbols (`build-apk.sh` does it, into a staging
  directory). What remains is `libopenmw.so` at 108 MB, because OSG, Boost, Bullet and ffmpeg are
  all linked in statically. The levers, in order of expected payoff:
  - **`--gc-sections`: measured, and it does NOTHING here.** The NDK already passes
    `-ffunction-sections -fdata-sections`, so the linker flag was the only missing half and adding
    it changed `libopenmw.so` by **exactly 0 bytes** on the stripped library
    (108,530,768 before and after). The reason is the one below: the OSG plugins are linked with
    `--whole-archive` for their registration, which pins everything reachable from them. Recorded
    so nobody spends the afternoon re-measuring it.
  - **A size-oriented build type.** `-DCMAKE_BUILD_TYPE=MinSizeRel` trades speed for bytes.
  - **Dropping OSG plugins the game does not use.** `USED_OSG_PLUGINS` (CMakeLists.txt:301) is ten
    plugins, and their registration is `--whole-archive`, so every one of them is force-linked in.
  - **Dropping collada-dom entirely** — 9 MB, plus engine-side DAE code — which is a
    **mod-compatibility tradeoff**, not a free win: `.dae` models are custom content, while
    Morrowind's own models are NIF. Recorded as an option rather than taken, because it is the
    user's call.
- **The game data.** The engine reads the Morrowind install by absolute path;
  `tools/android/provision-emulator.sh` already stages `/storage/emulated/0/Morrowind` the way the
  old APK expected. On device this is the same shape, and the mod ships in
  `/storage/emulated/0/Morrowind/Mods/idle_openmw`.
- **`SDL_main` is only half a game.** Launching successfully means the engine starts; it does not
  yet mean the idle director takes over, which needs the `.omwscripts` load path and chargen the
  mod already documents (`docs/chargen.md`).

---

# The native UI, and the loop that measures it

Everything above is about getting an engine onto a phone. This is the app *around* it, which is now
a native Android View tree rather than the Lua console it started as (the console is still in the
repo, unremoved — see the end of this section).

## Two activities, and why there are two

```
LauncherActivity   decides: is libopenmw.so packaged?
  |-- yes -> MainActivity    (an SDLActivity: loads the engine, then reparents SDL's own
  |                           RelativeLayout into a top-third viewport)
  `-- no  -> AppActivity     (the same shell, no engine: the emulator case)
```

The decision cannot live inside `MainActivity.onCreate`. A Java subclass cannot skip its superclass
to reach `Activity.onCreate`, and the framework checks a flag set there — so "start the other
activity and return" throws `SuperNotCalledException` (AGENTS.md #9). `SDLActivity` has the same
shape of problem from the other side: there is no path through its `onCreate` that skips the native
library load, so an engine-less build cannot reuse it.

`MainActivity` moves SDL's `mLayout` (not just `mSurface`) into the viewport, because SDL adds its
soft-keyboard `mTextEdit` to `mLayout` later; moving the container keeps that working. Both fields
are `protected static` on `SDLActivity`, so **no SDL2 fork is needed** for this.

## The bridge

Lua can read a file but cannot write one, and cannot open a socket (`docs/bridge-api.md`), so a
native UI cannot be *told* anything by a pure Lua mod. Java and the engine are one process, so the
shortest honest path is a direct call:

```
engine -> app   openmw.android.pushState(json)  ->  JNI  ->  MainActivity.onEngineState(byte[])
app -> engine   MainActivity.sendCommand(json)  ->  JNI  ->  queued  ->  openmw.android.pollCommand()
```

- The engine half is fork patch **`0002-android-bridge.patch`** (`apps/openmw/mwlua/androidbindings.cpp`).
  It is registered in `initCommonPackages`, so every script kind has it, and it exists on every
  platform while reporting `available() == false` off Android — a mod can call it unconditionally.
- **`tools/dev/engine-build/apply-patches.sh`** applies the fork's patches, and BOTH builds call it.
  Until this existed the Android engine got **no** fork patches at all, and a missing binding is not
  a compile error — it is a runtime error on a phone, which is the most expensive place to find one.
- Payloads cross as **byte arrays**, not jstrings: `NewStringUTF` wants modified UTF-8, which differs
  exactly where it hurts (supplementary characters, embedded NULs), and Morrowind's data is full of
  non-ASCII names.
- The app decodes with `org.json`, which ships with the platform, so no dependency and no resources.

## The UI-only APK, and what it is for

```bash
bash tools/android/build-apk.sh --ui-only     # 60 KB, no lib/ entries at all
bash tools/android/tests/ui-loop.sh           # build, install, launch, screenshot, measure
python tools/android/tests/read_screen.py build/device/loop-*.png
```

The APK is arm64-v8a and QEMU2 refuses to emulate arm64 on an x86_64 host (measured above), so the
engine can never run here. The **UI** can: `--ui-only` packages the same Java with no native
libraries, `LauncherActivity` routes to `AppActivity`, and the result is the real view tree with
either a fixture or a placeholder in the viewport. `Bridge.FIXTURE` feeds the *same code path* the
engine uses, so an emulator screenshot shows the real renderer holding fake numbers — with the footer
naming which of the two it is, because a fixture that looks like live data is a trap.

**The loop proves**: layout, insets, tap targets, colour, and that a tap reaches the command sink.
Measured this way: status bar to 5.8%, gold-framed viewport 7.0–35.2%, three bars at y=901 reading
0.84 / 0.61 / 0.72 (the fixture's own numbers), and a tap on the first button producing
`{"command":"wait"}` in logcat.

**It cannot prove**: that the engine renders into the short wide viewport, that the bridge carries
live state with both halves in one process, or anything about framerate and heat. Those need the
phone, and `ui-loop.sh --apk build/android-out/idle-openmw.apk --activity is.xyz.idle_openmw/.MainActivity`
is the same loop pointed at it.

## Still open here

- **Nothing has run with both halves in one process.** The engine build carries the exported JNI
  symbols and the app declares exactly those names, but the first real proof is the phone.
- **The short wide viewport is untuned.** A top-third render window is roughly 1080x780; camera
  aspect/FOV (`scripts/idle/camera.lua`, `docs/isometric.md`) and MyGUI's scaling factor were not
  touched, because neither can be judged without the engine drawing into one.
- **`scripts/portraitUI.lua` still ships.** The Lua console is the desktop surface and its removal is
  769 lines plus a 410-line spec, which belongs in its own step rather than a rushed one.
