# Plan reconciliation

The project started from a detailed 429-line plan. This document maps that plan
onto what actually exists, phase by phase, and records every place the plan's
assumptions collided with OpenMW's real API.

Status key: ✅ done and verified · 🟡 partial · ⛔ blocked on environment · ❌ invalid (the API cannot do this)

---

## Phase table

| Phase | Plan's task | Deliverable | Status |
|---|---|---|---|
| 1 | Fork `xyzz/openmw-android`, baseline build | Working APK | ⛔ needs NDK + Linux; no Android toolchain on the dev host |
| 2 | Port the OpenNevermind camera / isometric lock | Isometric camera | ⛔ needs OpenMW C++ work |
| 3 | Portrait manifest + OSG viewport | Portrait game activity | ⛔ needs a desktop build + a device to test the crash risk |
| 4 | Pure Lua idle director (stat crunch, weights, goals) | Lua scripts + unit tests | ✅ 14 core modules, unit-tested |
| 5 | Mock engine APIs, integration tests | Mock test suite | ✅ `tests/mocks/openmw.lua` + `runtime_spec.lua` |
| 6 | Deploy to PC OpenMW, test in a real save | In-game observation | ⛔ no OpenMW install on the host |
| 7 | Bundle into the APK, deploy to S23+ | Full APK | ⛔ follows phase 1 |
| 8 | Portrait UI, offline progress, thermal tuning | Polished build | 🟡 portrait UI ✅, offline progress ✅, thermal ⛔ |

Plus, beyond the plan:

| Extra | Why |
|---|---|
| ✅ `docs/openmw-lua-api.md` | Citation-backed API reference — the plan's errors needed a permanent fix |
| ✅ `tests/sim/headless_sim.lua` | The plan's "headless simulation harness" (1000 game-hours) |
| ✅ Play modes: manual / orders / auto | The plan's Full Auto / Directive Auto / Manual, and MANUAL hands the game's own controls back so it stays playable |
| ✅ Phone-first `uiLayout.lua` + `uiModel.lua` | The plan asked for a portrait command panel; this makes the geometry *and* the interaction model testable |
| ✅ The full console overhaul | The plan described a status panel; what shipped is a six-tab console (Info/Order/Pack/Talk/Log/Open) with tap-to-equip, an inventory browser and launchers for every real Morrowind window |
| ✅ `directive.lua` ("Directive Auto") | The plan's Full Auto / Directive Auto / Manual modes |

---

## The six corrections

Each is verified in `docs/openmw-lua-api.md` with a `file:line` citation.

### C1 — The player cannot be given AI packages

> **Plan:** `AI.startPackage({ type = 'Travel', destination = targetPosition })`

**Reality:** the engine throws `Can't add AI packages to player`; the field is
`destPosition`, not `destination`; and only six package types exist.

**Redesign:** the player is steered with `self.controls` along a path from
`nearby.findPath`, with the built-in input script overridden. See
`scripts/idle/pathfinder.lua` and `runtime/executor.lua`.

### C2 — `findPath` returns two values

> **Plan:** `if path.status == nearby.FIND_PATH_STATUS.Success then ...`

**Reality:** `local status, path = nearby.findPath(src, dst, opts)` — status is a
separate return value; there is no `.status` field. Options are
`includeFlags` + `areaCosts`, not `includeDoors` / `includeSwim`.

**Redesign:** `runtime/engine.lua`'s `makeNavPort` (in `idleDirector.lua`) wraps
the two-value return behind a one-line port, and `pathfinder.Route` consumes it.

### C3 — There is no `onInfoGetText`, and dialogue is observe-only

> **Plan:** "Use the `onInfoGetText` event to intercept and potentially
> auto-select dialogue options."

**Reality:** no such handler exists anywhere in the engine; `DialogueResponse` is
notification-only and cannot influence anything.

**Redesign:** `scripts/idle/dialogue.lua` became a *memory* (who greeted us,
what topics we have seen, who refuses us) rather than a controller. The plan's
"dialogue automation" risk (its §10 table) is not a risk — it is a closed door.

### C4 — `.omwscripts` syntax

> **Plan:** a manifest with `--` comments.

**Reality:** comments are `#`; `--` is a parse error. There is also no `LOCAL:`
flag — local scripts are declared with object-type tags.

**Redesign:** `mods/idle_openmw/idle_openmw.omwscripts` uses `#` comments and two
`PLAYER:` entries.

### C5 — `self.controls` is a struct, and `self.storage` does not exist

> **Plan:** "Use `openmw.input` to create touch-friendly command buttons" and
> `self.storage` for persistence.

**Reality:** `self.controls` exposes *fields* (`movement`, `yawChange`, `run`, …)
not methods; persistence is `require('openmw.storage')` with
`playerSection`/`globalSection`.

**Redesign:** the executor writes control fields; `runtime/engine.lua` exposes
`playerStorage()`.

### C6 — The UI mode enum is not `core.UI_MODE`

> **Plan:** implied `core.UI_MODE`.

**Reality:** it is `interfaces.UI.MODE`; there is no `core.UI_MODE`.

---

## Things the plan got right (kept)

- **Layer the brain as pure Lua.** "Keep the idle director pure Lua so it can be
  tested without the engine" — this is the spine of the whole project.
- **Module names.** `idleDirector.lua`, `portraitUI.lua`, `statCrunch.lua`,
  `classPriorities.lua`, `goalScoring.lua`, `pathfinder.lua`, `dialogue.lua`,
  `offlineProgress.lua` are all as proposed.
- **Class weight vectors** for Warrior / Mage / Thief / Healer, and the
  behavioural differences between them — implemented, and *derived* from real
  class skill data rather than hard-coded (so any modded class works).
- **The scoring formula** `weights × need × opportunity × (1 + levelScaling) − risk`
  — implemented essentially verbatim, with `aptitude` added so *capability*
  modulates *preference*.
- **Offline progress, capped** — "cap at 8 real hours to prevent exploitation".
- **The test layout** (`spec/`, `mocks/`, `fixtures/`, `run`) and the mock shapes.
- **Portrait command panel** with quick commands + auto-play toggle + activity log.
- **S23+ tuning intent**: low render rate, shadows off, thermal monitoring —
  still correct, still unimplemented (device-side).

---

## Design changes the plan did not anticipate

1. **Class weights are derived, not tabulated.** `classPriorities.buildWeights`
   reads specialization + major/minor skills and normalizes to mean 1.0. The
   four archetypes are presets; a modded class still behaves sensibly.
2. **`idle` is a fallback, not a competitor.** Without this, "do nothing"
   out-scored real goals whose aptitude was small (a non-merchant's economy).
3. **Directive Auto is a first-class queue** with a TTL, and always yields to
   danger — the plan described the mode but not the mechanism.
4. **Barter/rest/training are simulated directly**, gated by a config flag,
   because the plan's UI-driving approach is impossible (C3-adjacent).
5. **`simulateActions = false` mode** — purely advisory navigation, for players
   who do not want the mod editing their inventory.
6. **The HUD geometry is a pure, tested module.** You cannot iterate on touch
   layout you cannot see; moving the arithmetic somewhere testable was the only
   way to make progress on it without a device.

---

## Deviations in repo layout

- The plan put `tests/` *inside* the mod (`idle_openmw/tests/`). Tests are not
  shipped to the game, so they live at the repo root and the mod is a clean
  subtree under `mods/idle_openmw/`.
- Core modules live under `scripts/idle/` (not directly in `scripts/`) so the
  two entry scripts, the pure brain and the runtime adapter are visibly distinct.
- The plan's `tests/run.lua` + `busted` became a **dependency-free harness**
  driven by `tools/run_tests.py` over `lupa`, so the suite needs no luarocks, no
  compiler, and can also run on-device later.
