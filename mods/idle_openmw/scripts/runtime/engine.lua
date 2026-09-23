-- scripts/runtime/engine.lua
-- The ONLY module that names `openmw.*` packages.
--
-- Everything else in the mod talks to the engine through the `env` table that
-- this module assembles (see scripts/runtime/observer.lua for the contract), or
-- through the helpers here. Keeping the engine surface in one file means the
-- rest of the runtime can be exercised against tests/mocks/openmw.lua.

local M = {}

local cache = {}

--- require() an engine module once, returning nil (not throwing) when the mod
--- is loaded outside OpenMW -- e.g. while running headless tests.
local function engineModule(name)
  if cache[name] == nil then
    local ok, value = pcall(require, name)
    cache[name] = ok and value or false
  end
  return cache[name] or nil
end

--- Forget cached modules (used by tests).
function M.reset() cache = {} end

M.self        = function() return engineModule('openmw.self') end
M.world       = function() return engineModule('openmw.world') end
M.nearby      = function() return engineModule('openmw.nearby') end
M.types       = function() return engineModule('openmw.types') end
M.util        = function() return engineModule('openmw.util') end
M.core        = function() return engineModule('openmw.core') end
M.storage     = function() return engineModule('openmw.storage') end
M.async       = function() return engineModule('openmw.async') end
M.interfaces  = function() return engineModule('openmw.interfaces') end
M.input       = function() return engineModule('openmw.input') end
M.ui          = function() return engineModule('openmw.ui') end
M.camera      = function() return engineModule('openmw.camera') end

--- Is the game world paused? (core.lua:46, "Not available in load scripts".)
--- Worth knowing for its own sake: a paused world takes no input and runs no simulation,
--- so from the outside a paused game and a stuck mod look identical.
function M.isWorldPaused()
  local core = engineModule('openmw.core')
  if not core or type(core.isWorldPaused) ~= 'function' then return nil end
  local ok, paused = pcall(core.isWorldPaused)
  if ok and type(paused) == 'boolean' then return paused end
  return nil
end

--- Read a small UTF-8 text file from the data folder, or nil.
---
--- This is the operator channel: write `narration.txt` next to the mod's data and the
--- HUD shows it, so someone watching a run can narrate what they are doing without
--- touching the mod. `openmw.vfs` is read-only and available in every script context
--- (resources/lua_api/openmw/vfs.lua:4).
--- @param name string VFS path, e.g. 'narration.txt'
--- @param maxBytes number|nil guard against a huge file (default 4096)
function M.readTextFile(name, maxBytes)
  local vfs = engineModule('openmw.vfs')
  if not vfs or type(vfs.open) ~= 'function' then return nil end
  local limit = maxBytes or 4096
  local ok, text = pcall(function()
    local handle = vfs.open(name)
    if not handle then return nil end
    local data = handle:read('*a')
    handle:close()
    return data
  end)
  if not ok or type(text) ~= 'string' then return nil end
  if #text > limit then text = text:sub(1, limit) end
  return text
end
M.markup      = function() return engineModule('openmw.markup') end

--- Assemble the env table the observer/executor consume.
function M.env()
  return {
    self       = M.self(),
    world      = M.world(),
    nearby     = M.nearby(),
    types      = M.types(),
    util       = M.util(),
    core       = M.core(),
    storage    = M.storage(),
    async      = M.async(),
    interfaces = M.interfaces(),
    input      = M.input(),
    ui         = M.ui(),
    -- `openmw.camera` is a PLAYER package (luabindings.cpp:73): the isometric lock
    -- and tap-to-move both need it, and the capability probe checks for it.
    camera     = M.camera(),
  }
end

--- Wall-clock seconds. `os.time()` is available under OpenMW's LuaJIT and is the
--- only axis that measures time-since-last-play (core.getRealTime() resets each
--- launch). See docs/openmw-lua-api.md §8.
--- Seconds, for measuring intervals.
---
--- NEVER returns nil. It did, when the sandbox has no `os.time` (OpenMW's Lua is
--- sandboxed), and callers that subtracted the result threw "attempt to perform
--- arithmetic on a nil value" -- ON EVERY FRAME, inside the update body, which silently
--- stopped the whole director. A clock that returns nothing is a trap; a clock that
--- returns a counter is merely imprecise, and imprecise is recoverable.
function M.wallClock()
  if type(os) == 'table' and type(os.time) == 'function' then
    local ok, seconds = pcall(os.time)
    if ok and type(seconds) == 'number' then return seconds end
  end
  M.clockTicks = (M.clockTicks or 0) + 1
  return M.clockTicks
end

--- True when the wall clock above is real time rather than a fallback counter.
function M.hasRealClock()
  return type(os) == 'table' and type(os.time) == 'function'
end

--- Persisted per-script storage section (survives save/load).
function M.playerStorage(section)
  local storage = M.storage()
  if not storage or type(storage.playerSection) ~= 'function' then return nil end
  return storage.playerSection(section or 'IdleOpenMW')
end

--- Global (per-save, not per-script) storage section.
function M.globalStorage(section)
  local storage = M.storage()
  if not storage or type(storage.globalSection) ~= 'function' then return nil end
  return storage.globalSection(section or 'IdleOpenMW')
end

return M
