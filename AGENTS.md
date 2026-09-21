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
