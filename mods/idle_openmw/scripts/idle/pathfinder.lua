-- scripts/idle/pathfinder.lua
-- Route planning + steering. Engineer-agnostic: the navmesh is supplied as a
-- small `nav` port, so this module is fully unit-testable without the engine.
--
-- The real port (see scripts/runtime/engine.lua) wraps `nearby.findPath`, which
-- — per docs/openmw-lua-api.md §3 — returns TWO values `(status, points)`, not a
-- `{status, path}` table.
--
--   nav = { findPath = function(from, to) -> ok:boolean, points:list<{x,y,z}> end }
--
-- Pure: no engine, no I/O.

local util = require('scripts.idle.util')

local M = {}

-- Lua 5.1/LuaJIT expose math.atan2; Lua 5.3+ replaced it with math.atan(y, x).
local function atan2(y, x)
  if math.atan2 then return math.atan2(y, x) end
  return math.atan(y, x)
end

--- Keep at most `max` waypoints (the near ones; the path is ordered start->end).
function M.clampWaypoints(points, max)
  local out = {}
  for i = 1, math.min(#(points or {}), max or 64) do out[i] = points[i] end
  return out
end

--- Which door (if any) is blocking us right now?
---
--- Full pathfinding has to OPEN doors, and the engine's navmesh only *routes through*
--- them: `includeFlags` defaults to `Walk + Swim + OpenDoor + UsePathgrid`
--- (files/lua_api/openmw/nearby.lua:120-124,180-182), so `findPath` will happily return
--- a path that runs straight at a closed door and then the actor walks into it and stops.
--- The missing half is activation, and this is the decision half of it: given the actor's
--- position and the doors the engine sees, which one is close enough AND in front?
---
--- "In front" matters. A door behind us is not in the way, and opening it would be a
--- surprise. The bearing is `atan2(dx, dy)`, the same convention `steering` uses, so the
--- heading it is compared against is the actor's yaw.
---
--- @param position table {x,y,z}
--- @param heading number|nil the actor's yaw (radians)
--- @param doors list list of { position = {x,y,z}, ... } (engine or plain)
--- @param opts table|nil { radius = number, cone = number }
--- @return table|nil the door to open
function M.doorAhead(position, heading, doors, opts)
  opts = opts or {}
  local radius = opts.radius or 128
  local cone = opts.cone or (math.pi / 3)
  local best, bestDistance = nil, math.huge
  for _, door in ipairs(doors or {}) do
    local to = door.position or door
    if to then
      local dx = (to.x or 0) - (position.x or 0)
      local dy = (to.y or 0) - (position.y or 0)
      local distance = math.sqrt(dx * dx + dy * dy)
      if distance <= radius then
        local bearing = atan2(dx, dy)
        if math.abs(util.angleDelta(heading or 0, bearing)) <= cone and distance < bestDistance then
          best, bestDistance = door, distance
        end
      end
    end
  end
  return best, bestDistance
end

--- Total length of a polyline path.
function M.pathLength(points)
  local total = 0
  for i = 2, #(points or {}) do
    total = total + (util.distance(points[i - 1], points[i]) or 0)
  end
  return total
end

--- Steering solution toward a waypoint for one frame.---
--- OpenMW faces a direction (dx,dy) by turning to atan2(dx, dy)
--- (apps/openmw/mwmechanics/aiface.cpp:17). We mirror that and only walk
--- forward once roughly facing the target, matching the engine's own
--- "turn, then move" behaviour.
---
--- @return { distance, desiredYaw, yawDelta, yawChange, arrived, shouldMove, shouldTurn }
--- Steer toward `to`: the turn rate, whether to walk yet, and where to POINT the aim.
---
--- THE ANGLE CONVENTIONS ARE THE ENGINE'S, taken from the very function its own
--- TransformQ:getYaw()/getPitch() call (components/misc/mathutil.hpp:37-41):
---
---     pitch = -asin(forward.z)         yaw = atan2(forward.x, forward.y)
---
--- Note the negation on pitch: a target ABOVE the character is a NEGATIVE pitch. That is the
--- opposite of the intuitive reading, so it is taken from the engine rather than guessed, and it
--- is why an aim that ignores pitch points confidently at the wrong place.
---
--- Why aim is part of STEERING at all: `controls.pitchChange` and `controls.yawChange` are the same
--- kind of value -- per-frame rotation the engine applies to the character -- so they belong in the
--- same solution, computed from the same target.
function M.steering(from, to, currentYaw, opts)
  opts = opts or {}
  local arriveTolerance = opts.arriveTolerance or 96
  local moveTolerance = opts.moveYawTolerance or 0.6
  local maxTurn = opts.maxTurn or math.pi
  local maxPitch = opts.maxPitch or 0.35

  local dx = (to.x or 0) - (from.x or 0)
  local dy = (to.y or 0) - (from.y or 0)
  local dz = (to.z or 0) - (from.z or 0)
  local distance = math.sqrt(dx * dx + dy * dy)
  local desiredYaw = atan2(dx, dy)
  local yawDelta = util.angleDelta(currentYaw or 0, desiredYaw)
  local arrived = distance <= arriveTolerance

  -- vertical aim, in the engine's own convention (see above). A zero-length direction would divide
  -- by zero, hence the floor: the character is never exactly ON the target and the case only
  -- arises at coincident points.
  local span = math.sqrt(distance * distance + dz * dz)
  local desiredPitch = -math.asin(util.clamp(dz / math.max(span, 0.001), -1, 1))
  local currentPitch = opts.currentPitch or 0
  local pitchDelta = util.angleDelta(currentPitch, desiredPitch)

  return {
    distance = distance,
    verticalDistance = dz,
    desiredYaw = desiredYaw,
    yawDelta = yawDelta,
    yawChange = util.clamp(yawDelta, -maxTurn, maxTurn),
    desiredPitch = desiredPitch,
    pitchDelta = pitchDelta,
    pitchChange = util.clamp(pitchDelta, -maxPitch, maxPitch),
    arrived = arrived,
    shouldMove = (not arrived) and math.abs(yawDelta) <= moveTolerance,
    shouldTurn = math.abs(yawDelta) > 0.05,
    shouldAim = math.abs(pitchDelta) > 0.02,
  }
end

-- ---------------------------------------------------------------------------
-- Route: a cached, self-healing path to a destination
-- ---------------------------------------------------------------------------

local Route = {}
Route.__index = Route

function M.newRoute(nav, cfg)
  assert(util.isObject(nav) and type(nav.findPath) == 'function',
    'nav port must expose findPath(from, to)')
  return setmetatable({
    nav = nav,
    cfg = cfg,
    target = nil,
    points = nil,
    index = 1,
    pathAt = -math.huge,
    pathTarget = nil,
    lastProgressAt = 0,
    lastProgressPos = nil,
    repaths = 0,
    failures = 0,
  }, Route)
end

function Route:isActive() return self.target ~= nil end
function Route:waypointCount() return self.points and #self.points or 0 end

--- Point the route at `dest`. Re-targeting the same place is a no-op (returns
--- false) so callers can set the target every tick without thrashing.
function Route:setTarget(dest, opts)
  if not dest then self:clear() return false end
  -- drift is measured against what the caller ASKED for, not where we ended up: an unreachable
  -- target gets snapped onto the navmesh (see _repath), and comparing against the snapped point
  -- would make the caller's next identical order look like a new one and churn every repath.
  if self.requestedTarget then
    local drift = util.distance(self.requestedTarget, dest)
    local slack = (self.cfg.behaviour.repathDistance or 256) * 0.5
    if drift and drift < slack then
      -- same destination: keep the route, but honour a caller that asked for a tighter
      -- arrival ("get within interaction range of that actor") so it is not silently lost
      if opts and opts.arriveTolerance then self.arriveTolerance = opts.arriveTolerance end
      return false
    end
  end
  self.requestedTarget = util.copy(dest)
  self.target = util.copy(dest)
  self.arriveTolerance = (opts and opts.arriveTolerance) or nil
  self.points = nil
  self.index = 1
  self.lastProgressAt = -math.huge
  self.lastProgressPos = nil
  return true
end

function Route:clear()
  self.target = nil
  self.requestedTarget = nil
  self.snapped = nil
  self.points = nil
  self.index = 1
  self.pathTarget = nil
  self.lastProgressPos = nil
  self.arriveTolerance = nil
end

function Route:_repath(position, now)
  -- The FLAGS INTENT travels with the call; the engine port turns it into the `includeFlags`
  -- bitmask (docs/openmw-lua-api.md §3). A port that only reads `(from, to)` ignores the third
  -- argument, which is why the existing specs keep working.
  local opts = {
    doors = self.cfg.behaviour.navOpenDoors ~= false,
    swim = self.cfg.behaviour.navSwim ~= false,
  }
  local ok, points = self.nav.findPath(position, self.target, opts)

  -- If there is no path, the target may simply not be ON the navmesh -- an item on a table, a
  -- shopkeeper behind a counter. Snap it to walkable ground and try ONCE more, then walk to the
  -- snapped point (arrival is measured against `self.target`, which is now reachable). Without
  -- this the move just fails and the goal loops.
  if (not ok or type(points) ~= 'table' or #points == 0) and type(self.nav.snap) == 'function' then
    local snapped = self.nav.snap(self.requestedTarget or self.target)
    if snapped then
      local okSnap, snapPoints = self.nav.findPath(position, snapped, opts)
      if okSnap and type(snapPoints) == 'table' and #snapPoints > 0 then
        self.target = snapped
        self.snapped = true
        ok, points = true, snapPoints
      end
    end
  end

  self.repaths = self.repaths + 1
  if not ok or type(points) ~= 'table' or #points == 0 then
    self.points = nil
    self.failures = self.failures + 1
    return false
  end
  self.points = M.clampWaypoints(points, self.cfg.behaviour.maxPathWaypoints or 64)
  self.index = 1
  self.pathAt = now
  self.pathTarget = util.copy(self.target)
  -- NOTE: deliberately does NOT reset lastProgressAt/lastProgressPos. A repath
  -- must not mask a lack of progress, or a stuck actor would never be detected.
  return true
end

--- Advance the route. Call every tick with the current position and time.
--- @return { status = 'idle'|'moving'|'arrived'|'failed'|'stuck', waypoint=?, index=?, waypointCount=? }
function Route:update(position, now)
  now = now or 0
  if not self.target then return { status = 'idle' } end

  local tolerance = self.arriveTolerance or self.cfg.behaviour.arriveTolerance or 96
  local toTarget = util.distance(position, self.target)
  if toTarget and toTarget <= tolerance then
    self:clear()
    return { status = 'arrived' }
  end

  local ttl = self.cfg.behaviour.pathCacheTtl or 30
  local repathDistance = self.cfg.behaviour.repathDistance or 256
  local drifted = self.pathTarget and util.distance(self.pathTarget, self.target)
  local needRepath = (not self.points)
    or (now - self.pathAt > ttl)
    or (drifted and drifted > repathDistance)
  if needRepath then self:_repath(position, now) end
  if not self.points then return { status = 'failed' } end

  -- consume any waypoints we already stand on
  while self.index <= #self.points
      and (util.distance(position, self.points[self.index]) or 0) <= tolerance do
    self.index = self.index + 1
  end
  if self.index > #self.points then
    local remaining = util.distance(position, self.target)
    self:clear()
    if remaining and remaining > tolerance then
      -- The path is spent but we are still away from the target: it was UNREACHABLE (off the
      -- navmesh, behind a wall), so the path simply ended at the nearest walkable point.
      -- Reporting 'arrived' here is how a move could "succeed" hundreds of units short and
      -- then fire an activation out of range -- the exact failure the target canary catches.
      return { status = 'short', distance = remaining, tolerance = tolerance }
    end
    return { status = 'arrived' }
  end

  -- stuck detection: no meaningful progress within stuckTimeout
  if not self.lastProgressPos
      or (util.distance(self.lastProgressPos, position) or 0) > 8 then
    self.lastProgressAt = now
    self.lastProgressPos = util.copy(position)
  elseif now - self.lastProgressAt > (self.cfg.behaviour.stuckTimeout or 45) then
    self:clear()
    return { status = 'stuck' }
  end

  return {
    status = 'moving',
    waypoint = self.points[self.index],
    index = self.index,
    waypointCount = #self.points,
  }
end

return M
