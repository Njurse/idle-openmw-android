# Limitations

This document exists so nobody — human or agent — has to rediscover these by
watching the mod misbehave. Every limitation is either *engine-imposed*
(verified against OpenMW source) or *environment-imposed* (this project's dev
host). Nothing here is "we didn't get to it" dressed up as a constraint.

---

## 1. Engine-imposed: what OpenMW's Lua API will not let a mod do

### 1.1 The player cannot be driven by AI packages

The single biggest correction to the original design. The plan's core mechanism
was:

```lua
AI.startPackage({ type = 'Travel', destination = pos })   -- ❌ twice wrong
```

Three separate problems:

- `interfaces.AI` is a **local-script** interface: it acts on the script's own
  actor, which for a PLAYER script *is the player*, and the engine then throws
  `Can't add AI packages to player` (`apps/openmw/mwmechanics/aisequence.cpp:389`).
- The field is **`destPosition`**, not `destination`
  (`files/data/scripts/omw/ai.lua:45-47`). `destination` raises
  `destPosition required`.
- Only six package types exist at all: `Combat`, `Pursue`, `Follow`, `Escort`,
  `Wander`, `Travel`. No `Explore`, `Activate`, `Wait` or `Sleep` package.

**Consequence.** Movement is implemented the only way that works: steer the
player with `self.controls` (`movement`, `yawChange`, `run`, …) along a navmesh
path, with `interfaces.Controls.overrideMovementControls(true)` to stop the
built-in input script fighting us. Yaw is `atan2(dx, dy)`, matching
`MWMechanics::zTurn` (`aiface.cpp:17`).

### 1.2 Dialogue is observe-only

- There is **no `onInfoGetText`** handler. Grepping the whole engine finds
  nothing. Neither `onDialogue`, `onTopic`, nor `onPersuasion` exist either.
- `DialogueResponse` is a **notification-only** Lua event on the player's local
  scripts (`luamanagerimp.cpp:541-560`) with fields
  `{ actor, type, recordId, infoId }` and `type ∈ greeting|journal|persuasion|topic|voice`.
- "Event handlers can not return any data to the sender" (`overview.rst:483`).

**Consequence.** The mod cannot open a topic, choose a dialogue option, or
advance a quest by talking. It *observes* conversations to build a world model
(who talks, what topics exist, who refuses you) and otherwise acts through
engine-level moves. `scripts/idle/dialogue.lua` is explicitly a memory, not a
controller. This is why "shop by driving the barter menu" and "pick the quest
topic" from the plan are marked ❌.

### 1.3 Barter, rest, and training cannot be *UI-driven*

There is no Lua API to open the barter screen and complete a trade, to rest for
N hours, or to pay a trainer. `world.mwscript` only reads global-script state —
it cannot execute `Rest`/`Say`/`AddTopic`.

**Consequence — and the honest workaround.** The mod performs these actions
*directly*:

- selling = `inventory:find(id):remove(n)` + `world.createObject('gold_001', n):moveInto(inv)`
- buying = the reverse
- resting = `types.Actor.stats.dynamic.<pool>.current = .base`
- training = advancing `types.NPC.stats.skills.<id>.progress` and deducting gold

These are real, supported engine operations — but they are a *simulation* of the
activity, bypassing the game's own UI and its mercantile skill checks. They are
gated behind `behaviour.simulateActions` (default `true`). Set it to `false` and
the mod becomes purely advisory: it navigates and opens the relevant UI, then
tells you in the log what to tap.

### 1.4 "Who is a merchant?" — RESOLVED (was an invented limitation)

**This was wrong in an earlier revision of this document.** It claimed OpenMW's
Lua API does not expose an NPC's service flags. It does:
`NpcRecord.servicesOffered` and `CreatureRecord.servicesOffered` are a
`map<string, boolean>` over exactly the 19 service names the engine binds
(`files/lua_api/openmw/types.lua:1266`, `:964`;
`apps/openmw/mwlua/types/servicesoffered.hpp:11`). `travelDestinations`
(`types.lua:1267`) is how you tell a silt strider from a townsfolk.

`scripts/idle/worldsense.lua` now reads those records directly, so
`shop` / `trainer` / `healer` / `repairer` / `enchanter` / `travel` opportunities
are derived from real data with no pluggable hook. The lesson is recorded here
because it is the kind of error that repeats: an assumption about the API was
written down as a *limitation* and then built around.

### 1.4a Enemies are still a heuristic — and that is not fixable

There is **no** "is at war with the player" query. Grepping the entire Lua API
for `isInCombat` / `InCombat` / `inCombat` returns nothing. The nearest signal is
the AI disposition `types.Actor.stats.ai.fight(actor)` → `AIStat { base, modified }`
(`types.lua:544`), and it cannot distinguish a town guard (Fight 100) from a
bandit (Fight 95) — both read identically.

**Consequence, and the design response.** Auto-attacking a guard ruins a save
irreversibly, so NPC hostility is **opt-in** (`sensing.npcFightHostility`, default
`false`). By default only creatures are enemies, which is unambiguous. Even with
it enabled, essential actors and anyone offering a service are never enemies, and
`sensing.ignoreRecords` is an explicit never-hostile list.

### 1.5 Other shape traps already handled

- `nearby.findPath` returns **two values** `(status, points)`, not
  `{ status, path }`; options are `includeFlags` / `areaCosts`, not
  `includeDoors` / `includeSwim`.
- Positions are `util.vector3(...)` → `Vector3`. There is no `types.Position` and
  no `Vector3:distance()` — use `(a - b):length()`.
- `self.controls` is a struct of **fields**, not methods. `self.storage` does not
  exist (`require('openmw.storage')`). UI mode enum is `interfaces.UI.MODE`, not
  `core.UI_MODE`.
- `.omwscripts` comments are `#`; there is no `LOCAL:` flag; the path must end
  in `.lua`.
- **An item's `type` number is not its equipment slot number.** Armor type 2 is
  `LPauldron` while equipment slot 2 is `Greaves`. `scripts/idle/equipment.lua`
  exists solely to bridge that via names.

### 1.6 Tap-to-equip is best-effort by design

`types.Actor.setEquipment(actor, { [slot] = item })` works, but only for items
whose slot we can *derive*. Tools (lockpicks, probes, repair hammers), potions,
books and ingredients are **selectable, not wearable**, and an unknown armor type
gives us no slot at all. In those cases the mod refuses and tells you to use the
inventory window rather than guessing a slot — a wrong slot silently equips the
wrong thing, which is worse than a refusal. Armor, clothing, weapons, ammo and
light sources all resolve correctly.

### 1.7 The console's pixels are unverified

`uiLayout.lua` (geometry) and `uiModel.lua` (tabs, rows, footers, scrolling,
modes) are unit-tested, including a check that no two touch regions overlap. What
is **not** tested is how it *looks*: text may not sit vertically centred in a
row, exact offsets and the fit of Morrowind's MWUI templates need an on-device
pass. Every `ui.create` is pcall-guarded and the console latches off after one
failure, so a cosmetic problem can never break the director.

---

## 2. Environment-imposed: what this dev host could not do

The machine this was built on is Windows, with no Android NDK, no Gradle, no
native OpenMW build, and no ability to run the game.

**Not done, and why:**

| Item | Blocker |
|---|---|
| Building the Android APK | Needs the NDK toolchain + a 30–60 min native superbuild; no Gradle/NDK present. |
| Un-gating portrait orientation | Needs `AndroidManifest.xml` / OSG changes *and* a device to observe the crash the 2020 note warned about. |
| Isometric camera | Needs OpenMW C++ work (camera/viewport), not Lua. |
| On-device visual tuning of the HUD | Needs the game running. Geometry is unit-tested; cosmetics are not. |
| 30-minute thermal/stability soak | Needs the phone. |

None of that blocks the Lua work, which is why the effort went there: it is the
part that *is* verifiable, and it is the part the Android packaging would just
wrap.

---

## 3. Design limits you should know about

- **Offline progress is a fabrication, by design.** OpenMW does not simulate a
  closed single-player world. The mod awards a bounded, deterministic catch-up
  (`offline.maxRealHours`, default 8) so idling offline is not a strict loss.
  It is deliberately capped to make that explicit.
- **The console covers the lower half of the screen** (~46%; ~30% in MANUAL). That
  is a deliberate trade so the game stays visible above it, and it is
  configurable via the mode, but it *does* mean the lower half of the world is
  hidden while the panel is open. There is no auto-hide or swipe-to-dismiss yet.
- **No occlusion handling.** An isometric/third-person view can be blocked by
  scenery. There is no "fade nearby obstructing objects" shader.
- **Threat model is heuristic.** `combat.assess` uses enemy level counts against
  the character's capability. It will misjudge unusual enemies.
- **NPC hostility is a heuristic, not a fact** — see §1.4a. Creatures are
  enemies by default; NPCs only when you opt in, because the engine cannot tell a
  guard from a bandit.
- **Autonomous travel is OFF by default** (`behaviour.autoTravel`). The 1000-hour
  simulation showed an unbounded travel goal looping degenerately and starving
  training and trading. The console lists destinations so you can order a journey
  deliberately; only the autonomous case is disabled.
- **Directives have a TTL** (default 120 sim-seconds) because there is no
  completion callback from the engine to clear them precisely.

---

## 4. The most valuable next steps

1. **On-device console pass** — verify `ignorePointerEvents`, MWUI template fit,
   tap targets and row text centring on real hardware. The console's geometry and
   interaction model are already tested; only the pixels are unverified.
2. **Faction relations** — `types.NPC.getFactions` / `primaryFaction` exist and
   could sharpen the hostility heuristic beyond "creatures only". Untested
   against real data.
3. **Android build track** — the NDK superbuild, portrait un-gating, and the
   thermal/FPS policy from the original plan (all still valid, all still
   unimplemented here).
