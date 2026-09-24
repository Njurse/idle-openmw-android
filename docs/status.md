# Status — where this stands, and what to pick up next

A return-here note. Everything below is **measured on the built 0.52 engine**, not inferred, and
each claim names the command that produced it so it can be re-run rather than trusted.

Last worked: the session that fixed the weapon draw. Engine: `F:/OpenMW-build/build/openmw.exe`
(OpenMW 0.52, Lua API revision 160).

## What works right now

**The idle loop runs end to end on a real engine.** The character walks to a creature, draws a
weapon, and fights it:

```
t+10s goal=fight stance=1 moved=3463.8 pos=(-15227, -67799) cmds=['move', 'activate/attack']
t+15s goal=fight stance=1 moved=   2.2 pos=(-15225, -67798) cmds=['move', 'activate/attack']
...
TOTAL WALKED: 3471.1 units
  'Drew ': 8      'Cannot attack': 0
```

Read off `build/dev-scratch/combat-probe.sh` (starts the engine, then samples the bridge). Note the
stopping: it holds position once in reach, which is melee, not a stall.

The five defects fixed to get there, each of which was **silent** — the frame update is
pcall-guarded, so nothing threw and the log kept saying things were fine:

1. `util.point` rejected userdata, so every distance was nil — and a nil distance makes
   `Route:update` fall through its arrival test into "the path is spent", which reports `arrived`.
   The character "arrived" 4000 units short, forever.
2. `self.rotation` is a **Transform** userdata, not an angle, so steering never converged while the
   log said `moving = true`.
3. The danger model summed every hostile in a 4096-unit scan radius, so 25 distant slaughterfish
   saturated danger at 1.00 and Seyda Neen read as a warzone. Now proximity-weighted.
4. A goal that could not act parked the character while its reason line claimed otherwise. Goals
   now fall through to the next ranked one that can act.
5. **An item's `object.type` is a userdata Type object**, so `equipment.kindOf` classified *every*
   item as `kind = 'other'` — no weapon was ever equippable, and a character holding an iron dagger
   still reported `fightWith = 'spell'`. (`aim.lua` and `entity.lua` had the same table-only guard
   on **positions**, so the whole aim/tap-to-move geometry returned nil for real engine data.)

And the one that needed the engine's source rather than a guess: **`openmw.self.object` is an
`LObject`**, while `setStance` takes a **`SelfObject`** (`localscripts.cpp:76` vs
`types/actor.cpp:213`). Passing `.object` throws — which is what `Cannot attack: the engine would
not draw <weapon>` actually meant. Keeping the pcall's error text is what turned a mystery into a
one-line fix.

Test suite: **783 specs, 0 failed, 0 pending** on LuaJIT 2.1 / Lua 5.1 / Lua 5.4
(`python tools/run_tests.py --all`), plus the 1000-hour invariant simulation
(`python tools/run_tests.py --sim`) with all invariants holding.

## What is blocked, and exactly why

### Reading a spell is impossible from Lua — it needs injection or an engine binding

This is the clearest example of the scope the user set (**engine for what Lua cannot express,
injection for what the UI can**).

- **`Actor.setSelectedSpell` does not exist in 0.52.** The mod was calling it through a `pcall`, so
  the call silently did nothing *while the log blamed the engine*.
- On the **player**, `setStance(Spell)` asks the **`WindowManager`** which spell is selected
  (`types/actor.cpp:229-236`), falling back to a selected enchanted item, then `return`s silently.
  Lua can only reach `CreatureStats`, which is a different slot the engine deliberately does not
  consult for the player.

So a spell cannot be readied from Lua at all. The weapon path is now fixed and is enough to fight;
magic needs one of:

- **injection** — select the spell in the magic menu as a player would (this is the Android app's
  touch path anyway), or
- **an engine binding** — e.g. a fork patch exposing "set the player's selected spell" that also
  resets `WindowManager::mSelectedSpell` the way `actor.cpp:176` already does for enchanted items.

### Chargen still gates a real new game

Unchanged, and named in `docs/chargen.md`: `chargenstate` is set by Morrowind's own CharGen ESM
script, which only runs while the world is **unpaused**. After the intro dialogs the world sits
paused behind a message box that Lua can neither see nor dismiss. Current workaround: start in an
exterior cell with `--skip-menu=1 --start="Seyda Neen"`. The engine-side hook is the cheap half and
is the named follow-up.

### The Android engine build needs a dependency tree, not a toolchain

`docs/android.md` has the measurements. In short: an NDK (r29) is installed and **provably
cross-compiles Android binaries from this Windows host**, so the toolchain was never the blocker.
`openmw-android` is a **superbuild** pinned to NDK r21e and 2019-2021 dependency releases, so the
work is producing an Android dependency tree for `OPENMW_DEPENDENCIES_DIR`. The first configure
gets as far as `Could NOT find LZ4` (`CMakeLists.txt:281`) — which is the dependency list starting,
not a compile failure. Reproduce with `tools/android/configure-android.sh`.

Keep the mod's **≥ 0.49** floor in view: the released APK is 0.48 and predates `.omwscripts`.

## Verified engine reference

Facts already checked against source, so they need not be re-derived:

| Fact | Where |
|---|---|
| `openmw.self.object` is an `LObject`; `setStance` needs the `SelfObject` | `localscripts.cpp:76`, `types/actor.cpp:213` |
| `setStance` returns **silently** on "already in that stance" and "attack in flight" | `types/actor.cpp:231`, `:250` |
| Player spell selection lives in the `WindowManager`, not `CreatureStats` | `types/actor.cpp:229-236` |
| **No** `setSelectedSpell` binding exists in 0.52 | `types/actor.cpp` (absent) |
| `Actor.getEquipment` / `NPC.getFactions` return real `sol::table`s (so a table check is correct there) | `types/actor.cpp:317`, `types/npc.cpp:497` |
| Engine values are userdata, including an item's `type` | `AGENTS.md` #7 |
| `nearby.findPath` returns **two** values `(status, points)` | `nearby.lua:120` |

## Open threads (found, not yet chased)

1. **Combat resolution.** The character closes to melee and stays put with
   `cmds=['move', 'activate/attack']` for 40+ seconds, and `'killed': 0`. Either it is whittling a
   high-HP mudcrab (fine) or the swings are not landing (not fine). Next probe: log the target's
   health each swing.
2. **`player.inventory` shape.** It answered `['common_pants_01', 'common_shirt_01',
   'common_shoes_01']` — only the *worn* items — while the warden had just created an iron dagger.
   That looks like the equipped-item reader answering where the full pack was meant. Worth
   confirming which shape the API claims to return.

## How to reproduce the whole live workflow

```bash
# 1. the offline suite (no engine needed)
python tools/run_tests.py --all
python tools/run_tests.py --sim

# 2. start the engine and watch it play
bash build/dev-scratch/combat-probe.sh        # walks, draws, fights

# 3. ask the running engine anything (write a request, read the reply from openmw.log)
printf '{"id":1,"method":"ui"}\n' > mods/idle_openmw/idle_api.txt

# 4. drive the mod from a file instead of the console
printf 'economy give iron dagger 1\n' > mods/idle_openmw/dev_command.txt
```

Gotchas that cost time: the engine **pauses when its window loses focus** (hold it with
`tools/dev/desktop/keep_focus.py`), and a large bridge answer can be **interleaved into the
middle of the JSON line** in `openmw.log`, so match by request id and prefer the small `ui` report.

## Where the scope now points

The user set this direction: **the deliverable is an Android app that hosts the mod and drives the
engine**, with engine changes for what Lua cannot express and UI injection for what it can.
`docs/app-ui.md` is the specified layout (viewport panel, stat strip, tap-to-command action panel,
character portrait column, plus journal / inventory / map / character sheet / spellbook).

That reframes the two blocked items above as *app* work rather than workarounds: spell selection
and chargen dismissal are both things the app can do by injecting touches, and both are the same
mechanism.

## Suggested next steps, in order

1. **Chase the combat outcome** (open thread 1) — the loop closes only if something dies.
2. **Pick the spell route**: injection vs a fork binding, and record the decision. It is the first
   real instance of the engine/injection split, so it sets the pattern.
3. **Settle `player.inventory`'s shape** (open thread 2) — cheap, and it is what the app's
   inventory screen will consume.
4. **Then the Android dependency tree**, which is the long pole and is now well understood.
