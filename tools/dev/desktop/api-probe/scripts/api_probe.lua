-- tools/dev/desktop/api-probe/scripts/api_probe.lua
-- Dump what THIS engine's Lua API actually exposes, at the main menu.
--
-- WHY A MENU SCRIPT
-- -----------------
-- A PLAYER script only ticks once a game is loaded, so it cannot tell us anything
-- about an engine from the main menu -- and reaching a loaded game needs a whole
-- controlled character (Phase 3). A MENU script runs immediately, so this probe
-- reports an engine's real API surface in seconds, before any gameplay: it is how
-- the supported-engine floor in docs/openmw-lua-api.md gets its evidence instead
-- of a guess.
--
-- It prints ONE line, prefixed API_PROBE, so a grep finds it:
--
--   API_PROBE rev=128 camera=yes pick=yes chargen=yes uistack=yes journal=yes ...
--
-- Every probe is pcall-guarded: this runs on engines whose API is exactly what we
-- are trying to measure, so it must never throw.

local M = {}

local function has(tbl, key, kind)
  if type(tbl) ~= 'table' then return false end
  local value = tbl[key]
  if kind then return type(value) == kind end
  return value ~= nil
end

local function safeRequire(name)
  local ok, module = pcall(require, name)
  if ok then return module end
  return nil
end

local function yes(value) return value and 'yes' or 'no' end

function M.report()
  local core = safeRequire('openmw.core')
  local ui = safeRequire('openmw.ui')
  local types = safeRequire('openmw.types')
  local nearby = safeRequire('openmw.nearby')
  local camera = safeRequire('openmw.camera')
  local interfaces = safeRequire('openmw.interfaces')

  local revision = 'n/a'
  if core then
    local ok, value = pcall(function() return core.API_REVISION end)
    if ok and value ~= nil then revision = tostring(value) end
  end

  local controls = interfaces and interfaces.Controls or nil

  local parts = {
    'API_PROBE',
    'rev=' .. revision,
    'core=' .. yes(core ~= nil),
    'ui=' .. yes(ui ~= nil),
    'types=' .. yes(types ~= nil),
    'nearby=' .. yes(nearby ~= nil),
    'camera=' .. yes(camera ~= nil),
    'interfaces=' .. yes(interfaces ~= nil),
    -- the modern capabilities the mod depends on
    'pick=' .. yes(has(camera, 'viewportToWorldVector', 'function')),
    'campos=' .. yes(has(camera, 'getPosition', 'function')),
    'rendray=' .. yes(has(camera, 'castRenderingRay', 'function')),
    'castray=' .. yes(has(nearby, 'castRay', 'function')),
    'chargen=' .. yes(has(types and types.Player, 'isCharGenFinished', 'function')),
    'journal=' .. yes(has(types and types.Player, 'journal', 'function')),
    'uistack=' .. yes(has(ui, '_getUiModeStack', 'function')),
    'settings=' .. yes(has(ui, 'registerSettingsPage', 'function')),
    'gmst=' .. yes(has(core, 'getGMST', 'function')),
    'ctrloverride=' .. yes(has(controls, 'overrideMovementControls', 'function')),
  }

  return table.concat(parts, ' ')
end

local function emit()
  local ok, line = pcall(M.report)
  if not ok then line = 'API_PROBE FAILED ' .. tostring(line) end
  -- Both channels on purpose: print() goes to the in-game console/engine log on
  -- some builds, printToConsole() on others, and we do not yet know which this is.
  pcall(print, line)
  local ui = safeRequire('openmw.ui')
  if ui and type(ui.printToConsole) == 'function' then pcall(ui.printToConsole, line) end
end

return {
  engineHandlers = {
    onInit = emit,
    onFrame = emit,
  },
}
