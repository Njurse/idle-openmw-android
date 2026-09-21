-- scripts/idleDirector.lua
-- PLAYER script: the runtime shell around the idle director brain.
--
--   .omwscripts declares:  PLAYER: scripts/idleDirector.lua
--
-- Responsibilities (the ONLY ones -- all decisions live in scripts/idle/*):
--   * build snapshots from the engine (scripts/runtime/observer.lua),
--   * call director:tick and hand the commands to the executor
--     (scripts/runtime/executor.lua),
--   * own the per-script persistence (save/load) and offline catch-up,
--   * forward DialogueResponse events into the director's memory.
--
-- See docs/openmw-lua-api.md for the verified API this relies on.

local engine = require('scripts.runtime.engine')
local observer = require('scripts.runtime.observer')
local executorMod = require('scripts.runtime.executor')
local directorMod = require('scripts.idle.director')
local configMod = require('scripts.idle.config')
local offlineProgress = require('scripts.idle.offlineProgress')

local self = engine.self()

local state = {
  cfg = nil,
  director = nil,
  executor = nil,
  sinceSnapshot = 0,
  autoPlay = true,
  pendingRestore = nil,
  failures = 0,
}

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

local function loadUserConfig()
  local section = engine.playerStorage(configMod.SECTION_NAME)
  local overrides = nil
  if section and type(section.get) == 'function' then
    local ok, value = pcall(section.get, section, 'config')
    if ok then overrides = value end
  end
  return configMod.validate(configMod.new(overrides))
end

--- Wrap `nearby.findPath` behind the narrow nav port the core expects.
--- nearby.findPath returns TWO values -- `(status, points)` -- not a table
--- (docs/openmw-lua-api.md §3), and takes/returns engine Vector3s.
local function makeNavPort()
  local nearby = engine.nearby()
  local util = engine.util()
  if not nearby or type(nearby.findPath) ~= 'function' then return nil end

  local function vec(point)
    if type(point) ~= 'table' then return point end
    if util and util.vector3 then return util.vector3(point.x or 0, point.y or 0, point.z or 0) end
    return point
  end

  return {
    findPath = function(from, to)
      local ok, status, points = pcall(nearby.findPath, vec(from), vec(to), { destinationTolerance = 32 })
      if not ok then return false, nil end
      local statuses = nearby.FIND_PATH_STATUS
      local success = status == true
        or (statuses and status == statuses.Success)
        or status == 'Success'
      if not success or type(points) ~= 'table' or #points == 0 then return false, nil end
      return true, points
    end,
  }
end

--- Ensure the brain exists. Called from onUpdate only: it touches `openmw.nearby`
--- and `openmw.types`, which are unsafe in onLoad (docs/openmw-lua-api.md §7).
local function ensureInit()
  if state.director then return end

  state.cfg = loadUserConfig()
  local env = engine.env()

  state.director = directorMod.new({
    classDef = observer.readClass(env, self.object),
    config = state.cfg,
  })
  state.executor = executorMod.new(env, state.cfg, {
    nav = makeNavPort(),
    rng = state.director.rng,
    onLog = function(message, level) state.director:logLine(message, level) end,
  })

  -- Take the player out of the input loop's hands so our controls stick.
  local interfaces = engine.interfaces()
  if interfaces and interfaces.Controls and interfaces.Controls.overrideMovementControls then
    pcall(interfaces.Controls.overrideMovementControls, true)
  end
  pcall(function() self:enableAI(false) end)

  local restore = state.pendingRestore
  state.pendingRestore = nil
  if restore and restore.data then
    state.director:load(restore.data)
    state.autoPlay = restore.autoPlay ~= false
    local elapsed = offlineProgress.elapsedFromLastSeen(restore.data, engine.wallClock())
    if elapsed > 0 then
      local award = state.director:applyOffline(elapsed)
      if award.applied then
        state.director:logLine(offlineProgress.describe(award), 'good')
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- the tick
-- ---------------------------------------------------------------------------

local function simulationTime()
  local core = engine.core()
  if core and type(core.getSimulationTime) == 'function' then
    local ok, value = pcall(core.getSimulationTime)
    if ok and type(value) == 'number' then return value end
  end
  return 0
end

local function update(dt)
  local ok, err = pcall(function()
    ensureInit()

    if not state.autoPlay then
      state.executor:clear()
      return
    end

    state.sinceSnapshot = state.sinceSnapshot + dt

    if state.sinceSnapshot >= state.cfg.tick.interval then
      local elapsed = state.sinceSnapshot
      state.sinceSnapshot = 0

      local env = engine.env()
      local snapshot = observer.build(env, {
        cfg = state.cfg,
        visitedCells = state.director.visited,
      })
      state.director:markVisited(snapshot.player.cell and snapshot.player.cell.name)

      local result = state.director:tick(elapsed, snapshot)
      state.executor:submit(result.commands)
    end

    state.executor:update(dt, simulationTime())
  end)

  if not ok then
    state.failures = state.failures + 1
    -- Never spam the log or die silently: report the first few, then stay quiet.
    if state.failures <= 5 and state.director then
      pcall(function() state.director:logLine('Director error: ' .. tostring(err), 'bad') end)
    end
  end
end

-- ---------------------------------------------------------------------------
-- handlers
-- ---------------------------------------------------------------------------

local function onSave()
  if not state.director then return { data = nil, autoPlay = state.autoPlay } end
  return {
    data = state.director:serialize(engine.wallClock()),
    autoPlay = state.autoPlay,
  }
end

--- onLoad runs before the first onUpdate, and must not touch `openmw.nearby`;
--- so we only stash the payload and let ensureInit() apply it.
local function onLoad(data)
  state.pendingRestore = data
end

local function onKeyPress(code, modifiers)
  local input = engine.input()
  local constants = input and input.KEY
  -- Toggle auto-play with the configured key (default: the 'L' key).
  if constants and code == constants.L and not modifiers then
    state.autoPlay = not state.autoPlay
    if not state.autoPlay then state.executor:clear() end
    if state.director then
      state.director:logLine(state.autoPlay and 'Auto-play ON' or 'Auto-play OFF (paused)', 'warn')
    end
    return true
  end
  return false
end

local function onDialogueResponse(event)
  if not state.director then return end
  pcall(function() state.director:onDialogue(event) end)
end

return {
  engineHandlers = {
    onUpdate = update,
    onSave = onSave,
    onLoad = onLoad,
    onKeyPress = onKeyPress,
  },
  eventHandlers = {
    DialogueResponse = onDialogueResponse,
  },
  -- exposed so the HUD script can read the same brain without re-deriving it
  interfaceName = 'IdleOpenMW',
  interface = {
    getState = function() return state end,
    getConfig = function() return state.cfg end,
    isAutoPlaying = function() return state.autoPlay end,
    setAutoPlay = function(value) state.autoPlay = value and true or false end,
    toggleAutoPlay = function()
      state.autoPlay = not state.autoPlay
      if not state.autoPlay and state.executor then state.executor:clear() end
      return state.autoPlay
    end,
    status = function() return state.director and state.director:status() or nil end,
    -- Directive Auto: the HUD's buttons feed straight into this
    pushDirective = function(id, payload)
      return state.director and state.director:pushDirective(id, payload) or nil
    end,
    clearDirectives = function()
      if state.director then state.director:clearDirectives() end
    end,
    directive = function()
      return state.director and state.director:currentDirective() or nil
    end,
    log = function(message, level)
      if state.director then state.director:logLine(message, level) end
    end,
  },
}
