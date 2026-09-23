-- scripts/runtime/interact.lua
-- The engine half of "walk up to it, look at it, use it": where the camera is pointed, how far
-- you can reach, and pulling the trigger on an object.
--
-- WHY AIMING IS DONE THROUGH THE **EXTRA** ANGLES
-- The camera's real orientation is `getPitch() + getExtraPitch()` and `getYaw() + getExtraYaw()`
-- (openmw/camera.lua documents both). Base pitch/yaw is what the game itself is driving --
-- including our own isometric lock (scripts/idle/camera.lua), which sets the base pose every
-- tick. If aiming wrote the BASE angles, the isometric lock would fight it and the camera would
-- twitch; and with `setMode` no-oping on an unchanged mode (apps/openmw/mwrender/camera.cpp:218)
-- there is nothing to synchronise against.
--
-- So aim writes the DIFFERENCE into the extra angles. That composes with whatever the base pose
-- is -- isometric, third person, first person -- and it is the difference that matters for
-- "point the view at that hatch". Note the engine clamps pitch to a limit
-- (apps/openmw/mwrender/camera.cpp:328), so a very steep look can come back short, which is why
-- the aim is VERIFIED rather than assumed.
--
-- AND WHY VERIFICATION USES THE ENGINE'S OWN VIEW DIRECTION
-- The obvious check -- "did the ray I aimed hit the target?" -- proves nothing when the ray is
-- built from the same angles I just set. So the check asks the ENGINE where it is looking
-- (`camera.viewportToWorldVector(0.5, 0.5)`, the crosshair ray the mod already uses for
-- `ui.target`) and fires that. No convention is assumed on either side.

local engine = require('scripts.runtime.engine')
local util = require('scripts.idle.util')
local aim = require('scripts.idle.aim')

local M = {}

--- How far ahead to cast when checking where the camera ended up looking. Generous, because
--- this ray is only asking "is the thing I am aiming at in the middle of the screen?".
M.CHECK_REACH = 4096

--- How far off the desired angle is still "pointed at it", in radians (about a degree).
M.AIM_TOLERANCE = 0.02

--- A Vector3 (engine userdata) as a plain table. nil for a partial read, matching
--- entities.positionOf: half a position produces confident nonsense.
function M.point(value)
  if not util.isObject(value) then return nil end
  local out = nil
  pcall(function() out = { x = value.x, y = value.y, z = value.z } end)
  if out and (out.x == nil or out.y == nil or out.z == nil) then return nil end
  return out
end

--- How close the player must be for an object to be usable.
---
--- This is a GAME SETTING (`iMaxActivateDist`), read by the engine at
--- apps/openmw/mwworld/worldimp.cpp:890, which means a mod can change it. So it is read, never
--- assumed -- and the documented default is only a fallback for when the read fails.
function M.reach(env)
  env = env or engine.env()
  local core = env.core
  if core and type(core.getGMST) == 'function' then
    local ok, value = pcall(core.getGMST, 'iMaxActivateDist')
    if ok then
      local number = tonumber(value)
      if number and number > 0 then return number end
    end
  end
  return aim.DEFAULT_REACH
end

--- Where the camera actually is -- the eye a ray should start from.
function M.eye(env)
  env = env or engine.env()
  local camera = env.camera
  if not camera or type(camera.getPosition) ~= 'function' then return nil end
  local ok, position = pcall(camera.getPosition)
  if not ok then return nil end
  return M.point(position)
end

--- Which way the camera is actually looking, according to the engine.
--- @return table|nil unit direction
function M.viewDirection(env)
  env = env or engine.env()
  local camera = env.camera
  if not camera or type(camera.viewportToWorldVector) ~= 'function' then return nil end
  local ok, direction = pcall(camera.viewportToWorldVector, 0.5, 0.5)
  if not ok then return nil end
  return M.point(direction)
end

--- What the crosshair is on right now, as an engine object (or nil).
---
--- Deliberately NOT the mod's `ui.target`: this is the low-level check, used to confirm an aim
--- landed on the object we meant.
function M.crosshairObject(env, eye, ignore)
  env = env or engine.env()
  local nearby = env.nearby
  local from = eye or M.eye(env)
  local direction = M.viewDirection(env)
  if not (nearby and type(nearby.castRay) == 'function' and from and direction) then return nil end

  local to = {
    x = from.x + direction.x * M.CHECK_REACH,
    y = from.y + direction.y * M.CHECK_REACH,
    z = from.z + direction.z * M.CHECK_REACH,
  }
  local hit = nil
  pcall(function()
    local result = nearby.castRay(from, to, { ignore = ignore })
    if result and result.hit and result.hitObject then hit = result.hitObject end
  end)
  return hit
end

--- The engine object's id, for comparing two of them. Engine objects have no usable `==` from
--- Lua, so identity comparisons go through this.
function M.objectId(object)
  if not util.isObject(object) then return nil end
  local id = nil
  pcall(function() id = object.id end)
  if type(id) == 'string' then return id end
  return nil
end

--- Read the camera's full angles back (base + extra).
function M.angles(env)
  env = env or engine.env()
  local camera = env.camera
  if not camera then return nil end
  local function read(name)
    if type(camera[name]) ~= 'function' then return nil end
    local ok, value = pcall(camera[name])
    if not ok then return nil end
    return tonumber(value)
  end
  local pitch, extraPitch = read('getPitch'), read('getExtraPitch')
  local yaw, extraYaw = read('getYaw'), read('getExtraYaw')
  return {
    pitch = pitch, extraPitch = extraPitch,
    yaw = yaw, extraYaw = extraYaw,
    fullPitch = (pitch or 0) + (extraPitch or 0),
    fullYaw = (yaw or 0) + (extraYaw or 0),
  }
end

--- Write the EXTRA angles so the camera's full orientation points at `point`.
---
--- @param env table
--- @param point table { x, y, z } the thing to look at
--- @param options table|nil { upSign = 1|-1, eye = table }
--- @return table { ok, desiredYaw, desiredPitch, appliedYaw, appliedPitch, verified, reason }
function M.aimAt(env, point, options)
  env = env or engine.env()
  options = options or {}
  local camera = env.camera
  local canExtra = camera and type(camera.setExtraPitch) == 'function'
  local canBase = camera and type(camera.setPitch) == 'function'
  if not (canExtra or canBase) then
    return { ok = false, reason = 'openmw.camera cannot be aimed in this build' }
  end

  local eye = options.eye or M.eye(env)
  if not (eye and point) then return { ok = false, reason = 'no eye or no target position' } end

  local plan = aim.plan(eye, point, options.upSign or 1)
  if not plan then return { ok = false, reason = 'could not compute an angle to that point' } end

  local before = M.angles(env) or {}
  local ok = true
  pcall(function()
    if canExtra then
      -- full = base + extra, so the extra we want is the difference between the pose we want and
      -- the pose the game is already holding. This composes with the isometric lock instead of
      -- fighting it.
      camera.setExtraPitch(plan.pitch - (before.pitch or 0))
      camera.setExtraYaw(plan.yaw - (before.yaw or 0))
    else
      -- an engine without the extra angles: write the absolute pose. Recorded rather than
      -- assumed, because a fallback that is wrong is worse than one that is absent.
      camera.setPitch(plan.pitch)
      if type(camera.setYaw) == 'function' then camera.setYaw(plan.yaw) end
    end
  end)
  local method = canExtra and 'extra' or 'base'

  local after = M.angles(env) or {}
  local offPitch = math.abs((after.fullPitch or 0) - plan.pitch)
  local offYaw = math.abs((after.fullYaw or 0) - plan.yaw)
  -- the engine clamps pitch, so a steep look can land short; that is reported, not hidden
  local clamped = offPitch > M.AIM_TOLERANCE

  return {
    ok = ok,
    method = method,
    desiredPitch = plan.pitch, desiredYaw = plan.yaw,
    appliedPitch = after.fullPitch, appliedYaw = after.fullYaw,
    offPitch = offPitch, offYaw = offYaw,
    clamped = clamped,
    above = plan.above,
    distance = plan.distance,
  }
end

--- Is the camera now pointing at `object`? Asks the engine where it looks, then casts that ray.
--- @param object engine GameObject
--- @return boolean looking, table|nil whatWasHit
function M.isLookingAt(env, object, options)
  options = options or {}
  local eye = options.eye or M.eye(env)
  local hit = M.crosshairObject(env, eye, options.ignore)
  local hitId = M.objectId(hit)
  local wantId = M.objectId(object)
  if not hitId or not wantId then return false, hit end
  return hitId == wantId, hit
end

--- Try to aim at an object, verifying with a ray, and flipping the pitch convention ONCE if the
--- first attempt looks the wrong way vertically.
---
--- The flip exists because the pitch sign is inferred from the camera quaternion order rather
--- than from a line of documented intent (see scripts/idle/aim.lua). One correction, then it
--- gives up and says so -- an endless flip-flop would be worse than an honest failure.
--- @return table { verified, attempts, upSign, reason }
function M.aimAndVerify(env, object, point, options)
  options = options or {}
  local attempts = 0
  local lastTrace = nil

  for _, upSign in ipairs({ 1, -1 }) do
    if options.upSign and options.upSign ~= upSign then
      -- a caller that already knows the convention only gets that one try
    else
      attempts = attempts + 1
      local trace = M.aimAt(env, point, { upSign = upSign, eye = options.eye })
      trace.upSign = upSign
      lastTrace = trace
      if trace.ok then
        local looking = M.isLookingAt(env, object, { eye = options.eye, ignore = options.ignore })
        if looking then
          trace.verified = true
          trace.attempts = attempts
          return trace
        end
      end
    end
  end

  if lastTrace then
    lastTrace.verified = false
    lastTrace.attempts = attempts
    lastTrace.reason = lastTrace.reason
      or 'the ray did not land on the target in either pitch convention'
    return lastTrace
  end
  return { verified = false, attempts = attempts, reason = 'aiming is unavailable in this build' }
end

--- Use an object: `object:activateBy(actor)` (openmw/core.lua:205).
---
--- This is the Lua route to the engine's own activation (which internally is
--- `LuaManager::objectActivated`, the same call the Activate AI package makes --
--- apps/openmw/mwmechanics/aiactivate.cpp:57). For a teleport door, activation is what moves the
--- actor, so this single call is the whole of "open the hatch and step out".
---
--- @return table { ok, reason }
function M.activate(env, object, actor)
  env = env or engine.env()
  if not util.isObject(object) then return { ok = false, reason = 'no object to activate' } end
  if type(object.activateBy) ~= 'function' then
    return { ok = false, reason = 'this object cannot be activated from Lua' }
  end
  actor = actor or env.self
  if not util.isObject(actor) then return { ok = false, reason = 'no actor to activate with' } end

  local ok, err = pcall(function() object:activateBy(actor) end)
  if not ok then return { ok = false, reason = tostring(err) } end
  return { ok = true }
end

--- A one-line description of an aim result, for the log and the narration.
function M.describeAim(trace)
  if type(trace) ~= 'table' then return 'no aim result' end
  if trace.verified then
    local where = trace.above and 'up at' or 'down at'
    return string.format('looking %s it (%.0f away, %d attempt(s))',
      where, trace.distance or 0, trace.attempts or 1)
  end
  return 'could not get it in the crosshair: ' .. tostring(trace.reason or 'unknown')
end

return M
