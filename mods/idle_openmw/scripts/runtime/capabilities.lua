-- scripts/runtime/capabilities.lua
-- Ask the engine what it can actually do, instead of assuming.
--
-- WHY THIS EXISTS
-- ---------------
-- The mod was written against one engine and run against another, and the gap is
-- real: OpenMW 0.48.0 has none of `types.Player.isCharGenFinished`,
-- `ui._getUiModeStack`, `servicesOffered` or `journal().topics`, while 0.49+ has
-- them all. Every one of those calls is pcall-guarded, so the mod keeps running on
-- an older engine -- but *silently*: the chargen gate stops gating, the UI hook
-- stops reporting, service detection stops detecting, and nothing says so.
--
-- So we probe once per session and say so, loudly, in the log. The engine's own
-- Lua API version is the anchor:
--
--   core.API_REVISION  -- "an integer that is incremented every time the API is
--                         changed" (files/lua_api/openmw/core.lua:11;
--                         mwlua/corebindings.cpp:81 -> Version::getLuaApiRevision,
--                         set from CMakeLists.txt)
--
-- Everything else is probed structurally (does the function/table exist), which is
-- cheap and cannot throw. This module takes the injected `env`, so it is testable
-- against tests/mocks/openmw.lua like the rest of the runtime.

local M = {}

--- Feature -> how to tell whether this engine has it.
--- Each probe gets `env` and returns a boolean; nothing here may throw.
M.FEATURES = {
  -- Character creation can be detected, so the director can hold fire through it
  -- (scripts/idle/lifecycle.lua). Without it the mod cannot know, and may drift
  -- into driving a character that is still being created.
  charGenFlag = function(env)
    -- NOTE: engine packages are USERDATA on 0.51, never tables. Probe truthiness and
    -- the member's type -- never the container's (that mistake made this report
    -- "MISSING 10/10" on a fully capable engine).
    local Player = env.types and env.types.Player
    return Player ~= nil and type(Player.isCharGenFinished) == 'function'
  end,

  -- The live UI mode stack: the "what window is open" hook (scripts/idle/uiState.lua).
  uiModeStack = function(env)
    return env.ui ~= nil and type(env.ui._getUiModeStack) == 'function'
  end,

  -- Reading the journal's topics: the unlocked dialogue options (docs/dialogue.md).
  journalTopics = function(env)
    local Player = env.types and env.types.Player
    return Player ~= nil and type(Player.journal) == 'function'
  end,

  -- Handing movement controls back to the game, so MANUAL play is really playable.
  controlsOverride = function(env)
    local Controls = env.interfaces and env.interfaces.Controls
    return Controls ~= nil and type(Controls.overrideMovementControls) == 'function'
  end,

  -- Screen -> world: tap-to-move needs BOTH of these (docs/tap-to-move.md).
  viewportPick = function(env)
    return env.camera ~= nil and type(env.camera.viewportToWorldVector) == 'function'
  end,
  cameraPosition = function(env)
    return env.camera ~= nil and type(env.camera.getPosition) == 'function'
  end,

  -- Ray casting, for both picking and line-of-sight checks.
  castRay = function(env)
    return env.nearby ~= nil and type(env.nearby.castRay) == 'function'
  end,
  renderingRay = function(env)
    return env.camera ~= nil and type(env.camera.castRenderingRay) == 'function'
  end,

  -- Morrowind's own GMST colours, so the console matches the player's game
  -- (scripts/idle/theme.lua).
  gmst = function(env)
    return env.core ~= nil and type(env.core.getGMST) == 'function'
  end,

  -- The one supported widget-injection point.
  settingsPage = function(env)
    return env.ui ~= nil and type(env.ui.registerSettingsPage) == 'function'
  end,
}

--- The order to report features in (stable output for logs and specs).
M.ORDER = {
  'charGenFlag', 'uiModeStack', 'journalTopics', 'controlsOverride',
  'viewportPick', 'cameraPosition', 'castRay', 'renderingRay', 'gmst', 'settingsPage',
}

--- Human labels, used by the console and the log line.
M.LABEL = {
  charGenFlag = 'character-creation flag',
  uiModeStack = 'live UI mode stack',
  journalTopics = 'journal topics',
  controlsOverride = 'movement-control override',
  viewportPick = 'screen to world picking',
  cameraPosition = 'camera position',
  castRay = 'ray casting',
  renderingRay = 'rendering ray',
  gmst = 'GMST lookup',
  settingsPage = 'settings page',
}

--- `core=table,types=table,...` -- the Lua type of each engine package we were given.
local function envFieldTypes(env)
  local names = { 'core', 'types', 'ui', 'nearby', 'camera', 'interfaces', 'util',
                  'world', 'self', 'input', 'async', 'storage' }
  local parts = {}
  for _, name in ipairs(names) do
    parts[#parts + 1] = name .. '=' .. type(env and env[name])
  end
  return table.concat(parts, ',')
end

--- Probe the engine.
--- @param env table the injected engine env (scripts/runtime/engine.lua)
--- @return { revision?, features, present, missing, ok }
function M.probe(env)
  env = env or {}
  local features = {}
  local present, missing = {}, {}

  for _, name in ipairs(M.ORDER) do
    local check = M.FEATURES[name]
    local ok, value = pcall(check, env)
    local has = ok and value == true
    features[name] = has
    if has then present[#present + 1] = name else missing[#missing + 1] = name end
  end

  local revision
  local okRev, value = pcall(function() return env.core and env.core.API_REVISION end)
  if okRev and type(value) == 'number' then revision = value end

  return {
    revision = revision,
    -- What the env actually held, so a "everything missing" report is diagnosable
    -- from the log instead of needing another engine run to investigate.
    envTypes = (function()
      local ok, value = pcall(envFieldTypes, env)
      return ok and value or ('unreadable: ' .. tostring(value))
    end)(),
    features = features,
    present = present,
    missing = missing,
    ok = #missing == 0,
  }
end

--- A one-line summary, for the engine log and the console.
function M.describe(probe)
  if type(probe) ~= 'table' then return 'capabilities: (not probed)' end
  local revision = probe.revision and ('Lua API revision ' .. tostring(probe.revision)) or 'Lua API revision unknown'
  if probe.ok then
    return ('%s; all %d capabilities present'):format(revision, #(probe.present or {}))
  end
  local labels = {}
  for _, name in ipairs(probe.missing or {}) do
    labels[#labels + 1] = M.LABEL[name] or name
  end
  return ('%s; MISSING %d/%d: %s  [env: %s]'):format(revision, #(probe.missing or {}),
    #(probe.present or {}) + #(probe.missing or {}), table.concat(labels, ', '),
    probe.envTypes or '?')
end

--- The features the console/UI genuinely cannot work without, as opposed to ones
--- that merely degrade. Used to decide whether to warn the player.
M.REQUIRED = { charGenFlag = true }

--- Which required capabilities are absent?
function M.requiredMissing(probe)
  local missing = {}
  for _, name in ipairs(M.ORDER) do
    if M.REQUIRED[name] and type(probe) == 'table' and probe.features and probe.features[name] == false then
      missing[#missing + 1] = name
    end
  end
  return missing
end

return M
