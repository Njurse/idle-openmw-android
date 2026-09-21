# Deployment

## PC (desktop OpenMW 0.49+)

1. Locate your data directory:
   - **Windows:** `%USERPROFILE%\Documents\My Games\OpenMW\`
   - **Linux:** `~/.local/share/openmw/`
   - **macOS:** `~/Library/Application Support/openmw/`
2. Copy the mod next to your other mods:
   ```
   <data>/Mods/idle_openmw/        <- copy mods/idle_openmw/ here
   ```
3. Add it as a data folder in `openmw.cfg` **before** the Morrowind data
   entries you want it to see, and add the script manifest:
   ```
   data="C:/.../Mods/idle_openmw"
   content=idle_openmw.omwscripts
   ```
   With a mod manager, add `Mods/idle_openmw` as a data path and enable
   `idle_openmw.omwscripts`.
4. Load a save (or start a new game). The HUD appears top-left and the director
   takes over. Press **L** to toggle auto-play.

**Sanity check the install** without launching the game: the mod is plain Lua, so
you can require it in the test host:

```bash
python tools/run_tests.py        # proves the brain and the adapter are sound
```

## Android (Samsung Galaxy S23+ or any device)

Morrowind data lives at `/storage/emulated/0/Morrowind/Data Files/`. Put the mod
beside it:

```
/storage/emulated/0/Morrowind/Mods/idle_openmw/
```

and add to the device's `openmw.cfg`:

```
data="/storage/emulated/0/Morrowind/Mods/idle_openmw"
content=idle_openmw.omwscripts
```

The mod works in **landscape out of the box** (OpenMW Android's game activity is
`sensorLandscape`). The HUD is designed portrait-first and reflows on
`onResolutionChanged`, so it adapts if you rotate.

> ⚠️ **Portrait orientation is not something this mod can do for you.** OpenMW
> Android hard-codes `sensorLandscape` on `GameActivity`, and a 2020 release note
> says portrait was disabled because it "caused random crashes". Un-gating it is
> an engine/app change (`AndroidManifest.xml` + the OSG camera aspect
> computation), and it must be validated on real hardware. That work is **not
> done here** — see [limitations.md](limitations.md) §2.

### S23+ tuning (all still applicable)

The plan's device guidance is sound and mostly orthogonal to the Lua work:

| Goal | Setting |
|---|---|
| Save battery | Auto-play at 15–20 FPS, manual at 30 FPS |
| Heat | Disable shadows in auto-play; render 720p and upscale |
| Stability | Watch `PowerManager.getCurrentThermalStatus()` and drop FPS on throttle |
| Keep running | Request `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` if you want it alive when backgrounded |

A thermal policy can be implemented in Lua against `openmw.core` /
`openmw.camera` and a `PowerManager` bridge, but the bridge is app-side (Kotlin).
Not implemented here.

---

## Configuration

Override anything by writing a partial table to the mod's player storage section
`IdleOpenMW`, key `config`. Unspecified keys keep their defaults
(`mods/idle_openmw/scripts/idle/config.lua` is the canonical list).

```lua
local storage = require('openmw.storage').playerSection('IdleOpenMW')
storage:set('config', {
  tick = { interval = 3.0 },
  thresholds = { criticalHealth = 0.3, junkValuePerWeight = 30 },
  behaviour = { simulateActions = false, barterRatio = 1.0 },
  offline = { maxRealHours = 12 },
  ui = { textScale = 1.2 },
})
```

### Reference

| Key | Default | Meaning |
|---|---|---|
| `tick.interval` | `2.0` | Simulation seconds between decisions |
| `tick.logLimit` | `200` | Activity-log ring size |
| `weightOverrides.*` | `1.0` | Multipliers on the class-derived weights (`combat`, `magic`, `stealth`, `social`, `economy`, `train`) |
| `thresholds.criticalHealth` | `0.25` | Health fraction that forces `survive` |
| `thresholds.lowHealth` / `lowMagicka` / `lowFatigue` | `0.5` / `0.2` / `0.15` | Rest/heal/shop triggers |
| `thresholds.encumbranceHigh` | `0.85` | Load fraction that forces a shop trip |
| `thresholds.junkValuePerWeight` | `20` | Gold-per-weight below which loot is junk |
| `thresholds.dangerFlee` / `dangerEngage` | `0.7` / `0.35` | Flee above / engage below |
| `thresholds.restHours` | `8` | Hours per rest action |
| `goalBias.*` | see file | Per-goal desirability |
| `levelScaling` | `0.02` | `score *= 1 + levelScaling * level` |
| `offline.enabled` | `true` | Award catch-up |
| `offline.maxRealHours` | `8` | Hard cap on the catch-up window |
| `offline.gameHoursPerRealMinute` | `1` | Time compression |
| `behaviour.arriveTolerance` | `96` | Engine units counted as "arrived" |
| `behaviour.stuckTimeout` | `45` | Sim seconds without progress before giving up on a move |
| `behaviour.simulateActions` | `true` | Perform barter/rest/training directly (see [limitations.md](limitations.md) §1.3) |
| `behaviour.barterRatio` | `0.8` | Merchant pays this fraction of book value |
| `behaviour.directiveTtl` | `120` | How long a user directive stays in force |
| `ui.topInset` / `bottomInset` | `24` | Extra safe-area padding, in UI units |
| `ui.textScale` | `1.0` | HUD text multiplier |

---

## Verifying a change

```bash
python tools/run_tests.py --all      # correctness + Lua version portability
python tools/run_tests.py --sim      # long-run invariants (1000 game-hours)
python tools/run_tests.py --sim --hours 5000 --seed 42   # a harsher soak
```

The simulation asserts: no thrown errors, gold trends up but stays plausible, no
goal dominates the run, the result is deterministic for a seed, class priorities
are respected, and offline catch-up applies.
