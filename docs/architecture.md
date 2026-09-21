# Architecture

## The one idea

**The brain is a pure function of snapshots to commands.**

Everything else is plumbing. The decision layer never calls the engine, never
reads a clock, never touches `io`. It receives plain tables and returns plain
tables. That is what makes an idle game — a thing that is otherwise awkward to
test — fully testable without the game.

```
        engine (openmw.*)
              │
              │  runtime/observer.lua        reads stats, inventory, nearby,
              ▼                              pathfinding
        ┌───────────┐
        │ SNAPSHOT  │  { player = {...}, world = {...}, time = {...} }
        └─────┬─────┘
              │
              │  idle/director.lua:tick(dt, snapshot)
              ▼
   classPriorities ──► weights      "what it wants"
   statCrunch      ──► capability   "what it can do"
   goalScoring     ──► goal         transparent scoring, ranked
   planCommands    ──► COMMANDS     ordered intent batch
              │
              │  runtime/executor.lua
              ▼
        engine calls (controls, activateBy, inventories, stats)
```

## Layers

| Layer | Files | May touch |
|---|---|---|
| Core | `scripts/idle/*.lua` | nothing but other core modules |
| Runtime | `scripts/runtime/*.lua` | an injected `env` table |
| Scripts | `scripts/idleDirector.lua`, `scripts/portraitUI.lua` | my `env`, `openmw.*` via `engine.lua` |

`runtime/engine.lua` is the *single* module that names `openmw.*`. It caches
lazily and returns `nil` (never throws) outside OpenMW.

## Contracts

### Snapshot (`observer.build`)

```lua
{
  player = {
    level, levelProgress,
    health  = { base, current, modifier },
    magicka = { base, current, modifier },
    fatigue = { base, current, modifier },
    encumbrance = { current, max },
    gold,
    skills     = { [skillId] = { base, modified, progress } },
    attributes = { [skillId] = { base, modified } },
    inventory  = { { id, count, value, weight, equipped, quest }, ... },  -- sorted, no currency
    position = { x, y, z }, yaw, cell = { name, isExterior }, inCombat,
  },
  world = {
    opportunities = { shop, trainer, healing, rest, talk, quest, loot, unexplored },  -- 0..1
    enemies, danger, junkValue,
    nearest = { shop = { name, position, distance, object }, trainer, healer, rest, talk, quest, enemy },
    threat = { danger, count, verdict }, enemies_nearby,
  },
  time = { simulation, game, real },
}
```

The player shape is exactly what `statCrunch.compute` consumes; the world shape
is exactly what `goalScoring` consumes. Both are documented at the top of
`scripts/idle/director.lua` and built in `tests/fixtures/states.lua` /
`tests/fixtures/worlds.lua`.

### Commands (`director:planCommands`)

An **ordered** batch. `[move, activate]` reads "walk there, then interact".

| Command | Fields |
|---|---|
| `move` | `dest`, `run` |
| `flee` | `from`, `dest`, `distance`, `run` |
| `stop` | — |
| `activate` | `kind` (`shop`/`trainer`/`healer`/`talk`/`quest`/`attack`), `target` |
| `sell` | `plan` (from `economy.planSales`) |
| `buy` | `plan` (from `economy.planPurchases`) |
| `rest` | `hours` |
| `train` | `skill` |
| `useItem` | `tag` (`healing`/`magicka`/`fatigue`) |
| `wander` | `radius` |

`executor.lua` treats `move`/`flee` as *blocking* (it starts a route and waits),
executes everything else immediately, and lets `wander` push a generated `move`
back onto the front of the queue.

## Decision model

```
score(goal) = bias(goal)
            * aptitude(goal)        -- mean over its categories of weight[c] * capability[c]
            * need(goal)            -- 0..1, urgency
            * opportunity(goal)     -- 0..1, reachability
            * (1 + levelScaling * level)
            - riskWeight(goal) * risk(goal) * RISK_SCALE
```

Twelve goals: `survive, heal, flee, fight, rest, train, shop, sell_junk, talk,
quest, explore, idle`. Every factor is returned in the ranking, so the HUD can
show *why* and the specs can assert on it.

Two deliberate rules:

- **`idle` is a fallback, not a competitor.** It is only chosen when no other
  goal has both a positive need and a positive score.
- **`aptitude` couples preference with ability**, so a warrior with a blunt
  weapon and a mage with a spellbook prefer different things even at equal need.

**Directives** (`idle/directive.lua`) override the choice with a TTL, and always
yield to `survive`/`flee`.

## Movement (no AI packages allowed)

The engine refuses to give the player an AI package. So:

1. `nearby.findPath` (two return values!) gives waypoints.
2. `pathfinder.Route` caches them, repaths on TTL/drift, and detects being stuck.
3. `pathfinder.steering` computes `desiredYaw = atan2(dx, dy)` — matching
   `MWMechanics::zTurn` — and the executor writes `self.controls.yawChange` and
   `movement`.

`idleDirector.lua` calls `interfaces.Controls.overrideMovementControls(true)` on
startup so the built-in input script stops fighting for the controls.

## Persistence & offline progress

`idleDirector.lua` implements `onSave`/`onLoad`. Saved state is the director's:
RNG state, counts, dialogue memory, visited cells, and `lastSeen` from
`os.time()` (`core.getRealTime()` resets each launch and is the wrong axis).

`onLoad` **must not** touch `openmw.nearby`, so it only stashes the payload;
`ensureInit` applies it on the first `onUpdate`. Catch-up maths is pure
(`offlineProgress.lua`) and capped by `offline.maxRealHours`.

## Why the HUD geometry is separate

`idle/uiLayout.lua` is pure and unit-tested; `portraitUI.lua` only turns its
rectangles into widgets. The widget calls cannot be verified headlessly, so all
the arithmetic that could be wrong was moved somewhere it *can* be verified.

## Test architecture

- `tests/harness.lua` — dependency-free `describe/it/expect/assert`, nested
  suites, `before_each`, collection-error capture.
- `tests/mocks/openmw.lua` — a fake engine with live state (inventory counts,
  stat pools) plus `package.preload` wiring, so `runtime/*` is tested for real.
- `tests/fixtures/` — classes, states, worlds.
- `tests/sim/headless_sim.lua` — a world model that plays 1000 game-hours and
  asserts invariants (no crashes, gold trends up but not implausibly,
  no goal dominates, determinism, class priorities, offline catch-up).
