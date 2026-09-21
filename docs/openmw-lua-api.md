# OpenMW Lua API — verified reference (for the idle mod)

Facts below were **verified against actual OpenMW source**, not from memory. Sources are
cited as `path:line` relative to an OpenMW `master` checkout (the repo we cloned into
`.research/openmw/`, commit `3daa5e4`). Where the authoritative docs are not the `.rst`
stubs (those are `.. raw:: html` includes of generated HTML that is not in-tree), the
source of truth is either the annotated API stubs under `files/lua_api/openmw/*.lua`
or the C++ bindings under `apps/openmw/mwlua/`.

> ⚠️ The original project plan contained several **load-bearing errors**. Each is called
> out in a **Correction** block. If you are an agent picking this up: trust this document
> over the plan.

---

## 0. Runtime / version

- `CMakeLists.txt:500` — `option(USE_LUAJIT "Switch Lua/LuaJit (TRUE is highly recommended)" TRUE)`.
  **OpenMW ships LuaJIT (Lua 5.1 semantics) by default.** A non-JIT Lua path exists
  (`-DUSE_LUAJIT=OFF` → Lua 5.4) but is not the default.
- Consequence for tests: write 5.1-compatible Lua. No `goto`, no integer `//`, no
  `table.unpack` (use `unpack`), no `<close>`/`<const>`. Headless tests run under
  LuaJIT 2.1 via `lupa.luajit21` (see `tools/run_tests.py`).

---

## 1. The **player cannot be driven by AI packages** (critical)

> **Correction.** The plan's core mechanism — `AI.startPackage({ type = 'Travel', destination = pos })`
> to walk the auto-playing *player* — is wrong twice over.

- `interfaces.AI` is a **local-script** interface (`files/data/scripts/omw/ai.lua:58,61`).
  `startPackage(options)` dispatches on `options.type` (`ai.lua:9-49`) and throws
  `Unsupported AI Package: <type>` for anything else.
- Only **six** package types are startable: `Combat`, `Pursue`, `Follow`, `Escort`,
  `Wander`, `Travel`. There is **no** `Explore`, `Activate`, `Wait`, or `Sleep` package.
- The Travel field is **`destPosition`**, not `destination`
  (`ai.lua:45-47`; `ai/travel.rst`). `destination` ⇒ `error("destPosition required")`.
- **AI packages cannot be added to the player**: the engine throws
  `Can't add AI packages to player` (`apps/openmw/mwmechanics/aisequence.cpp:389`).

**Therefore the idle director must move the player a different way** (§2), or drive an
*NPC* instead. We move the player.

## 2. How to actually drive the player's movement

`self.controls` is a **struct of fields** (not an object with methods). Setting any field
marks it changed and the engine copies it to movement settings
(`apps/openmw/mwbase/luamanager.hpp:150-163`; `apps/openmw/mwmechanics/actors.cpp:362-409`).

| field | type | meaning |
|---|---|---|
| `movement` | number | `+1` forward, `-1` backward |
| `sideMovement` | number | `+1` right, `-1` left |
| `yawChange` | number (radians) | turn right; negative = left |
| `pitchChange` | number (radians) | look down; negative = up |
| `run` | boolean | run vs walk |
| `sneak` | boolean | sneak |
| `jump` | boolean | jump |

(`files/lua_api/openmw/self.lua:42-48`)

To stop the built-in input script fighting us, use the **player-only `Controls`
interface** (`files/data/scripts/omw/input/playercontrols.lua:264-279`):- `interfaces.Controls.overrideMovementControls(true)` — input no longer touches
  movement/jump/sneak; another script may drive them.
- `interfaces.Controls.overrideCombatControls(true)`, `overrideUiControls(true)`.
- Or `types.Player.setControlSwitch(player, type, value)` for a fuller switch set
  (`files/lua_api/openmw/types.lua:1447-1475`).

`self:enableAI(false)` disables the actor's own AI once a script takes over
(`self.lua:52`; `localscripts.cpp:79`; guards at `actors.cpp:1644-1670`).

**Yaw convention (verified):** the engine faces a direction `(dx, dy)` by turning to
`atan2(dx, dy)` — `MWMechanics::zTurn(actor, std::atan2(dir.x(), dir.y()), …)`
(`apps/openmw/mwmechanics/aiface.cpp:17`, `aiactivate.cpp:40`, `aifollow.cpp:202`).
So a steering controller should compute `desiredYaw = atan2(to.x - from.x, to.y - from.y)`
and drive `yawChange` toward it with `MWMechanics::zTurn`'s per-frame clamp
(`std::min(delta, maxStep)`), moving forward (`movement = 1`) only once roughly facing
the waypoint. This is exactly what `scripts/idle/pathfinder.lua:steering` models.

**Net design:** a PLAYER script steers the player along waypoints with `self.controls`,
where the waypoints come from a navmesh path (§3).

## 3. Pathfinding — `nearby.findPath` returns **two values**

> **Correction.** `findPath` does **not** return `{ status=…, path=… }`. It returns two
> Lua values `(status, path)`. `path.status` does not exist.

`files/lua_api/openmw/nearby.lua:210-222`, C++ `apps/openmw/mwlua/nearbybindings.cpp:242-296`:

```lua
local nearby = require('openmw.nearby')
local status, path = nearby.findPath(source, destination, options)   -- Vector3 in, Vector3 list out
if status == nearby.FIND_PATH_STATUS.Success then
    -- path is a 1-indexed list of Vector3 waypoints
end
```

- `options` keys (all optional): `agentBounds`, `includeFlags`, `areaCosts`,
  `destinationTolerance` (default `1`), `checkpoints`.
- **`includeDoors` / `includeSwim` / `includeWater` do NOT exist.** Doors/swim are expressed
  via the bitmask `includeFlags`:
  `nearby.NAVIGATOR_FLAGS.Walk + .Swim + .OpenDoor + .UsePathgrid`.
- `nearby.findNearestNavMeshPosition(position, options)` snaps a point to walkable ground.
- Doc caveat: *"Result is unstable since navigation mesh generation is asynchronous."*
- `status` is a numeric `FIND_PATH_STATUS` value; compare against the enum table.

Other `nearby` facts that bite an automation mod:
- `nearby.actors` / `.containers` / `.doors` / `.activators` / `.players` / `.items` are
  iterables of **`GameObject`** (not raw tables). There is **no** `nearby.actors(type, …)` form.
- Positions are `Vector3` from `util.vector3(x,y,z)`. **`types.Position` does not exist.**
  Vector3 has `:length()`, `:length2()`, `:normalize()`, `:dot()`, `:cross()`, and `+ - * /`
  operators. There is **no** `:distance()` — use `(a - b):length()` (`util.lua:225-303`).
- Raycast is **`nearby.castRay(from, to, options)`** (and `castRenderingRay`,
  `castNavigationRay`); result fields are `hit`, `hitPos`, `hitNormal`, `hitObject`.
  There is **no** `nearby.raycast` / `util.raycast` / `world.raycast`.

## 4. Dialogue automation is **observe-only** (important scope limit)

> **Correction.** There is **no `onInfoGetText`** handler, and no `onDialogue`/`onTopic`/
> `onPersuasion`/`onDialogueResponse` handler. Grep for `onInfoGetText` across the whole
> engine returns nothing.

- `DialogueResponse` is a **Lua event** delivered to the *player's* local scripts
  (`apps/openmw/mwlua/luamanagerimp.cpp:541-560`, `sendLocalEvent(mPlayer, ...)`).
  Consume it via `eventHandlers`:
  ```lua
  eventHandlers = {
      DialogueResponse = function(e)
          -- e.actor, e.type, e.recordId, e.infoId
      end,
  }
  ```
  `e.type` ∈ `"greeting" | "journal" | "persuasion" | "topic" | "voice"`
  (`luamanagerimp.cpp:547-556`; `events.rst:9-16`).
- The event is **notification-only**: "Event handlers can not return any data to the sender"
  (`overview.rst:483`). You **cannot** programmatically trigger a greeting/topic/persuasion
  response, nor auto-select a dialogue topic.
- What scripts *can* do around dialogue:
  - `player:addTopic(topicId)` — learn a topic keyword (`types.lua:1348-1356`).
  - Read records: `core.dialogue.{journal,topic,greeting,persuasion,voice}.records[...]`.
  - Open/close the UI: `interfaces.UI.setMode('Dialogue', { target = actor })`.
  - `player:addJournalEntry(...)`, `types.Player.quests(player)[id].stage`.
  - Only dialogue-adjacent **handler**: `onQuestUpdate(questId, stage)` (player scripts).

**Design consequence:** "shop by driving the barter menu" and "pick the quest topic" are
**not implementable** as pure Lua automation. The director treats dialogue as an *observer*:
it uses `DialogueResponse` to update its world model (who's talkable, what topics exist)
and otherwise uses engine-level actions (activate a merchant, then react to the event).

## 5. Core modules — exact shapes we use

- `require('openmw.self')` → `self.object` (the GameObject), `self.position` (Vector3),
  `self.rotation` (number), `self.controls`, `self:enableAI(bool)`, `self.cell`, `self.type`,
  `self.recordId`, `self.enabled`.
- `require('openmw.world')`:
  - `world.players` (ObjectList), `world.activeActors` (ObjectList), `world.cells`.
  - `world.createObject(recordId, count)` → GameObject in *disabled* state;
    place with `:teleport(cellName, pos)` or `:moveInto(types.Actor.inventory(actor))`
    (`world.lua:172-185`). Add/remove inventory items this way — `Inventory:add/:remove`
    do **not** exist.
- `require('openmw.storage')`:
  - `storage.globalSection('name')` / `storage.playerSection('name')` → `StorageSection`
    with `:get(key)`, `:set(key, val)`, `:remove(key)`, `:asTable()`, `:reset()`; persists
    across save/load (`storage.lua:32-124`). **Note:** `self.storage` does **not** exist.
- `require('openmw.types')`:
  - `types.Actor.stats.dynamic.health(actor)` → `{ base, current, modifier }`
    (same for `.magicka`, `.fatigue`); `types.Actor.stats.level(actor)` → `{ current, progress, … }`.
  - `types.NPC.stats.skills.<skill>(actor)` → `{ base, damage, modified, modifier, progress }`.
  - `types.NPC.stats.attributes.<attr>(actor)`.
  - `types.Actor.inventory(actor)` → read-only inventory (`:countOf(id)`, `:getAll`, `:find`, …).
  - `types.Player` (player-only helpers incl. `getControlSwitch`/`setControlSwitch`).
- `require('openmw.util')`: `vector2/3/4`, `color`, `clamp(v,lo,hi)`, `remap`,
  `normalizeAngle`, `round`, `bitAnd/bitOr/bitXor/bitNot`, `makeReadOnly`.
- `require('openmw.async')`: register callbacks then schedule timers.
  - `async:registerTimerCallback(name, fn)` → `TimerCallback`
  - `async:newSimulationTimer(delay, cb, arg)` — advances with *simulation* time
    (paused when the game is paused).
  - `async:newGameTimer(delay, cb, arg)` — advances with *game* time (1 game-day per 24 min
    by default), **keeps counting while the world/UI is paused but not while the app is off**.
  - `async:newRealTimeTimer(delay, cb, arg)`, `newUnsavableSimulationTimer/…GameTimer/…RealTimeTimer`.
  - (`async.lua:12-74`) `TimerCallback` handles have `:cancel()`.
- `require('openmw.core')`: `getSimulationTime`, `getGameTime`, `getRealTime`,
  `getRealFrameDuration`, `getSimulationTimeScale`, `isWorldPaused`, `getGMST`,
  `sendGlobalEvent(name, payload)`, `quit`, `l10n`.
  - **Note:** it is `core.sendGlobalEvent`, **not** `core.sendEvent`.
- `require('openmw.input')`: `input.registerAction`, `registerTrigger`,
  `registerTriggerHandler`, `isKeyPressed`, `bindAction`, … (player/menu scripts).
- `require('openmw.ui')` (**`@context menu|player`**): HUD/widget UI is drawn from Lua —
  `ui.create{ layer=…, type=ui.TYPE.Text, props=… }`, `ui.content{…}`, `ui.showMessage`,
  `ui.layers` (incl. `'HUD'`). Morrowind theming via the `MWUI` interface. MyGUI `.layout`
  is a separate native path and is **not** required for Lua HUD widgets.
  UI mode enum is `interfaces.UI.MODE`, **not** `core.UI_MODE`.

## 6. Mod manifest: `.omwscripts`

> **Correction.** Comments are `#`, **not** `--`. There is **no `LOCAL:` flag** and no
> permission/`unsafe` syntax in the manifest.

Grammar (`overview.rst:152-203`; parser `components/lua/configuration.cpp:19-95,230-284`):

```
# lines starting with '#' are comments
GLOBAL: scripts/my_mod/global.lua          # one instance, whole game
PLAYER: scripts/my_mod/player.lua          # auto-attached to the player, `self` = player
NPC, CREATURE: scripts/my_mod/local.lua    # local script on every NPC/creature
CUSTOM: scripts/my_mod/custom.lua          # attachable to any object by a global script
CONTAINER, CUSTOM: scripts/my_mod/box.lua
```

- Flags: `GLOBAL`, `CUSTOM`, `PLAYER`, `MENU`, `LOAD`; plus object-type tags
  `ACTIVATOR ARMOR BOOK CLOTHING CONTAINER CREATURE DOOR INGREDIENT LIGHT MISC_ITEM NPC
  POTION WEAPON APPARATUS LOCKPICK PROBE REPAIR`.
- Path **must** end in `.lua` (case-insensitive) or it is a parse error.
- Line order = script load priority. Several flags may be combined (comma or space), except
  `GLOBAL` cannot be combined with local flags.
- Interfaces are declared **inside the Lua file** (`interfaceName` / `interface` in the
  returned table), not in `.omwscripts` (`overview.rst:407-426`).

Requiring sibling modules uses the **VFS path as the module name**, e.g. a file at
`<mod root>/scripts/idle/foo.lua` is `require('scripts.idle.foo')`
(cf. `files/data/scripts/omw/camera/camera.lua:34-37` → `require('scripts.omw.camera.head_bobbing')`).

## 7. Engine handlers (for a PLAYER script)

- `onUpdate(dt)` — every frame; `dt` = simulation seconds.
- `onLoad(data)` / `onSave()` — persist per-script state (returned table is saved).
- `onNewGame()`, `onPlayerAdded(player)`, `onActive()`, `onInactive()`.
- `onKeyPress(code, modifiers)` / `onKeyRelease`, `onMouseButtonPress`/`Release`,
  `onControllerButtonPress`/`Release`.
- `onConsume(item, actor)`.
- Player-only: `onQuestUpdate(questId, stage)`.
- Note: docs say `onSave`/`onLoad` "shouldn't use `openmw.nearby`" (can run for inactive
  objects) — keep pathfinding out of save/load (`overview.rst:314`).
- `onUiModeChanged` is internal (`_onUiModeChanged`); mods observe the **`UiModeChanged`
  event** with `{ oldMode, newMode, arg }` (`events.rst:180-191`).

## 8. Offline progress

- Real wall-clock time is available as `core.getRealTime()` (seconds since engine start) —
  this resets each launch, so it is **not** usable to measure time-since-last-play.
- For time-since-last-play we need a persisted wall clock. `os.time()` **is** available in
  OpenMW's Lua (LuaJIT exposes `os`), so the mod stores `os.time()` on save/exit and diffs
  it on load. `core.getGameTime()` is game-time and is the wrong axis for "hours you were away".
- The director therefore keeps the elapsed-real-seconds computation in the pure
  `offlineProgress` module and only the *timestamp source* in the runtime adapter.

## 9. World sensing — services, travel, and AI dispositions

Source of truth for `scripts/idle/worldsense.lua`. All verified against the
in-tree stubs and the C++ bindings, not the online docs.

### 9.1 `servicesOffered` exists (this contradicts an earlier claim in this repo)

`NpcRecord.servicesOffered` and `CreatureRecord.servicesOffered` are a
`map<string, boolean>` marking which services the actor provides:

- `files/lua_api/openmw/types.lua:1266` (NPC), `:964` (creature)
- the key set is bound by `MWLua::ServiceNames`, a 19-entry array at
  `apps/openmw/mwlua/types/servicesoffered.hpp:11`, consumed at
  `types/npc.cpp:166` and `types/creature.cpp:92`

The 19 keys are: `Spells, Spellmaking, Enchanting, Training, Repair, Barter,
Weapon, Armor, Clothing, Books, Ingredients, Picks, Probes, Lights, Apparatus,
RepairItem, Misc, Potions, MagicItems`.

**`Travel` is documented in that field's comment but is NOT one of the 19 bound
keys** — a trap. Travel is detected from `travelDestinations` instead
(`types.lua:1267`), which is a `list<TravelDestination>`.

Role mapping used by `worldsense.lua`:

| role | signal |
| --- | --- |
| `shop` | `Barter` |
| `trainer` | `Training` |
| `healer` | `Spells` or `Potions` |
| `repairer` | `Repair` |
| `enchanter` | `Enchanting` or `Spellmaking` |
| `travel` | `#travelDestinations > 0` |
| `questing` | none of the above — a bare "talker" |

### 9.2 AI dispositions

`types.Actor.stats.ai.fight(actor)` / `.alarm` / `.flee` return an `AIStat`,
i.e. `{ base, modified }` where `modified` is "the actor's current ai value
(read-only)" (`types.lua:544`, `:538`, `:550`; field doc near `:507`).

These are **dispositions on a 0..100 scale**, not a hostility flag.

### 9.3 There is no "in combat" / "at war" query

Grepping the entire Lua API and `apps/openmw/mwlua/` for `isInCombat`,
`InCombat`, `inCombat`, `getActorsInCombat` returns **nothing**. Hostility
therefore cannot be read; it must be inferred. See `docs/limitations.md` §1.4a
for the inference actually used and why NPC hostility is opt-in.

### 9.4 Faction data (available, currently unused)

`types.NPC.getFactions(actor)`, `primaryFaction`, `primaryFactionRank` exist and
are the obvious way to sharpen the hostility heuristic beyond "creatures only".
Not yet exercised against real data — listed in `docs/limitations.md` §4.
