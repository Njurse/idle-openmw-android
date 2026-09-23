# Building OpenMW from source (the fork)

We build our own engine. This is the why, the how, and the two things that were wrong the first
time.

## Why fork the engine

Three reasons, in the order they started to matter:

1. **Lua cannot see three of the five reasons a world is stopped.**
   `apps/openmw/mwworld/datetimemanager.cpp:259` pauses on tags, the console, the
   post-processor HUD, an interactive message box, or *no game loaded* — and only the first two
   are readable from Lua (`world.getPausedTags`, `ui.getConsoleMode`). A build we own can expose
   the rest, which is the difference between the mod reporting `paused: true` and reporting
   *why*.
2. **Character creation cannot be driven from Lua at all.** The chargen windows are native MyGUI
   widgets, and `ui.getElements` only ever returns Lua-created elements. A fork can give the mod
   a real handle on it (or an honest scripted path through it).
3. **Android.** The published APK recommends itself out of relevance: it predates `.omwscripts`
   and cannot load this mod at all (docs/android.md). A modern engine for the phone means a
   build, and the only supported way to get one is from source.

## What the build needs (all verified present on this machine)

| Piece | Where |
| --- | --- |
| MSVC | `C:/Program Files/Microsoft Visual Studio/18/Community` (MSVC 14.50.35717) |
| Windows SDK `rc.exe` | `Windows Kits/10/bin/10.0.26100.0/x64/rc.exe` |
| CMake + Ninja | the retcomm toolchain: `~/.local/share/retcomm/toolchains/cmake-clang-v1/latest/bin` |
| 7-Zip | `C:/Program Files/7-Zip/7z.exe` |
| Prebuilt deps | `vcpkg-x64-windows-2022-2026-09-09.7z` (~89 MB, 625 MB extracted) from openmw-deps |

The deps recipe is the project's own CI (`.github/workflows/windows.yml`), adapted:

```
$MANIFEST = vcpkg-x64-windows-${MSVC}-${VCPKG_TAG}-manifest.txt   # MSVC=2022, VCPKG_TAG=2026-09-09
```

Note the token is **`2022`, not `vs2022`** — the latter 404s. The manifest names the archive URL
and its SHA512; `build.sh` verifies the hash before extracting, because a truncated download and
a complete one look identical otherwise.

**We skip the launcher, the wizard, OpenCS, the importers and the tests.** That is not just
faster: it means **no Qt download at all**, because Qt is only needed for the launcher. We launch
`openmw.exe` directly with our own config (`tools/dev/desktop/setup-cfg.sh`).

## How to run it

```bash
bash tools/dev/engine-build/build.sh --deps        # download + verify + extract (once)
bash tools/dev/engine-build/build.sh               # configure + build
bash tools/dev/engine-build/build.sh --release     # Release instead of RelWithDebInfo
```

Defaults: source `$REPO/.research/openmw`, build `/f/OpenMW-build/build`, deps
`/f/OpenMW-build/deps`. Override with `OMW_SRC`, `OMW_BUILD_DIR`, `OMW_DEPS_DIR`.

To run the engine we just built:

```bash
OMW_EXE=/f/OpenMW-build/build/openmw.exe bash tools/dev/desktop/into-world.sh \
    --cell "Imperial Prison Ship"
```

## The version we build

The checkout is **`0.52.0`** (master, `OPENMW_VERSION_MINOR 52`), while the installed binary we
have been testing against is 0.51.0 and the Lua API revision moves with it (the build log prints
`OPENMW_LUA_API_REVISION=160`; the 0.51 install reports 129).

That matters: every engine finding in `docs/openmw-lua-api.md` was measured on 0.51.0. Anything
load-bearing gets re-checked against the fork's revision rather than assumed to carry over --
starting with the things this last session depends on: `interfaces.UI`'s members, the chargen
flow, `ui.getConsoleMode`, and the pause expression above.

## Fork patches

The fork's changes are **patch files in this repo**, not edits in the checkout:

```
tools/dev/engine-build/patches/*.patch     applied with `patch -p1` (idempotent)
```

`build.sh` applies them before configuring and refuses to continue if one does not apply
cleanly, so the engine we build is reproducible from this repo instead of being whatever the
working tree happens to contain.

### 0001 — the Windows resource is compiled by `rc.exe` directly

CMake 3.31 with MSVC 14.50 generates a malformed Ninja rule for `.rc` files. It emits:

```
RC $in $DEP_FILE $out "Note: including file: " "<...>/cl.exe" ...rc.exe ... /fo $out $in
```

— a bare `RC` token, the depfile, the `/showIncludes` prefix string and a `cl.exe` path, all
before `rc.exe`. `rc.exe` responds, correctly, with `fatal error RC1107: invalid usage`, and the
build stops at step 32 of 879.

The patch takes the resource out of CMake's RC language and compiles it with `add_custom_command`
instead: three lines, no dependence on that generator behaviour, and one obvious place to control
the icon, the manifest and the version information that ends up inside the binary — which is
where the project's own name and version will want to live.

## Two more things that were wrong first (worth not rediscovering)

* **Ninja's directory on `PATH` decided the compiler.** With the retcomm toolchain's `bin` in
  front, CMake found `cc.exe`/`c++.exe` (its clang) and started configuring a **clang** build that
  would have linked against **MSVC-built** libraries. Fix: name the compiler
  (`-D CMAKE_C_COMPILER=cl -D CMAKE_CXX_COMPILER=cl`), pass Ninja by path
  (`CMAKE_MAKE_PROGRAM`), and put its directory at the *end* of `PATH`.
* **Two system dependencies are simply not in the deps archive.** `find_package(yaml-cpp
  REQUIRED)` and `find_package(SQLite3 ...)` fail against this deps tree because it does not ship
  them — but OpenMW has internal copies and options for exactly this, so the build sets
  `OPENMW_USE_SYSTEM_YAML_CPP=OFF` and `OPENMW_USE_SYSTEM_SQLITE3=OFF`. `TinyXML`,
  `RecastNavigation` and `OSGPlugins` are the same story in a quieter way: their defaults already
  use the internal copies, or they are found through CMake modules rather than a `share/`
  config, so a "missing from `share/`" check is not the same as missing.
