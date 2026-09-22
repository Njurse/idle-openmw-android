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

## Lifecycle, the live UI, and the camera

Three small pure modules sit between the snapshot and the decisions, each with a
single engine call behind it in `runtime/observer.lua`:

```
  observer.readLifecycle(env) ──► lifecycle.phase(...)  ──► { menu|loading|chargen|dead|world }
        types.Player.isCharGenFinished        acting == (phase == 'world')
                                              │
  observer.readUi(env) ────────► uiState.fromStack(...) ──► { mode, kind, blocking, label }
        ui._getUiModeStack()
                                              │
  idleDirector.applyCamera(phase) ──► camera.plan(cfg, phase, manual) ──► openmw.camera
```

- **`idle/lifecycle.lua`** decides whether the director may act at all. During
  character creation (and the menu / a load screen) `acting` is false, so
  `director:tick` returns **no commands** and the runtime clears the executor.
  This is what lets a player actually get through chargen to Seyda Neen.
  An engine that cannot report char-gen resolves to `world`, so the mod is never
  locked out.
- **`idle/uiState.lua`** classifies the engine's current window into a stable
  vocabulary. It is the honest form of "hook into the UI": Lua can read *which*
  window is open, not its contents.
- **`idle/camera.lua`** is a pure plan for the isometric lock; `idleDirector`
  applies it through `openmw.camera`. Off by default. The *law* is pure and
  tested; the applying is one guarded block.

The guardian is deliberately **outside** this gate: its whole job is the `dead`
phase, so it keeps running even when the director is held back.

See `docs/openmw-lua-api.md` §11–§13 and `docs/isometric.md`.

## World sensing (`idle/worldsense.lua`)

The runtime hands `worldsense` a flat descriptor per nearby actor and gets back a
verdict: which roles it fills, whether it is an enemy, and why. Keeping the rules
pure means the *rules* are tested even though the records they read are not.

```
runtime/observer.describeActor(env, object)
    object.type.record(object)          -> NpcRecord / CreatureRecord
    object.type == types.Creature       -> is this a creature?
    types.Actor.stats.ai.fight(object)  -> AIStat { base, modified }
    types.Actor.stats.level(object)     -> { current, progress }
              |
              v
    worldsense.describe(spec, cfg)  ->  { roles, hostile, hostileReason, ... }
              |
              v
    worldsense.scan(descriptors, { position, scanRadius })
              ->  { opportunities, nearest, enemies }
```

Design rules that the specs enforce:

- **Services suppress hostility.** A merchant must never be an enemy, however
  belligerent its AI data looks. Tested directly.
- **`Travel` is not a service key.** The field's own comment lists it, but it is
  not one of the 19 bound `ServiceNames` — travel is detected from
  `travelDestinations`. A spec pins this so nobody "simplifies" it back.
- **Hostility says why.** Every verdict carries `hostileReason`, which reaches the
  activity log, so a surprising enemy is diagnosable rather than mysterious.
- **The default is the safe default.** Creatures only; NPC hostility opt-in.

## Why the HUD geometry is separate

`idle/uiLayout.lua` (geometry) and `idle/uiModel.lua` (tabs, rows, footers,
scrolling, mode cycling) are pure and unit-tested; `portraitUI.lua` only turns
their output into widgets. The widget calls cannot be verified headlessly, so all
the arithmetic and all the interaction logic that *could* be wrong was moved
somewhere it *can* be verified. The layout spec even asserts that **no two touch
regions overlap**.

## The console (phone UI)

```
runtime/observer.readPanel(env)  --- engine-derived --->  player, inventory,
                                                         journal, quests
director:panelData()             --- brain-derived  --->  status, mode,
                                                         directive, dialogue
                                                         transcript, log
                    |
                    v
        uiModel.buildRows(tab, panel)   --> rows
        uiModel.view(state, panel, layout) --> tab, visible slice, selection, footer
                    |
                    v
        portraitUI.lua  --> ui.create(...) widgets with mouseClick handlers
```

- **Rendering strategy.** Elements are created once per resolution and then have
  `layout.props.text` updated in place. OpenMW's `Element:update()` refreshes an
  element's own props but *not* its children's layouts, so every node is a root
  element rather than a nested child tree.
- **Interaction.** Tapping a row/​tab/​footer button calls the `IdleOpenMW`
  interface: `act(action, payload)`. The action table lives in `idleDirector.lua`
  (`cycle_mode`, `pause`, `order`, `cancel`, `equip`, `sell`, `drop`,
  `talk_nearest`, `clear_log`, `launch`). Because `uiModel` builds the rows and
  `uiLayout` builds the rects, the *whole* console is exercised headlessly —
  including simulated taps, which the specs do by calling the stored
  `events.mouseClick` handler directly.
- **Manual mode.** `act('pause')`/`setMode('manual')` calls
  `interfaces.Controls.overrideMovementControls(false)`, which hands the player
  back to OpenMW's own input script. The director then emits **zero** commands,
  so the game is genuinely playable.
- **Launchers.** `act('launch', { mode = 'Journal' })` calls
  `interfaces.UI.setMode(mode, opts)`. Modes are the real engine names from
  `mwlua/uibindings.cpp`: `Interface`, `Journal`, `Barter`, `Training`,
  `Dialogue`, `Rest`, `SpellBuying`, … Dialogue is given a `target` taken from
  the last snapshot's nearest talkable actor.
- **Setup** is the one tab that writes instead of reading.
  `act('set_option', { key })` cycles a value in the **live** config table — the
  one the director, the executor and the panel all hold a reference to — then
  re-derives the director's cached state and persists `config.overridesOf(cfg)`,
  i.e. only the keys that actually differ from the shipped defaults. Persisting
  the difference rather than the whole config is why a later default change still
  reaches an existing save.

## Collapsing the console (and a bug worth remembering)

`uiLayout.split(base, mode, collapsed)` gives the collapsed console its own
fraction (`M.COLLAPSED_FRACTION`), `console(cfg, { collapsed = true })` drops the
page strip, and `portraitUI` keeps the flag in its own state — collapsing is
*presentational*, so the director is never consulted. The spec asserts the
director sees no `act` call at all when you collapse.

The first implementation set `state.built = false` to force a rebuild and forgot
to destroy the old widgets. The tests caught it immediately: `elementWithText`
still found the previous tab strip, and the "no leaking elements" spec counted
two consoles. Every rebuild now goes through one `requestRebuild()` that destroys
first — resize/rotation included, which had its own copy of the destroy loop.
That the leak was invisible on paper and obvious in a headless test is the whole
argument for building the console this way.

## Tap-to-equip without guessing

`equipment.lua` exists because Morrowind's item `type` numbers do **not** line up
with equipment slot numbers (armor type 2 is `LPauldron`; equipment slot 2 is
`Greaves`). So the mapping is done in named steps, each pure:

```
record.type (number)
  -> type NAME   (invert types.<Kind>.TYPE)
  -> slot NAME   (the KIND_SLOT tables: Cuirass->Cuirass, Shield->CarriedLeft, Ring->LeftRing, …)
  -> slot NUMBER (types.Actor.EQUIPMENT_SLOT)
```

If any step cannot be resolved — tools like lockpicks and probes, which the game
*selects* rather than wears — the mapping returns `nil` and the executor refuses
with "use the inventory window" instead of guessing a slot. That refusal is
itself a test.


## Test architecture

- `tests/harness.lua` — dependency-free `describe/it/expect/assert`, nested
  suites, `before_each`, collection-error capture.
- `tests/mocks/openmw.lua` — a fake engine with live state (inventory counts,
  stat pools) plus `package.preload` wiring, so `runtime/*` is tested for real.
- `tests/fixtures/` — classes, states, worlds.
- `tests/sim/headless_sim.lua` — a world model that plays 1000 game-hours and
  asserts invariants (no crashes, gold trends up but not implausibly,
  no goal dominates, determinism, class priorities, offline catch-up).
