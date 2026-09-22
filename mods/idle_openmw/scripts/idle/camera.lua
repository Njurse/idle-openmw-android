-- scripts/idle/camera.lua
-- Pure plan for an *isometric* camera lock.
--
-- WHY THIS IS PURE LUA, NOT A C++ PATCH
-- ------------------------------------
-- The original plan filed "isometric camera" under "needs OpenMW C++ work"
-- (docs/plan-reconciliation.md phase 2), on the assumption that the camera was
-- out of reach. It is not: `openmw.camera` is one of the packages handed to a
-- PLAYER script (apps/openmw/mwlua/luabindings.cpp:73), and it exposes exactly
-- the controls an isometric lock needs
-- (apps/openmw/mwlua/camerabindings.cpp:28):
--
--   camera.MODE            Static/FirstPerson/ThirdPerson/Vanity/Preview
--   camera.setMode(mode)   switch view
--   camera.setPitch(rad)   lock the vertical angle   (forced -> sticky)
--   camera.setYaw(rad)     lock the horizontal angle (forced -> sticky)
--   camera.setPreferredThirdPersonDistance(u)
--
-- "Forced" matters: `Camera::setPitch(angle, force)` sets `mLockPitch` when
-- forced (mwrender/camera.cpp:320), so one forced set latches the angle and the
-- game's own look controls stop moving it -- a *lock*, which is what an idle
-- game wants. A third-person camera at a fixed, steep pitch and a long distance
-- is the classic isometric read.
--
-- This module only computes the *plan*; scripts/idleDirector.lua applies it
-- through `openmw.camera`. Keeping the numbers here means they are unit-tested
-- and tunable from config without an engine.
--
-- WHAT THIS DELIBERATELY DOES NOT DO (the honest limit)
-- ----------------------------------------------------
-- It cannot hide the world's roofs and ceilings. An overhead view of Morrowind
-- looks through building interiors and under doorframes, and "backface culling"
-- does not fix that -- the occluders are fronts, not backs, and OpenMW already
-- culls back faces (components/sceneutil/mwshadowtechnique.cpp:1681). Hiding
-- them from an overhead camera is rendering-layer work in the engine, not a
-- data or Lua change. See docs/isometric.md.

local M = {}

M.RAD = math.pi / 180

--: -35 degrees: the classic 2:1 isometric tilt, and steep enough to read the
--: ground while still showing the character's back.
M.DEFAULT_PITCH = -35 * M.RAD
M.DEFAULT_DISTANCE = 640

M.MIN_DISTANCE = 64
M.MAX_DISTANCE = 8192

local function num(value, fallback)
  if type(value) == 'number' then return value end
  return fallback
end

--- Decide whether -- and how -- to lock the camera this tick.
--- @param input {
---   cfg?    table,   -- the live config's `camera` section
---   phase?  string,  -- scripts/idle/lifecycle.lua phase id
---   manual? boolean, -- is the human driving?
--- }
--- @return { apply = boolean, reason? = string, pitch?, distance?, yaw? }
function M.plan(input)
  input = input or {}
  local cfg = input.cfg or {}

  if cfg.isometric ~= true then
    return { apply = false, reason = 'isometric camera is off' }
  end
  -- Never touch the camera outside the world: character creation and the load
  -- screen drive the camera themselves and a forced pitch would derail them.
  if input.phase ~= 'world' then
    return { apply = false, reason = 'not in the world yet' }
  end
  -- In manual play the human owns the camera; we must not fight their look.
  if input.manual and cfg.inManual ~= true then
    return { apply = false, reason = 'manual play owns the camera' }
  end

  local pitch = num(cfg.pitch, M.DEFAULT_PITCH)
  local distance = num(cfg.distance, M.DEFAULT_DISTANCE)
  if distance < M.MIN_DISTANCE then distance = M.MIN_DISTANCE end
  if distance > M.MAX_DISTANCE then distance = M.MAX_DISTANCE end

  local plan = { apply = true, pitch = pitch, distance = distance }
  -- Optional fully-fixed orientation. Left nil by default so the camera keeps
  -- following the character's heading; set camera.yaw (radians) for a heading-
  -- independent lock.
  if type(cfg.yaw) == 'number' then plan.yaw = cfg.yaw end
  return plan
end

return M
