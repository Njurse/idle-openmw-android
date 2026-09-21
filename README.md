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
(one tap to send the character shopping / resting / training / exploring),
**Pack** (your inventory: junk flags, worn markers, tap to Equip / Sell / Drop),
**Talk** (recent conversations, topics heard, quests), **Log** (activity), and
**Open** — which launches Morrowind's *real* windows (Inventory, Journal, Barter,
Training, Dialogue, Spells, Map), so nothing in the game is out of reach.


---

## Quick start

**Run the test suite (headless, no game needed):**

```bash
pip install lupa                     # embedded LuaJIT, one wheel, no compiler
python tools/run_tests.py            # 278 specs under LuaJIT 2.1
python tools/run_tests.py --all      # also verify Lua 5.1 and 5.4 portability
python tools/run_tests.py --sim      # 1000-game-hour simulation with invariants
python tools/run_tests.py --only director   # just the specs matching a substring
python tools/run_tests.py --list     # list discovered spec modules
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
citation in [docs/openmw-lua-api.md](docs/openmw-lua-api.md) or a test.

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
| **Drive the player with AI packages** | ❌ impossible — the engine throws `Can't add AI packages to player` |
| **Automate the barter / rest / training UI** | ❌ no Lua API; performed directly instead |
| **Auto-select dialogue topics** | ❌ dialogue is observe-only (no `onInfoGetText`) |
| Android APK build & portrait un-gating | ⚠️ not done — needs the NDK toolchain and a device, not available on the dev host |
| Isometric camera | ⚠️ not done — needs OpenMW C++ work |
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
    │   ├── economy.lua           junk valuation, buy/sell plans
    │   ├── equipment.lua         item type -> equipment slot (tap-to-equip)
    │   ├── pathfinder.lua        route cache + atan2 steering
    │   ├── offlineProgress.lua   capped catch-up
    │   ├── combat.lua            threat assessment
    │   ├── dialogue.lua          observe-only response memory
    │   ├── directive.lua         user orders ("go shop") with a TTL
    │   ├── uiLayout.lua          console geometry (panel/tabs/rows/regions)
    │   ├── uiModel.lua           console brain: tabs, rows, footers, scrolling
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
├── spec/                         278 specs
├── mocks/openmw.lua              a full fake engine
├── fixtures/                     classes, states, worlds
└── sim/headless_sim.lua          1000-game-hour invariant run

tools/run_tests.py                lupa driver (LuaJIT 2.1 by default)
docs/                             verified API, architecture, deployment, limits
```

---

## Design in one paragraph

The brain is a **pure function of snapshots to commands**. `scripts/idle/*` never
calls the engine: it takes plain tables in and returns an ordered command batch
(`move`, `activate`, `sell`, `rest`, …). Everything engine-shaped lives in
`scripts/runtime/*` and is injected as an `env` table, which is why the whole
decision layer — and the adapter — can be exercised headlessly against
`tests/mocks/openmw.lua`. See [docs/architecture.md](docs/architecture.md).

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
