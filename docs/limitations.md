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

### 1.4 "Who is a merchant?" is not answerable

OpenMW's Lua API does not expose an NPC's service flags (barter / trainer /
spellmaking / …). So `runtime/observer.lua` takes a pluggable `servicesOf` hook.
Without one, the world scan reports only what it genuinely can detect: people to
talk to, hostiles, containers, and whether the current cell has been visited.

**Consequence.** `shop` / `trainer` / `healer` / `quest` opportunities are only
populated when a service resolver is supplied. A good resolver is the most
valuable next piece of work (§4).

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
- **No occlusion handling.** An isometric/third-person view can be blocked by
  scenery. There is no "fade nearby obstructing objects" shader.
- **Threat model is heuristic.** `combat.assess` uses enemy level counts against
  the character's capability. It will misjudge unusual enemies.
- **`servicesOf` and hostility are pluggable hooks**, so out of the box the mod
  sees "people" and "monsters", not "merchants" and "trainers".
- **Directives have a TTL** (default 120 sim-seconds) because there is no
  completion callback from the engine to clear them precisely.

---

## 4. The most valuable next steps

1. **A service resolver** (`servicesOf`) — inspect `types.NPC.record` /
  class / faction data to identify merchants, trainers and healers. This single
  piece unlocks most of the economy and training behaviour.
2. **Hostility resolver** — the same shape, for `isHostile`. Currently a hook
   with a mock default.
3. **On-device HUD pass** — verify `ignorePointerEvents`, MWUI template usage
  and the tap targets on real hardware.
4. **Android build track** — the NDK superbuild, portrait un-gating, and the
   thermal/FPS policy from the original plan (all still valid, all still
  unimplemented here).
