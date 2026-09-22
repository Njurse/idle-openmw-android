-- scripts/idle/tapMove.lua
-- "I tapped there -- what should happen?" -- PURE.
--
-- HOW A TAP BECOMES A WORLD POSITION
-- ----------------------------------
-- A tap gives a screen point. Turning that into somewhere in the world is the
-- engine's job (idleDirector.pickAt):
--
--   camera.viewportToWorldVector(normalizedPos)  -> a direction through the pixel
--   nearby.castRay(cameraPos, cameraPos + dir*R) -> { hit, hitPos, hitObject }
--
-- (both verified: files/lua_api/openmw/camera.lua:236, nearby.lua:79). The result
-- is a *pick*; this module only decides what a pick MEANS, which is pure logic
-- and therefore fully unit-tested.

local M = {}

--: How far a tap can reach, in engine units. Morrowind's own interaction range is
--: short; this is generous so tapping a distant door still walks you there.
M.MAX_REACH = 4096

--: Stop this far short of a thing you tapped, so "walk to the door" does not
--: mean "walk into the door".
M.STANDOFF = 96

local function point(value)
  if type(value) ~= 'table' then return nil end
  if type(value.x) ~= 'number' or type(value.y) ~= 'number' or type(value.z) ~= 'number' then return nil end
  return { x = value.x, y = value.y, z = value.z }
end

--- Move `hit` toward `from` by `standoff`, so we stop beside the target.
function M.approach(hit, from, standoff)
  hit = point(hit)
  from = point(from)
  if not hit then return nil end
  if not from then return hit end
  standoff = standoff or M.STANDOFF
  local dx, dy, dz = from.x - hit.x, from.y - hit.y, from.z - hit.z
  local len = math.sqrt(dx * dx + dy * dy + dz * dz)
  if len <= standoff or len == 0 then return hit end
  local k = standoff / len
  return { x = hit.x + dx * k, y = hit.y + dy * k, z = hit.z + dz * k }
end

--- What the player meant by tapping a pick.
--- @param pick { hit, position, distance?, kind?, id?, name?, object? }
--- @param player { position }   (the snapshot's player)
--- @param cfg? { maxReach?, standoff? }
--- @return { kind = 'walk'|'enter'|'talk'|'use'|'none', dest?, target?, run?, label?, reason? }
function M.intent(pick, player, cfg)
  cfg = cfg or {}
  local reach = cfg.maxReach or M.MAX_REACH

  if type(pick) ~= 'table' or not pick.hit then
    return { kind = 'none', reason = 'nothing there' }
  end
  local position = point(pick.position)
  if not position then return { kind = 'none', reason = 'nothing there' } end
  if type(pick.distance) == 'number' and pick.distance > reach then
    return { kind = 'none', reason = 'too far away', distance = pick.distance }
  end

  local from = player and player.position
  local dest = M.approach(position, from, cfg.standoff)
  local name = pick.name or pick.id

  if pick.kind == 'door' then
    return { kind = 'enter', dest = dest, target = pick, run = false,
      label = 'enter ' .. tostring(name or 'the door') }
  end
  if pick.kind == 'actor' then
    return { kind = 'talk', dest = dest, target = pick, run = false,
      label = 'walk to ' .. tostring(name or 'them') }
  end
  if pick.kind == 'container' or pick.kind == 'activator' or pick.kind == 'item' then
    return { kind = 'use', dest = dest, target = pick, run = false,
      label = 'walk to ' .. tostring(name or 'it') }
  end

  -- ground / scenery: just walk to where you tapped (no standoff -- you meant
  -- that spot, not a spot beside it)
  return { kind = 'walk', dest = position, run = false, label = 'walk' }
end

--- A one-line description for the log/console.
function M.describe(intent)
  if type(intent) ~= 'table' then return 'nothing' end
  if intent.kind == 'none' then return 'nothing: ' .. tostring(intent.reason or '?') end
  return intent.label or intent.kind
end

return M
