-- scripts/idle/aim.lua
-- Where to look, and how close is close enough -- the two bits of geometry the mod needs to
-- walk up to a door and USE it.
--
-- THE YAW CONVENTION IS THE ENGINE'S, NOT A GUESS
-- The engine's own "walk to it and activate it" package computes the facing like this
-- (apps/openmw/mwmechanics/aiactivate.cpp:44, and identically in aiface.cpp:17):
--
--     zTurn(actor, std::atan2(targetDir.x(), targetDir.y()), 0.f);
--
-- So **yaw = atan2(dx, dy)** -- x first. Note that this is NOT the usual math convention
-- (atan2(y, x)); getting it wrong makes the actor walk sideways while looking at the target.
--
-- The pitch convention is measured rather than assumed: the camera orientation is built as
-- `Quat(pitch, X) * Quat(yaw, Z)` (apps/openmw/mwrender/camera.cpp:198), which puts positive
-- pitch as "up". Because that is an inference from a quaternion rather than a line of intent,
-- the runtime VERIFIES the aim with a ray and flips the sign if the ray disagrees -- see
-- scripts/runtime/interact.lua. A wrong guess must not be able to make the actor stare at its
-- own feet forever.
--
-- PURE -- plain tables in, plain tables out. No engine, no clock.

local M = {}

--- The engine default for `iMaxActivateDist`, used only if the GMST cannot be read. The real
--- value is a game setting (apps/openmw/mwworld/worldimp.cpp:890 reads it), which means it is
--- moddable and therefore NOT a constant: read it, do not assume it.
M.DEFAULT_REACH = 128

--- Distance at which walking to a target counts as arrived. Slightly INSIDE the reach, so the
--- actor stops before it is already close enough (otherwise it stutters on the boundary).
M.ARRIVE_MARGIN = 0.9

--- atan2 that works everywhere this mod runs. LuaJIT and Lua 5.1 have math.atan2 with TWO
--- arguments; Lua 5.4 removed it in favour of math.atan(y, x) with two. Both are needed because
--- the suite runs on 5.1, LuaJIT and 5.4 (`python tools/run_tests.py --all`).
local function atan2(y, x)
  if math.atan2 then return math.atan2(y, x) end
  return math.atan(y, x)
end
M.atan2 = atan2

function M.distance(a, b)
  if type(a) ~= 'table' or type(b) ~= 'table' then return nil end
  local dx = (a.x or 0) - (b.x or 0)
  local dy = (a.y or 0) - (b.y or 0)
  local dz = (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Horizontal distance only -- what decides whether a look is steep or shallow.
function M.planarDistance(a, b)
  if type(a) ~= 'table' or type(b) ~= 'table' then return nil end
  local dx = (a.x or 0) - (b.x or 0)
  local dy = (a.y or 0) - (b.y or 0)
  return math.sqrt(dx * dx + dy * dy)
end

--- The yaw that faces `to` from `from`, in the engine's convention (atan2(dx, dy)).
function M.yawTo(from, to)
  if type(from) ~= 'table' or type(to) ~= 'table' then return nil end
  return atan2((to.x or 0) - (from.x or 0), (to.y or 0) - (from.y or 0))
end

--- The pitch that puts `to` in the centre of the view from `from`. Positive is up, per the
--- camera's own quaternion order; the runtime checks this against a ray.
--- @param upSign number +1 or -1, to flip the convention once it has been measured
function M.pitchTo(from, to, upSign)
  if type(from) ~= 'table' or type(to) ~= 'table' then return nil end
  local planar = M.planarDistance(from, to)
  local dz = (to.z or 0) - (from.z or 0)
  local sign = upSign or 1
  -- straight up or straight down has no meaningful yaw, and atan2(0,0) is 0, which is fine
  return sign * atan2(dz, planar == 0 and 0.0001 or planar)
end

--- Everything needed to aim at a point: the angles, and how far away it is.
function M.plan(from, to, upSign)
  if type(from) ~= 'table' or type(to) ~= 'table' then return nil end
  return {
    yaw = M.yawTo(from, to),
    pitch = M.pitchTo(from, to, upSign),
    distance = M.distance(from, to),
    planar = M.planarDistance(from, to),
    -- whether the target is above or below, which is the part a player asks about ("look UP")
    above = (to.z or 0) > (from.z or 0),
  }
end

--- Is `distance` within activation reach? `reach` defaults to the documented fallback.
function M.inReach(distance, reach)
  if type(distance) ~= 'number' then return false end
  return distance <= (reach or M.DEFAULT_REACH)
end

--- Is `a` the same object as `b` for our purposes?
---
--- Comparing engine objects directly is not safe (no equality operator is exposed to Lua), so
--- identity is an id string or a record id, which is what the engine hands us anyway.
function M.sameTarget(a, b)
  if type(a) ~= 'table' or type(b) ~= 'table' then return false end
  if a.id ~= nil and b.id ~= nil then return a.id == b.id end
  return a.recordId ~= nil and a.recordId == b.recordId
end

--- Pick the door to leave by.
---
--- Preference order, and why:
---   1. a door under the crosshair (the player is already looking at it -- respect that);
---   2. a TELEPORT door, nearest first: in Morrowind only teleport doors move you between
---      cells, so an ordinary door inside the ship is not an exit;
---   3. failing that, the nearest door of any kind, because opening it is still progress.
---
--- @param doors table list of schema door entities (each with position, distance, id, isTeleport)
--- @param reach number|nil activation reach
--- @param playerPosition table|nil used only to fill in a missing per-door distance
--- @return table|nil chosen door, string reason
function M.chooseExit(doors, reach, playerPosition)
  if type(doors) ~= 'table' or #doors == 0 then return nil, 'no doors nearby' end

  local best, bestDistance = nil, nil
  local teleport, teleportDistance = nil, nil
  local looked, lookedDistance = nil, nil

  for _, door in ipairs(doors) do
    if door.position then
      -- the entity reader fills `distance` in when it knows where the player is; if it did not,
      -- work it out rather than treating an unknown distance as zero (which would make the
      -- furthest door look nearest)
      local away = door.distance
      if away == nil and playerPosition then away = M.distance(playerPosition, door.position) end

      if door.hit == true then
        if lookedDistance == nil or (away or 0) < lookedDistance then looked, lookedDistance = door, away or 0 end
      end
      if door.isTeleport == true then
        if teleportDistance == nil or (away or 0) < teleportDistance then
          teleport, teleportDistance = door, away or 0
        end
      end
      if bestDistance == nil or (away or 0) < bestDistance then best, bestDistance = door, away or 0 end
    end
  end

  if looked then return looked, 'the door under the crosshair' end
  if teleport then
    local why = 'the nearest teleport door'
    if reach and M.inReach(teleportDistance, reach) then why = why .. ' (already in reach)' end
    return teleport, why
  end
  if best then return best, 'the nearest door (not a teleport one)' end
  return nil, 'no door with a known position'
end

--- The next thing to do about a target: walk, look, or use.
---
--- Kept separate from the doing so the decision is testable and the narration can say what it
--- decided and why ("closing to 84 of 128", "looking up at the hatch").
---
--- The order matters and is the whole point of "pathfind close enough to interact, THEN look":
--- a ray aimed from four metres away hits a wall, so looking only makes sense once we are close.
---
--- @param options table|nil { aimed = boolean, upSign = number }
--- @return table { step = 'move'|'aim'|'activate'|'none', reason, distance, reach, plan }
function M.step(target, playerPosition, reach, options)
  options = options or {}
  reach = reach or M.DEFAULT_REACH
  if type(target) ~= 'table' or not target.position then
    return { step = 'none', reason = 'target has no position' }
  end
  if type(playerPosition) ~= 'table' then
    return { step = 'none', reason = 'no player position' }
  end

  local away = M.distance(playerPosition, target.position)
  local plan = M.plan(playerPosition, target.position, options.upSign)

  if not M.inReach(away, reach) then
    return {
      step = 'move',
      reason = string.format('%.0f away, reach is %.0f', away, reach),
      distance = away, reach = reach, plan = plan,
    }
  end
  -- in reach, but not yet pointed at it: this is the step a hand-played game calls "look up at
  -- the hatch and press Space"
  if options.aimed ~= true then
    return {
      step = 'aim',
      reason = string.format('%.0f away, within reach %.0f, not aimed yet', away, reach),
      distance = away, reach = reach, plan = plan,
    }
  end
  return {
    step = 'activate',
    reason = string.format('%.0f away, within reach %.0f and aimed', away, reach),
    distance = away, reach = reach, plan = plan,
  }
end

return M
