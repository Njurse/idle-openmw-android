# Pathfinding

How the character gets anywhere, and where "anywhere" currently stops. This is the
**pathfinding AI** `docs/scope.md` names as the first thing to establish.

## The pipeline

```
snapshot.player.position
   -> director.planCommands()        a 'move' command with a dest (PURE)
   -> executor:_startMove()          route:setTarget(dest)      (PURE + engine)
   -> route:update(position, now)    repath / consume waypoints (PURE)
   -> executor:_steer()              self.controls.movement + yawChange (ENGINE)
   -> executor:_openDoorsAhead()     activation for a door in the way (ENGINE)
```

The pure half (`scripts/idle/pathfinder.lua`) never touches the engine. It is handed a small
**nav port** and does all the arithmetic: which waypoint is next, how far off the heading is,
whether the actor has stopped making progress. The engine half is the port itself
(`scripts/idleDirector.lua:makeNavPort`) plus the steering and door activation in
`scripts/runtime/executor.lua`.

## The nav port contract

```lua
nav = {
  findPath = function(from, to, opts) -> ok:boolean, points:list<{x,y,z}> end,
  snap     = function(point) -> {x,y,z}|nil end,   -- optional
}
```

`opts` carries the **intent**, not the engine's wire format: `{ doors = bool, swim = bool }`.
The engine port turns that into the `includeFlags` bitmask
(`Walk + Swim + OpenDoor + UsePathgrid`, `files/lua_api/openmw/nearby.lua:120-124`). A port
that only reads `(from, to)` ignores it, which is why the pure specs use a two-argument port.

`nearby.findPath` returns **two values** `(status, points)` — not a table — and `snap` wraps
`nearby.findNearestNavMeshPosition` for a target that is not on the navmesh at all.

## What "full" means here (and the four things it does)

1. **Route, don't march.** A cached path is consumed waypoint by waypoint, repathed on drift
   (`repathDistance`) or age (`pathCacheTtl`), and clamped to `maxPathWaypoints`.
2. **Reach the target, or say you did not.** A path that ends short of its target is
   **unreachable** and returns `status = 'short'` with the remaining distance — it is **not**
   reported as an arrival. (Reporting `arrived` there is how a move used to "succeed" hundreds
   of units from its destination and then fire an activation out of range.)
3. **Snap, once.** If no path exists, the route asks the port to snap the target onto walkable
   ground and tries again — once — so an item on a table or a shopkeeper behind a counter is
   reachable instead of a failed move that makes the goal loop.
4. **Open the door you are walking into.** `findPath` will happily route *through* a closed
   door (the navmesh allows it); the actor still has to open it. `_openDoorsAhead` activates a
   door that is within `behaviour.doorOpenRadius` **and in front** (the pure decision is
   `pathfinder.doorAhead`). Behind you is not in the way.

Stuck detection is the fifth, and it is deliberately separate: a repath **must not** reset the
stuck timer, or an actor grinding against a wall looks healthy forever.

## What it still does not do (honest)

- **No cross-cell planning.** A move targets something in the *current* cell. Leaving a cell is
  a different mechanism: walk to the door and activate it (`world.exit`, and the ship-hatch path
  in `docs/leaving-the-ship.md`). There is no graph search that chains "door A, then door B,
  then the objective" for an objective in a cell you have never entered. That is the next real
  work, and it needs a door graph the engine does not hand us.
- **Waypoints are capped** at `maxPathWaypoints` (64). A very long route is truncated, not
  failed; the next repath extends it.
- **The navmesh is generated asynchronously** (`docs/openmw-lua-api.md` §3), so a path can fail
  in the first moments after a cell loads. The snap fallback and the repath TTL are what absorb
  that today.
- **Steering is turn-then-walk**, mirroring the engine's own `zTurn`
  (`apps/openmw/mwmechanics/aiface.cpp:17`). It is not a physics controller; it can be blocked
  by geometry the navmesh does not know about.

## Where it is tested

`tests/spec/pathfinder_spec.lua` drives the pure half directly (route, arrival, short, snap,
door-ahead, flags-on-the-wire); `tests/spec/runtime_spec.lua` drives the executor against the
mock engine (steering, arrival release, route failure, and opening a door ahead). The 1000-hour
simulation (`python tools/run_tests.py --sim`) is the invariant net over the whole thing.
