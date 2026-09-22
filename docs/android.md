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

## Correcting Finding C (twice)

Two follow-up experiments narrowed it, and both contradict the confident version
above, so here is the accurate state.

**The space in "Data Files" is not the cause.** Reproduced with a space-free path:

```
Cannot load file: /storage/emulated/0/omwmod/idle_openmw.omwscripts
```

**And this build does have script support.** `buildscripts/CMakeLists.txt` has

```cmake
ExternalProject_Add(luajit  URL https://luajit.org/download/LuaJIT-${LUAJIT_VERSION}.tar.gz ...)
...
set(OPENMW_DEPS_ANDROID ... DEPENDS boost openal osg mygui ffmpeg sdl2 bullet lz4 luajit)
```

So LuaJIT is compiled in and OpenMW depends on it. `.omwscripts` *should* load.
It does not, and the engine reports it at the **file** level ("Cannot load file"),
not as a parse error — which points at content/VFS resolution for a mod-provided
manifest in this 0.48 build, rather than at missing script support.

Remaining hypotheses, in the order worth testing:

1. **0.48 predates `.omwscripts` outside the engine's own VFS.** The port ships
   `resources/vfs/builtin.omwscripts` as a *resource*, not as a mod. Worth testing
   by dropping the manifest into that VFS directory and referencing it as content.
2. **The port's OpenMW commit** (`e92fb245…`, per the 0.48.0-46 release notes) may
   predate the loader path that mods use.
3. Patching the port is the guaranteed fix, and needs the build below.

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
