# idle-openmw

An **idle director** for OpenMW: a Lua mod that plays Morrowind's single-player
game for you — picking goals, walking the player there, fighting, shopping,
training, resting, and banking progress while you're away.

It is built for a **phone in portrait** (developed against a Samsung Galaxy S23+),
but it runs on desktop OpenMW too and everything important is testable without
the game.

```
┌──────────────────────────────┐
│ Idle OpenMW · lvl 5 · AUTO   │  ← status strip (under the notch)
│ fight  (2 hostiles, danger…) │
│ HP 84%  MP 60%  FT 71%  L…   │
│ Gold 1,240                   │
│ 5h 03m  Sold junk for 32 g   │
│ 5h 05m  Walking to Trader    │
│                              │
│        (the game renders)    │
│                              │
│ ┌──────┐┌──────┐┌────────┐   │  ← touch command bar
│ │ AUTO ││ Shop ││Sell jun│   │     (stacks upward, above the
│ └──────┘└──────┘└────────┘   │      gesture bar)
│ ┌──────┐┌──────┐             │
│ │ Rest ││Train │             │
│ └──────┘└──────┘             │
└──────────────────────────────┘
```

---

## Quick start

**Run the test suite (headless, no game needed):**

```bash
pip install lupa                     # embedded LuaJIT, one wheel, no compiler
python tools/run_tests.py            # 201 specs under LuaJIT 2.1
python tools/run_tests.py --all      # also verify Lua 5.1 and 5.4 portability
python tools/run_tests.py --sim      # 1000-game-hour simulation with invariants
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
| Portrait HUD with real touch buttons | ✅ implemented (geometry unit-tested; visuals need on-device tuning) |
| Full 1000-hour unattended run | ✅ simulated green (`--sim`) |
| **Drive the player with AI packages** | ❌ impossible — the engine throws `Can't add AI packages to player` |
| **Automate the barter / rest / training UI** | ❌ no Lua API; performed directly instead |
| **Auto-select dialogue topics** | ❌ dialogue is observe-only (no `onInfoGetText`) |
| Android APK build & portrait un-gating | ⚠️ not done — needs the NDK toolchain and a device, not available on the dev host |
| Isometric camera | ⚠️ not done — needs OpenMW C++ work |

Full reasoning: [docs/limitations.md](docs/limitations.md) and
[docs/plan-reconciliation.md](docs/plan-reconciliation.md).

---

## Layout

```
mods/idle_openmw/                 the mod you install
├── idle_openmw.omwscripts        manifest (PLAYER scripts)
└── scripts/
    ├── idleDirector.lua          PLAYER script: snapshot -> decide -> execute
    ├── portraitUI.lua            PLAYER script: HUD + touch command bar
    ├── idle/                     PURE brain. never requires openmw.*
    │   ├── director.lua          orchestrator: snapshot -> commands
    │   ├── goalScoring.lua       transparent goal scoring
    │   ├── classPriorities.lua   class -> preference weights
    │   ├── statCrunch.lua        stats -> capability scores
    │   ├── economy.lua           junk valuation, buy/sell plans
    │   ├── pathfinder.lua        route cache + atan2 steering
    │   ├── offlineProgress.lua   capped catch-up
    │   ├── combat.lua            threat assessment
    │   ├── dialogue.lua          observe-only response memory
    │   ├── directive.lua         user directives ("go shop")
    │   ├── uiLayout.lua          phone layout geometry
    │   ├── activityLog.lua       bounded log
    │   ├── config.lua            every tunable, validated
    │   ├── rng.lua               deterministic seeded RNG
    │   └── util.lua              math/table helpers
    └── runtime/                  the ONLY engine-facing code
        ├── engine.lua            the single place that names openmw.*
        ├── observer.lua          engine -> snapshot
        └── executor.lua          commands -> engine

tests/                            headless, no engine
├── harness.lua                   zero-dependency describe/it/expect/assert
├── run.lua                       suite entry point
├── specs.lua                     fallback manifest
├── spec/                         201 specs
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
