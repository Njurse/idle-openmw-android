# The API schema (v1, frozen)

The data model every bridge response conforms to. `scripts/idle/schema.lua` **is** the
declaration — this page is the prose version, and `{"method":"schema"}` serves the machine
version so a client never has to read our source.

**Version 1. Bump when a field changes meaning.** Adding a new *optional* field does not need
a bump; renaming one does, because the Android layer is written against these names.

## Rules that hold for every field

1. **Field names are engine names where the engine has one** (`recordId`, `isExterior`,
   `gridX`, `enchantmentCharge`). Inventing synonyms for engine concepts is how a data model
   drifts from its source.
2. **`nil` means UNKNOWN, never zero.** A field is omitted when the engine could not tell us.
   A reader must treat absence as "not known", not as "none" — `locked` being absent is not
   the same as a chest being unlocked.
3. **Numbers are Morrowind's own units**: distance in engine units, skills 1..100, dispositions
   0..100, `dynamicStat.current` and `.base` as the engine reports them.
4. **Every response is validated before it is sent** (`schema.validate`), which catches three
   mistakes deliberately: a wrong type, a **field that is not declared** (drift), and a missing
   required field.

## Identity — read this before keying anything

| Field | What it is | Use it for |
|---|---|---|
| `id` | engine `GameObject.id`: "The unique id of this object (not record id), can be used as a key in a table" (core.lua:163) | **the handle.** Unique per instance. |
| `formId` | `core.getFormId(contentFile, index)` (core.lua:143-150) ↔ `world.getObjectByFormId` | a deterministic **cross-save address** of a placed reference |
| `recordId` | the record **template** id (core.lua:177) | type/behaviour lookups — **never identity** |
| `contentFile` | lowercase defining plugin; `nil` for dynamically created objects | provenance |

`recordId` being a template is the trap: three bandits share one, and any client that keys a
map on `recordId` has a bug that only appears when two of them are standing near each other.
`id` and `kind` are the only **required** fields.

## Kinds

| Kind | Context | Notes |
|---|---|---|
| `player` | player | the player character |
| `npc` | global\|player\|local | humanoid; has `disposition` |
| `creature` | global\|player\|local | no disposition, no class |
| `door` | global\|player\|local | carries `destCell` / `destPosition` / `isTeleport` |
| `container` | global\|player\|local | has `inventory`, `capacity` |
| `item` | global\|player\|local | `count`, `condition`, `enchantmentCharge`, `soul` |
| `activator` | global\|player\|local | levers, shrines, signs |
| `cell` | **global** | metadata is cheap; contents are a deliberate, expensive request |
| `record` | global\|player\|local | a template, read per type |

**Context is part of the contract.** `cell` is global-only because `world.cells`,
`cell:getAll()` and `world.activeActors` are global-context calls (world.lua:86, core.lua:337,
world.lua:10) — the bridge's player script cannot serve them, so the global script does.

## Fields, by kind

Shared identity (all object-backed kinds): `id`, `kind`, `formId`, `recordId`, `contentFile`,
`name`, `cell`, `cellId`, `position`, `distance`, `vertical`, `enabled`.

**Actors** (`player`, `npc`, `creature`) add: `level`, `dead`, `health`, `magicka`, `fatigue`
(each a `DynamicStat` `{base, current, modifier}`), `ai` (dispositions `alarm`/`fight`/`flee`/
`hello`), `disposition`, `race`, `class`, `faction`, `factionRank`, `equipment`, `inventory`,
`services` (`servicesOffered`), `travelDestinations`.

**`door`** adds: `destCell`, `destPosition`, `isTeleport`, `locked`.
**`container`** adds: `capacity`, `inventory`, `locked`.
**`item`** adds: `count`, `weight`, `value`, `condition`, `enchantmentCharge`, `soul`.
**`cell`** is metadata only: `id`, `name`, `displayName`, `region`, `isExterior`, `gridX`,
`gridY`, `hasWater`, `waterLevel`, `hasSky`, `worldSpaceId`, plus `contentsFetched` and
`objects`/`doors` **which appear only when contents were deliberately fetched**.
**`record`**: `id`, `recordType`, `name`, `value`, `weight`, `fields`.

## Declared unavailability — what this engine cannot answer

Served in the schema as `unavailable`, so a client sees "unavailable in this engine" instead
of an empty result it might read as "nothing there".

| Capability | Why not |
|---|---|
| `projectiles` | **No API at all.** No `nearby.projectiles`, no `types.Projectile`, no `Projectile` type; the only projectile-related member is the `COLLISION_TYPE.Projectile` bit used as a `castRay` filter (nearby.lua:49,52). A later engine adds an `_onProjectileHit` event, which is a hit notification, not an enumeration. |
| `hostile` / `inCombat` | **No such query.** Use the proxies: `disposition`, the `ai` fight/flee/hello dispositions, `dead`, and npc-vs-creature identity. A boolean `hostile` field would be a lie a client would build on, so the schema refuses to declare one. |
| `aiPackage` | No read API. `interfaces.AI.startPackage` exists (to set one), there is no getter. |
| `statsOfOthers` | `types.Actor.stats` assignment is **self-only**: a global script cannot set another actor's pools and must dispatch `ModifyStat` to that actor. |
| `dialogueTopics` | Dialogue can be **opened** (`interfaces.UI.setMode`) but no topic can be **selected** — the callbacks are internal C++. |
| `cellsInLocal` | Enumeration is global-only, hence the survey runs in the global script. |

## Working with it

- `tests/spec/schema_spec.lua` pins every field name and type, asserts that no kind declares a
  `hostile`/`inCombat` field, and proves `describe()` is deterministic and JSON-round-trips.
- The bridge's `schema` method serves `describe()`, so codegen gets sorted, stable input.
- Add a field by: declaring it in `schema.lua`, using it in `scripts/idle/entity.lua`, and
  letting the validator fail loudly if a caller forgets.

### Remembered records are not entities

`entity.get` answers from the registry (`scripts/idle/registry.lua`), which keeps a **subset**
of an entity's fields so a host can name it in a later request. That subset is deliberately not
a schema kind: it is `id`, `kind`, `formId`, `recordId`, `name`, `list`, the `position` and
`cell` last seen, plus `firstSeen`/`lastSeen`/`seen`. If it were declared as a kind, a host's
codegen would treat a stale remembered position as a current one. So the registry's answer is
declared `free` in the bridge, and the schema makes no promise about it beyond naming its
fields here. A host that needs the truth re-reads the entity.

