# idle-openmw

An **idle director** for OpenMW: a Lua mod that plays Morrowind's single-player
game for you — picking goals, walking the player there, fighting, shopping,
training, resting, and banking progress while you're away.

It is built for a **phone in portrait** (developed against a Samsung Galaxy S23+),
but it runs on desktop OpenMW too and everything important is testable without
the game.

```
┌──────────────────────────────┐
│ [AUTO]  auto-play  (tap)     │  ← top strip (under the notch)
│ fight  (2 hostiles, danger…) │
│ HP 84%  MP 60%  FT 71%  L 12%│
│ Gold 1,240   lvl 5  load 35/…│
│ 5h 03m  Sold junk for 32 g   │
├──────────────────────────────┤
│ Info Order Pack Talk Log Open│  ← console: tap a tab
│ > heavy cuirass x1 300g [ju… │
│   chitin dagger x5  8g [junk]│  ← tap a row to order/select
│   longsword     x1 90g [WORN]│
│   lockpick      x12 5g     ▲ │
│                          ▼   │
├──────────────────────────────┤
│ [Equip] [Sell] [Drop] [Refr] │  ← contextual footer
└──────────────────────────────┘
```

Three modes, cycled by tapping the top-left `[AUTO]` line (or pressing **L**):

| Mode | What happens |
|---|---|
| **MANUAL** | You drive. The mod emits **no commands at all** and hands movement back to the game's own touch controls — the game is fully playable. |
| **ORDERS** | Auto-play, but your queued orders take precedence. |
| **AUTO** | Fully self-playing. |

The console's tabs are **Info** (why the director chose what it chose), **Order**
(one tap to send the character shopping / resting / training / exploring, plus
every destination the nearest travel service offers), **Pack** (your inventory:
junk flags, worn markers, tap to Equip / Sell / Drop), **Talk** (recent
conversations, topics heard, quests), **Log** (activity), **Open** — which
launches Morrowind's *real* windows (Inventory, Journal, Barter, Training,
Dialogue, Spells, Map), so nothing in the game is out of reach — and **Setup**,
where the bot's own behaviour is tappable: simulated actions, autonomous travel,
whether it may attack NPCs or creatures, console refresh rate, and the mode it
loads into. Changes apply immediately and only the values you changed are saved.

Two things make the console liveable rather than a slab over half your screen:

- **Shrink** (a footer button on every tab) collapses it to a tab strip, one row
  and one footer row, handing most of the screen back to the game. Tap
  **Expand** to bring it back. Collapsing is purely presentational — the director
  is not consulted, nothing changes about what the character is doing.
- A **page readout** ("rows 15-28 of 40") sits above the list, so you always know
  where you are in a long inventory or log.


---

## Quick start

**Run the test suite (headless, no game needed):**

```bash
pip install lupa                     # embedded LuaJIT, one wheel, no compiler
python tools/run_tests.py            # 460 specs under LuaJIT 2.1
python tools/run_tests.py --all      # also verify Lua 5.1 and 5.4 portability
python tools/run_tests.py --sim      # 1000-game-hour simulation with invariants
python tools/run_tests.py --only director   # just the specs matching a substring
python tools/run_tests.py --list     # list discovered spec modules
python tools/preview_console.py --png       # draw the console (docs/theme.md)
```

**See the console without launching the game:**

```bash
python tools/preview_console.py --tab info --png    # -> build/console-preview.png
```

**Install into OpenMW:**

1. Copy `mods/idle_openmw/` into your OpenMW data directory (see
   [docs/deployment.md](docs/deployment.md)).
2. Add it as a data folder and enable `idle_openmw.omwscripts`.
3. Load a save. The HUD appears top-left; the game starts playing itself.
4. Press **L** (or tap **AUTO**) to pause the director at any time.

---

## What actually works, and what can't

This project began as a much more ambitious plan. A lot of that plan turned out
to rest on API capabilities OpenMW does not have. Rather than ship something
that pretends, here is the honest split — every claim below is backed by a
citation in [docs/openmw-lua-api.md | [Dev environment](docs/dev-environment.md)](docs/openmw-lua-api.md) or a test.

| Capability | Status |
|---|---|
| Choose goals from class + live stats | ✅ implemented, unit-tested |
| Walk the player along a navmesh path | ✅ implemented (`self.controls` + `nearby.findPath`) |
| Open a merchant / trainer / NPC | ✅ implemented (`GameObject:activateBy`) |
| Sell junk, buy supplies, train, rest | ✅ implemented by **direct** inventory/stat manipulation (`simulateActions`) |
| Offline progress while the game is closed | ✅ implemented, capped |
| **Play the game by hand** | ✅ MANUAL mode hands the controls back |
| Bottom-half console: Status / Orders / Pack / Talk / Log / Open | ✅ implemented; layout + interaction model unit-tested |
| Launch Morrowind's own windows from the console | ✅ implemented (`interfaces.UI.setMode`) |
| Inventory: tap an item to Equip / Sell / Drop | ✅ implemented via a pure type→slot mapping |
| Order the character around while it auto-plays | ✅ implemented (directives) |
| Full 1000-hour unattended run | ✅ simulated green (`--sim`) |
| Read the engine's live UI (which window is open) | ✅ implemented (`ui._getUiModeStack` → `idle/uiState.lua`, console "On screen" row) |
| Morrowind-styled console | ✅ colours adopted from the game's own GMSTs (`idle/theme.lua`); the font is already Morrowind's (`MysticCards`) |
| Do not disturb character creation | ✅ implemented (`types.Player.isCharGenFinished` → `idle/lifecycle.lua` gate) |
| **Drive the player with AI packages** | ❌ impossible — the engine throws `Can't add AI packages to player` |
| **Automate the barter / rest / training UI** | ❌ no Lua API; performed directly instead |
| **Auto-select dialogue topics** | ❌ dialogue is observe-only (no `onInfoGetText`) |
| Android APK build & portrait un-gating | ⚠️ not done — needs the NDK toolchain and a device, not available on the dev host |
| Runs on the installed engine | ⚠️ floor is **OpenMW 0.49+**; 0.48.0 lacks the chargen flag, UI mode stack, services and `omw/input` (measured — see `docs/openmw-lua-api.md`) |
| Isometric camera | ✅ implemented as a Lua lock (`openmw.camera`), **off by default**; hiding roofs/ceilings remains engine work ([docs/isometric.md](docs/isometric.md)) |
| Console cosmetics on real hardware | ⚠️ geometry is tested, pixels are not — needs an on-device pass |

Full reasoning: [docs/limitations.md](docs/limitations.md) and
[docs/plan-reconciliation.md](docs/plan-reconciliation.md).

---

## Layout

```
mods/idle_openmw/                 the mod you install
├── idle_openmw.omwscripts        manifest (PLAYER scripts)
└── scripts/
    ├── idleDirector.lua          PLAYER script: snapshot -> decide -> execute,
    │                             play modes, console actions (IdleOpenMW iface)
    ├── portraitUI.lua            PLAYER script: the phone console (tabs + HUD)
    ├── idle/                     PURE brain. never requires openmw.*
    │   ├── director.lua          orchestrator: snapshot -> commands, play modes
    │   ├── goalScoring.lua       transparent goal scoring
    │   ├── classPriorities.lua   class -> preference weights
    │   ├── statCrunch.lua        stats -> capability scores
    │   ├── worldsense.lua        "what is that actor?" services, travel, enemies
    │   ├── economy.lua           junk valuation, buy/sell plans
    │   ├── equipment.lua         item type -> equipment slot (tap-to-equip)
    │   ├── pathfinder.lua        route cache + atan2 steering
    │   ├── offlineProgress.lua   capped catch-up
    │   ├── combat.lua            threat assessment
    │   ├── dialogue.lua          observe-only response memory
    │   ├── directive.lua         user orders ("go shop") with a TTL
    │   ├── uiLayout.lua          console geometry (panel/tabs/rows/regions)
    │   ├── uiModel.lua           console brain: tabs, rows, footers, scrolling
    │   ├── uiState.lua           engine UI mode -> kind (the live "UI hook")
    │   ├── theme.lua             Morrowind UI palette (roles -> colours)
    │   ├── lifecycle.lua         menu/chargen/loading/dead/world phase gate
    │   ├── camera.lua            isometric camera lock (pitch/distance)
    │   ├── activityLog.lua       bounded log
    │   ├── config.lua            every tunable, validated
    │   ├── rng.lua               deterministic seeded RNG
    │   └── util.lua              math/table helpers
    └── runtime/                  the ONLY engine-facing code
        ├── engine.lua            the single place that names openmw.*
        ├── observer.lua          engine -> snapshot + console panel
        └── executor.lua          commands -> engine; equip/sell/drop

tests/                            headless, no engine
├── harness.lua                   zero-dependency describe/it/expect/assert
├── run.lua                       suite entry point
├── specs.lua                     fallback manifest
├── spec/                         441 specs
├── mocks/openmw.lua              a full fake engine
├── fixtures/                     classes, states, worlds
└── sim/headless_sim.lua          1000-game-hour invariant run

tools/run_tests.py                lupa driver (LuaJIT 2.1 by default)
docs/                             API, architecture, console, theme, tap-to-move, …
```

---

## Seeing the world (and the two things that can't be seen)

`scripts/idle/worldsense.lua` turns nearby actors into decisions using the real
records: `servicesOffered` (a 19-key map the engine binds) gives shops, trainers,
healers, repairers and enchanters, and `travelDestinations` identifies silt
striders and boats. So the director knows *who a merchant is* from engine data,
not a guess.

Two things the engine genuinely does not expose, and what the mod does about them:

- **There is no "is at war with the player" flag.** Grepping the whole Lua API for
  `isInCombat` returns nothing. The nearest signal is the AI Fight disposition,
  which cannot tell a town guard (Fight 100) from a bandit (Fight 95). Since
  attacking a guard ruins a save irreversibly, **NPC hostility is opt-in**
  (`sensing.npcFightHostility`, default off) — by default only creatures are
  enemies. Essential actors and anyone offering a service are never enemies, and
  `sensing.ignoreRecords` is an explicit never-hostile list. See
  [docs/limitations.md §1.4a](docs/limitations.md).
- **Autonomous travel is off by default** (`behaviour.autoTravel`). The 1000-hour
  simulation caught an unbounded `travel` goal looping degenerately and starving
  training and trading, so it ships disabled. The console still lists every
  destination the nearest travel service offers, so a journey is one tap away.

That is the pattern everywhere in this repo: where the engine can tell us, we read
it; where it cannot, the limitation is written down and the default is the safe one.

## Not dying at work

Dying is the one outcome that ends a set-and-forget run: the engine drops to the
load menu and nothing continues until you notice. So the mod carries a *guardian*,
in two layers:

- **Prevent.** Health is topped back up before it can reach zero
  (`guardian.criticalHealthFraction`, default 15%). This is cheating, and it is
  labelled as such; `guardian.preventDeath = false` turns it off and the guardian
  then only withdraws a wounded character instead.
- **Recover.** If death happens anyway, either **respawn** (the default) or
  **reload a save**:

  ```lua
  guardian.onDeath = 'respawn'   -- 'respawn' | 'reload' | 'none'
  guardian.saveSlot = nil        -- required for 'reload'
  ```

"Nearest town" is honestly **the last settlement you were healthy in**
(`guardian.safeHealthFraction`, default 60%). We cannot route to a town the
character has never seen, so the mod remembers where it last was fine and returns
there. On respawn every pool is refilled, not just health — a rescue that leaves
you with no fatigue to run on is how a rescue becomes a loop.

**MANUAL mode is left strictly alone**: you are present, so the game behaves like
vanilla, death included. `guardian.activeInManual = true` opts in.

Two engine facts shaped this (see `docs/openmw-lua-api.md` §10): `teleport` and
`menu.loadGame` are *global-script-only*, which is why the mod has one `GLOBAL:`
script (`scripts/idleWarden.lua`) alongside its two `PLAYER:` ones.

## Design in one paragraph

The brain is a **pure function of snapshots to commands**. `scripts/idle/*` never
calls the engine: it takes plain tables in and returns an ordered command batch
(`move`, `activate`, `sell`, `rest`, …). Everything engine-shaped lives in
`scripts/runtime/*` and is injected as an `env` table, which is why the whole
decision layer — and the adapter — can be exercised headlessly against
`tests/mocks/openmw.lua`. See [docs/architecture.md](docs/architecture.md).

## Docs

| Doc | What |
| --- | --- |
| [docs/openmw-lua-api.md](docs/openmw-lua-api.md) | the verified engine API, §0–§13, every claim with a `file:line` |
| [docs/architecture.md](docs/architecture.md) | the layers, the snapshot contract, the pipeline |
| [docs/console.md](docs/console.md) | every tab, order, option and gesture in the phone console |
| [docs/theme.md](docs/theme.md) | the Morrowind palette, the font question, the preview tool |
| [docs/tap-to-move.md](docs/tap-to-move.md) | tapping the world: raycast → walk / enter / talk |
| [docs/dialogue.md](docs/dialogue.md) | dialogue topics, and the one thing Lua cannot do |
| [docs/isometric.md](docs/isometric.md) | the camera lock, and why roofs stay visible |
| [docs/observability.md](docs/observability.md) | the decision trace and the test/observability tools |

| [docs/ui-inventory.md](docs/ui-inventory.md) | the decision trace and the test/observability tools |
| [docs/ui-overhaul.md](docs/ui-overhaul.md) | moving Morrowind's own windows (data, not Lua) |
| [docs/deployment.md](docs/deployment.md) | desktop + Android install, and the first run |
| [docs/android.md](docs/android.md) | the emulator, data staging, the `.omwscripts` wall |
| [docs/limitations.md](docs/limitations.md) / [docs/plan-reconciliation.md](docs/plan-reconciliation.md) | what is not done, and where the plan was wrong |

## Development notes

- Target runtime is **LuaJIT (Lua 5.1)** because that is what OpenMW ships. Keep
  the core 5.1-safe: no `goto`, no `//`, no `table.unpack`.
- Edit Lua with a file-writer, not a bash heredoc (heredocs mangle `\` escapes).
- `docs/openmw-lua-api.md` is the source of truth for the engine API. Trust it
  over any older planning document.
- `.research/` holds a gitignored shallow clone of OpenMW for API cross-checks.

## License

MIT (see [LICENSE](LICENSE)). OpenMW and Morrowind are their own things; this is
an unaffiliated mod.
- [The engine <-> host bridge API](docs/bridge-api.md)
