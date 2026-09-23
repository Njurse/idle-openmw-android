# Deployment

## PC (desktop OpenMW 0.49+)

**Which engine, and why the version matters.** The floor is **0.49+**, measured rather
than assumed (`docs/openmw-lua-api.md`, "The supported engine floor"). OpenMW 0.48.0 is
missing:

| Missing in 0.48.0 | So on 0.48 |
| --- | --- |
| `types.Player.isCharGenFinished` | no character-creation gate |
| `ui._getUiModeStack` | no live "what window is open" |
| `servicesOffered` on records | no shop/trainer/healer detection |
| `Player.journal().topics` | the Talk tab has no topics |
| `interfaces.Controls.overrideMovementControls` (the whole `omw/input` suite) | MANUAL mode cannot hand movement back |

The mod still *loads* on 0.48 and does not throw — every modern call is guarded, and
`scripts/runtime/capabilities.lua` reports what the engine actually has — but the features
above degrade, and the console's Info tab says so. The dev environment here runs
**0.51.0** (`tools/dev/desktop/`, `docs/dev-environment.md`).


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
4. Start a new game or load a save.

### The first run: new game → character creation → Seyda Neen

The mod is deliberately inert until the character is **free in the world**
(`scripts/idle/lifecycle.lua`). Concretely, on a new game:

- During character creation the engine's own windows ask you to pick a gender,
  name, race, class and birthsign. The mod emits **no** movement or action
  commands, so nothing fights those windows, and the console **stays hidden** so
  it does not cover them.
- Why it can tell: `types.Player.isCharGenFinished(player)` is false until the
  `chargenstate` global flips to `-1` (`docs/openmw-lua-api.md` §13). A `Chargen*`
  UI mode is a second, independent signal.
- Once the Census & Excise office releases you into Seyda Neen, the phase becomes
  `world`: the console appears and the director takes over.
- Press **L** to toggle auto-play (MANUAL ↔ AUTO), or use the console's
  **Mode** button.

If the console never appears, open the **Info** tab's "Holding" row — it names the
phase the mod is waiting on (usually `Character creation`).

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
| `ui.textScale` | `1.0` | Console text multiplier |
| `ui.startMode` | `'auto'` | Which mode to begin in: `manual`, `directive` or `auto` |

---

## Using the console

Tap the top-left `[AUTO]` line (or press **L**) to cycle modes:

| Mode | What it does |
|---|---|
| **MANUAL** | You drive. The mod stops issuing commands and hands movement back to OpenMW's touch controls. The console shrinks to leave the game more room. |
| **ORDERS** | Auto-play, but your orders take precedence. |
| **AUTO** | Fully self-playing. |

Tabs along the top of the console:

- **Info** — why the director chose what it chose: mode, current goal with reason,
  HP/MP/FT/load, gold, the top-scoring goals, and decision counters.
- **Order** — one tap to send the character shopping, selling junk, resting,
  training, healing, talking, questing or exploring. Orders also work in AUTO.
- **Pack** — your inventory with `[junk]` / `[WORN]` flags and gold-per-weight.
  Tap a row to select it, then use **[Equip] [Sell] [Drop]**. Equip handles
  armour, clothing, weapons, ammo and light sources; tools and anything whose slot
  cannot be derived will tell you to use the inventory window (see
  [limitations.md](limitations.md) §1.6).
- **Talk** — recent conversations, topics you have heard, and started quests.
- **Log** — the activity feed, newest first.
- **Open** — launches Morrowind's own windows: Inventory, Journal, Barter,
  Training, Dialogue, Spells, Map. This is what keeps the *whole* game reachable
  from the console.

`[AUTO]`/`[PAUSED]` in the top strip reflects the mode; `[Sell junk]`-style
buttons are contextual to the active tab.

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
