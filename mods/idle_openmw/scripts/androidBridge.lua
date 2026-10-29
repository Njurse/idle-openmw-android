-- scripts/androidBridge.lua
-- PLAYER script: publish game state to the native Android app, and accept its commands.
--
--   .omwscripts declares:  PLAYER: scripts/androidBridge.lua
--
-- WHY THIS IS A SCRIPT AND NOT PART OF THE DIRECTOR
-- The director is the brain and must not grow a UI dependency. This file is the adapter's other
-- half: it reads what the director already computes (`interfaces.IdleOpenMW.panel()`) and hands the
-- app one JSON document through `openmw.android.pushState()`. The SCHEMA lives in
-- scripts/idle/appPayload.lua, which is pure and has a spec; this file only moves bytes.
--
-- THE ONE THING TO KNOW ABOUT THE ENGINE SIDE
-- `openmw.android` is a FORK binding (tools/dev/engine-build/patches/0002-android-bridge.patch,
-- apps/openmw/mwlua/androidbindings.cpp). A stock OpenMW does not have it, and on desktop there is
-- no app to talk to at all -- so the package is probed once, and this script is a no-op without it.
-- That is deliberate: the mod must keep running on a stock engine.

local engine = require('scripts.runtime.engine')
local json = require('scripts.idle.json')
local appPayload = require('scripts.idle.appPayload')

local interfaces = engine.interfaces()

--- How often the state is pushed, in frames rather than seconds: the world can be PAUSED, where dt
--- is 0 every frame, and a paused game is exactly when a watching app wants to be told what is
--- going on (the same reason scripts/idleDirector.lua counts frames for its own polls).
local PUSH_FRAMES = 15

local state = {
  checked = false,
  android = nil,      -- the openmw.android package, when the engine has one
  announced = false,
  pushed = 0,
  commands = 0,
  refused = 0,
  frame = 0,
}

local function idle() return interfaces and interfaces.IdleOpenMW end

local function probe()
  if state.checked then return end
  state.checked = true
  -- pcall because a stock engine does not have the package at all, and require() raising here would
  -- take down a PLAYER script that has nothing to do with the failure.
  local ok, package = pcall(require, 'openmw.android')
  if not ok or type(package) ~= 'table' then
    pcall(print, 'idle-openmw: no openmw.android binding (stock engine, or a build without the fork patch)')
    return
  end
  state.android = package
end

local function available()
  probe()
  local package = state.android
  if not package then return false end
  local ok, value = pcall(package.available)
  return ok and value == true
end

--- Answer whatever the app has asked for. Bounded per frame, so a burst of taps cannot starve the
--- director's own tick: a command that has waited this long is still in the queue for the next frame.
local function pollCommands()
  local api = idle()
  local package = state.android
  if not (api and package and type(api.act) == 'function') then return end

  for _ = 1, 8 do
    local ok, line = pcall(package.pollCommand)
    if not ok or type(line) ~= 'string' or line == '' then return end

    local entry, reason = appPayload.command(line)
    if not entry then
      state.refused = state.refused + 1
      if api.log then pcall(api.log, 'App command refused: ' .. tostring(reason), 'warn') end
    else
      local acted, result = pcall(api.act, entry.action, entry.payload)
      if not (acted and result) then
        state.refused = state.refused + 1
        if api.log then
          pcall(api.log, 'App command ' .. tostring(entry.id) .. ' did nothing', 'warn')
        end
      else
        state.commands = state.commands + 1
      end
    end
  end
end

--- Push the current state. Returns true when the app took it.
local function push()
  local api = idle()
  local package = state.android
  if not (api and package and type(api.panel) == 'function') then return false end

  local okPanel, panel = pcall(api.panel)
  if not okPanel then return false end

  local payload = appPayload.project(panel)
  local okJson, encoded = pcall(json.encode, payload)
  if not okJson or type(encoded) ~= 'string' then return false end

  local okPush, taken = pcall(package.pushState, encoded)
  if okPush and taken then
    state.pushed = state.pushed + 1
    return true
  end
  return false
end

--- The native shell owns the HUD on Android: hide the engine's own (bars, minimap, crosshair) so the
--- viewport is just the 3D view. Chargen dialogs are untouched -- the shell drives those instead.
local function hideNativeHud()
  local Ui = interfaces and interfaces.UI
  if Ui and type(Ui.setHudVisibility) == 'function' then pcall(Ui.setHudVisibility, false) end
end

local function update()
  if not available() then return end

  if not state.announced then
    state.announced = true
    hideNativeHud()
    pcall(print, 'idle-openmw: android bridge attached; pushing state every ' .. PUSH_FRAMES .. ' frames')
  end

  pollCommands()

  state.frame = state.frame + 1
  if state.frame % PUSH_FRAMES == 0 then push() end
end

return {
  engineHandlers = {
    -- onFrame, NOT onUpdate: onUpdate stops while the world is paused, and character creation is
    -- paused -- which left the app on "Waiting for the first tick" through the whole name prompt.
    onFrame = update,
  },
}
