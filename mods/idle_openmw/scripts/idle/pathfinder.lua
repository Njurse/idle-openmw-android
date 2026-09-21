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

--- Total length of a polyline path.
function M.pathLength(points)
  local total = 0
  for i = 2, #(points or {}) do
    total = total + (util.distance(points[i - 1], points[i]) or 0)
  end
  return total
end

--- Steering solution toward a waypoint for one frame.
---
--- OpenMW faces a direction (dx,dy) by turning to atan2(dx, dy)
--- (apps/openmw/mwmechanics/aiface.cpp:17). We mirror that and only walk
--- forward once roughly facing the target, matching the engine's own
--- "turn, then move" behaviour.
---
--- @return { distance, desiredYaw, yawDelta, yawChange, arrived, shouldMove, shouldTurn }
function M.steering(from, to, currentYaw, opts)
  opts = opts or {}
  local arriveTolerance = opts.arriveTolerance or 96
  local moveTolerance = opts.moveYawTolerance or 0.6
  local maxTurn = opts.maxTurn or math.pi

  local dx = (to.x or 0) - (from.x or 0)
  local dy = (to.y or 0) - (from.y or 0)
  local distance = math.sqrt(dx * dx + dy * dy)
  local desiredYaw = atan2(dx, dy)
  local yawDelta = util.angleDelta(currentYaw or 0, desiredYaw)
  local arrived = distance <= arriveTolerance

  return {
    distance = distance,
    desiredYaw = desiredYaw,
    yawDelta = yawDelta,
    yawChange = util.clamp(yawDelta, -maxTurn, maxTurn),
    arrived = arrived,
    shouldMove = (not arrived) and math.abs(yawDelta) <= moveTolerance,
    shouldTurn = math.abs(yawDelta) > 0.05,
  }
end

-- ---------------------------------------------------------------------------
-- Route: a cached, self-healing path to a destination
-- ---------------------------------------------------------------------------

local Route = {}
Route.__index = Route

function M.newRoute(nav, cfg)
  assert(type(nav) == 'table' and type(nav.findPath) == 'function',
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
function Route:setTarget(dest)
  if not dest then self:clear() return false end
  if self.target then
    local drift = util.distance(self.target, dest)
    local slack = (self.cfg.behaviour.repathDistance or 256) * 0.5
    if drift and drift < slack then return false end
  end
  self.target = util.copy(dest)
  self.points = nil
  self.index = 1
  self.lastProgressAt = -math.huge
  self.lastProgressPos = nil
  return true
end

function Route:clear()
  self.target = nil
  self.points = nil
  self.index = 1
  self.pathTarget = nil
  self.lastProgressPos = nil
end

function Route:_repath(position, now)
  local ok, points = self.nav.findPath(position, self.target)
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

  local tolerance = self.cfg.behaviour.arriveTolerance or 96
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
    self:clear()
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
