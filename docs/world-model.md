# The world model, and how it went blind

The director is only as good as the **snapshot** it is handed. This is the story of two
reader bugs that made that snapshot wrong on a *real engine* while every spec stayed green,
plus the two problems still open. It is written down because the class of bug is not fixed
by fixing one instance.

## The trap, restated

Every engine value in OpenMW's Lua API is **userdata, not a table** (`AGENTS.md` #7): a
Vector3, a `DynamicStat`, a record, an `Inventory`, an `ObjectList`. So this:

```lua
if type(value) ~= 'table' then return nil end     -- WRONG for every engine value
```

does not raise. It returns nil, the caller falls back to a default, and the mod keeps
running with a quietly fabricated world. The specs pass because the **mock uses plain
tables** — the mock is not the engine.

## Bug 1 — the player was at the origin

`scripts/runtime/observer.lua:point()` guarded with `type(value) ~= 'table'`. A position is
a **Vector3 userdata**, so `point(self.position)` returned nil and `readPlayer` fell back to
`{ x = 0, y = 0, z = 0 }`. Measured live:

| Reader | Result |
|---|---|
| `self.position` (raw) | `(-12288, -69632, 87.29)` — correct |
| `entities.positionOf(self)` | `(-12288, -69632, 87.29)` — correct |
| `observer.point(self.position)` | `nil` -> snapshot said `(0, 0, 0)` |

Every actor's position went the same way (nil), so **every distance the director computed
was nonsense**: distances to opportunities, arrival checks, flee directions, the threat
map. The director steered from the origin.

## Bug 2 — the nearby lists read as empty

`scripts/runtime/entities.lua:readList/readNearby` guarded with `type(list) == 'table'`.
`nearby.actors` / `.doors` / `.containers` are an **ObjectList userdata**
(`apps/openmw/mwlua/nearbybindings.cpp:197-204`), so all eight lists read as empty and
`entities.nearby` answered `{}`. A live probe of the same engine, from the same list,
reported:

```
nearbyLists: {actors: 41 userdata, doors: 26 userdata, containers: 305 userdata,
              items: 76 userdata, activators: 33 userdata, players: 1 userdata}
```

(note `type(list) == 'userdata'`, and `#list` works — the ObjectList carries `__len`.)

`readList` now walks a list by index (`#` + `[i]`), which goes through `__len`/`__index`
for **both** a userdata and a table, and works where `ipairs` does not: LuaJIT's `ipairs`
is the 5.1 builtin and rejects a userdata outright.

The same guard was in **nine** other observer readers — `dynamicStat` (health/magicka/
fatigue all read as `1/1`), `readEquipped`, `readInventory`, the class record, the journal
and the quest list. All now use `util.isObject`.

## What this changes, and what is still open

These two fixes are in `scripts/runtime/`; the pure brain was never wrong, it was **lied
to**. With them, on the live 0.52 engine, the snapshot position matches the engine and the
list reads are real.

Still open, found by the same probe (recorded, not hidden):

1. **Enemy classification is wrong in a town.** The director reports
   `danger 1.00, 25 hostiles` in Seyda Neen, where every actor is an NPC and NPC hostility
   is opt-in (`sensing.npcFightHostility`, default false). `worldsense.hostile` only calls
   an actor hostile if `isCreature` is true or the opt-in is set, so `isCreature` is coming
   back true for NPCs — `object.type == types.Creature` needs checking against the real
   types table. Until it is fixed the director flees an empty town.
2. **That flee emits nothing.** `goal = flee` with `pending = 0`: no `flee` command is
   produced (there is no `nearest.enemy` position to flee from), so the character stands
   still instead of doing anything. A goal that cannot act must fall through, not idle.

Both are visible in the bridge's `ui` report (`goal`, `goalReason`, `pending`, `moving`) —
which is exactly why those fields exist.

## The lesson that generalizes

Two of this project's own "it works" claims were false on a real engine and true only in
the mock. The mock is a **model**, and a model that uses plain tables for values the engine
sends as userdata will happily agree with a reader that is looking for the wrong shape. So:

- a reader of an engine value is `util.isObject`, never `type(x) == 'table'`;
- `tests/spec/userdata_spec.lua` drives the real code with real userdata (`newproxy`) — the
  `observer.point` regression test FAILS against the old guard and passes against the new;
- the live bridge report (`ui`) is the ground truth, and it should be asked before believing
  a green suite.
