# AGENTS.md — working on idle-openmw

Guidance for AI agents (and humans) picking this repo up cold.

## What this is

A **Lua mod for OpenMW** (`mods/idle_openmw/`) that auto-plays single-player
Morrowind as an idle game, plus a **headless test suite** (`tests/`) that runs
without the engine.

## Commands

```bash
pip install lupa                   # embedded LuaJIT runtime (prebuilt wheel)
python tools/run_tests.py          # run the spec suite (LuaJIT 2.1)
python tools/run_tests.py --all    # LuaJIT 2.1 + Lua 5.1 + Lua 5.4
python tools/run_tests.py --sim    # 1000-game-hour invariant simulation
python tools/run_tests.py --list   # list spec modules
```

There is no build step: the mod is interpreted Lua. `tools/run_tests.py` is the
only entry point you need.

The Android app has one loop, and it is the one to use for any UI work:

```bash
bash tools/android/tests/ui-loop.sh        # build --ui-only, install, launch, screenshot, measure
bash tools/android/tests/ui-loop.sh --no-build --no-boot   # just shoot the running build
python tools/android/tests/read_screen.py <png>            # read a screenshot back as numbers
```

It runs the UI with NO engine on the x86_64 emulator, which is the only device here that can run
any of this: the APK is arm64-v8a and QEMU2 refuses arm64 on an x86_64 host. `docs/android.md` has
the two-activity design, the JNI bridge, and what each loop can and cannot prove.

## Architecture (read this before editing)

Two hard layers:

| Layer | Path | Rule |
|---|---|---|
| **Core (brain)** | `mods/idle_openmw/scripts/idle/` | **PURE.** Must never `require('openmw.*')`, touch `os`, `io`, or a clock. Plain tables in, plain tables out. |
| **Runtime (adapter)** | `mods/idle_openmw/scripts/runtime/` | The only place that names `openmw.*`. Takes an injected `env`. |

`runtime/engine.lua` is the *single* file that requires engine modules. If you
need a new engine binding, add it there.

The contract in the middle:

- `observer.build(env, opts)` → **snapshot** `{ player, world, time }`
  (shape documented at the top of `scripts/idle/director.lua`)
- `director:tick(dt, snapshot)` → **`{ goal, commands, status }`**
- `executor:submit(commands)` / `executor:update(dt, now)` → engine calls

Because `env` is injected, **new engine behaviour is testable**: extend
`tests/mocks/openmw.lua` and write a spec in `tests/spec/runtime_spec.lua`.

## Conventions

- **Target LuaJIT / Lua 5.1.** No `goto`, no `//`, no `table.unpack`, no
  integer division. The suite runs `--all` to keep you honest.
- **Comment the *why*, cite the *where*.** Engine facts belong in
  `docs/openmw-lua-api.md` with a `file:line` citation; code comments reference it.
- **Determinism.** No `math.random`. Use `scripts/idle/rng.lua` with a seed.
  Snapshots must be built in a stable order (sort before you store).
- **Failure isolation.** Anything touching the engine is pcall-guarded and
  defaulted (`runtime/observer.lua`, `scripts/pm... port`). A mod that throws
  mid-frame is worse than one that reports a neutral value.
- **Do not add a dependency** to the test harness. It is intentionally
  dependency-free so it can also run on-device later.
- **Edit files with the file tools, not bash heredocs** — heredocs in this
  workspace mangle backslash escapes, and a check written the same way cannot
  detect the damage it caused.
- **Keep non-ASCII out of Lua source; build it with `string.char`.** The same
  mangling turns an ellipsis or an accented letter into a *different* character,
  silently. It bit twice in one session: a clamp that then overran its own byte
  limit, and a spec whose expected value was mangled the same way as the code it
  was testing (so it could not detect the damage). Morrowind data is full of
  non-ASCII *values* — that is fine; it is typing them into source that is not.
  `python tools/dev/check_ascii.py` reports code-position offenders.

## Gotchas that have already bitten

1. **The player cannot be given AI packages.** `AI.startPackage` on the player
   throws (docs/openmw-lua-api.md §1). Movement is `self.controls` steering.
2. **`nearby.findPath` returns two values**, `(status, points)` — not a table.
3. **`.omwscripts` comments are `#`**, and there is no `LOCAL:` flag.
4. **Lua closure scope**: `local t = { f = function() t.x = 1 end }` does *not*
   capture `t` (its scope starts after the statement) — it silently hits a nil
   global. Declare the variable first.
5. **`assert` is a function**, so `assert.equals` needs the harness's callable
   table trick (`tests/harness.lua:install`).
7. **Engine values are `userdata`, not `table`.** `require('openmw.types')`, a record,
   a GameObject, a Cell, an item, a stat — all `userdata` on 0.51. Measured, from the
   mod's own log line sent to the engine console:
   `[env: core=userdata,types=userdata,ui=userdata,nearby=userdata,camera=userdata,...]`.
   So `type(x) == 'table'` is **false for every engine value** — it does not raise, it
   yields nil, and the world model goes quietly blind. Use `util.isObject(x)` (accepts
   both) or plain truthiness. `tests/spec/userdata_spec.lua` drives the real code with
   real userdata via `newproxy` to keep this honest.

   **Two places this cost the most, so do not repeat them:**

   - **A distance.** `self.position` is a userdata Vector3, and `scripts/idle/util.lua`'s
     `point()` accepted only tables — so *every* distance in the mod was `nil`. Where that
     lands is the dangerous part: `Route:update`'s arrival test is
     `if toTarget and toTarget <= tolerance`, so a nil distance falls *through* the arrival
     branch into "the path is spent", which returns `arrived`. The route claimed success
     4000 units from its target and the character never moved a step. Guard **in the core
     util**, where one fix covers every caller, not at each call site.
   - **A yaw.** `self.rotation` on 0.52 is a Transform **userdata**, not the number the older
     docs describe. Feeding it to the steering maths produced a yaw that never converged:
     `shouldMove` stayed false and the character turned on the spot for forty seconds while
     every log said `moving = true`. `Executor.yawOf` probes several sources and records
     which one it used (`ui.yawSource`) so a fallback is never mistaken for a reading.

   The same trap reaches the WIRE: `types.Actor.stats.ai` is a wrapper, so a raw read
   serialised as the literal string `"<userdata>"` — and it validated, because the schema's
   `map`/`list` checks only asked whether the value was a table. They now reject any engine
   value nested inside a field (`scripts/idle/schema.lua`), so a host cannot receive
   confident nonsense again.
8. **An engine handler the engine does not know is silent, not fatal.** It logs
   "Not supported handler 'x'" and never fires — so the feature just stops working.
   The authoritative names are in
   `.research/openmw/docs/source/reference/lua-scripting/engine_handlers.rst`;
   `python tools/dev/check_handlers.py` checks ours against them.
9. **An Android `Activity` must call through to `super.onCreate`.** Routing inside
   `MainActivity.onCreate` ("if the engine is missing, start the other activity and return")
   throws `SuperNotCalledException`: the framework sets a flag in `Activity.onCreate` and checks it
   after the call returns, and a Java subclass cannot skip its superclass to reach the grandparent.
   The fix is a separate, trivial `LauncherActivity` that decides and finishes. `SDLActivity` has the
   same shape of problem from the other side — no path skips the native library load — which is why
   the engine-less case is a second activity rather than a branch.
10. **`--` inside an XML comment is not well-formed.** A manifest comment containing `--` fails
    `aapt2 link` with "not well-formed (invalid token)" pointing at the comment, not the attribute.
11. **Do not export `MSYS_NO_PATHCONV=1` for a whole script here.** It is right for a script that
    pushes device paths to `adb` (`tools/android/run-on-emulator.sh`), and wrong for one that shells
    out to a Windows tool with a POSIX path: `python tools/android/add-to-apk.py` becomes `/c/...`,
    which python.exe reads as `C:\c\...` and reports as a missing file. Scope it to the single
    command that needs it.
12. **The debug keystore must live outside the build's work directory.** `$WORK` is wiped at the top
    of every build, so a keystore inside it is regenerated, and a differently-signed APK makes
    `adb install -r` fail with `INSTALL_FAILED_UPDATE_INCOMPATIBLE` — the command the emulator loop
    depends on. It is at `build/android-keystore/debug.keystore`.
6. **A repath must not reset the stuck timer** — otherwise a stuck actor looks
   healthy forever (`scripts/idle/pathfinder.lua`).

## Testing philosophy

Specs drive the design, and they caught real bugs during development
(a goal with no capability source; `idle` out-scoring real goals; a repath
masking a stuck actor). Keep them behavioural: assert *relationships*
("a thief values economy more than a warrior"), not magic numbers, unless the
number is the contract.

If you add a module, add a spec. `tools/run_tests.py` globs `tests/spec/*_spec.lua`
and warns when `tests/specs.lua` drifts.

## When the API question comes up

Do not guess at OpenMW behaviour. Check `.research/openmw/` (a shallow clone) or
`docs/openmw-lua-api.md` first. The verified reference has already corrected six
load-bearing assumptions from the original plan; assume more lurk.
