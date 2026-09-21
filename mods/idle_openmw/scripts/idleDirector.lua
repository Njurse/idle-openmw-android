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
--   * forward DialogueResponse events into the director's memory,
--   * expose the `IdleOpenMW` interface the HUD drives:
--       panel() / act(action, payload) / mode handling.
--
-- PLAY MODES (scripts/idle/director.lua:M.MODES)
--   manual    -- the player drives. We emit NO commands and hand movement back
--                to the game's own touch controls, so the game is fully playable.
--   directive -- auto-play, but queued orders take precedence.
--   auto      -- fully self-playing.
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
  snapshot = nil,
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
  local utilEngine = engine.util()
  if not nearby or type(nearby.findPath) ~= 'function' then return nil end

  local function vec(point)
    if type(point) ~= 'table' then return point end
    if utilEngine and utilEngine.vector3 then
      return utilEngine.vector3(point.x or 0, point.y or 0, point.z or 0)
    end
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

--- Hand movement controls to, or take them from, the game's own input script.
--- THIS is what makes manual play work: with the override off, the built-in
--- playercontrols script drives the player again.
local function applyControlOverride()
  local interfaces = engine.interfaces()
  local controls = interfaces and interfaces.Controls
  if not controls or type(controls.overrideMovementControls) ~= 'function' then return end
  local manual = state.director ~= nil and state.director:isManual()
  pcall(controls.overrideMovementControls, not manual)
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

  local restore = state.pendingRestore
  state.pendingRestore = nil
  if restore and restore.data then
    state.director:load(restore.data)
    local elapsed = offlineProgress.elapsedFromLastSeen(restore.data, engine.wallClock())
    if elapsed > 0 then
      local award = state.director:applyOffline(elapsed)
      if award.applied then
        state.director:logLine(offlineProgress.describe(award), 'good')
      end
    end
  end

  if state.director:isManual() then pcall(function() self:enableAI(false) end) end
  applyControlOverride()
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

    -- manual mode: hand everything back to the player
    if state.director:isManual() then
      state.executor:clear()
      state.sinceSnapshot = state.sinceSnapshot + dt
      if state.sinceSnapshot >= state.cfg.tick.interval then
        state.sinceSnapshot = 0
        state.snapshot = observer.build(engine.env(), { cfg = state.cfg })
      end
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
      state.snapshot = snapshot
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
-- the console API (driven by portraitUI.lua)
-- ---------------------------------------------------------------------------

--- The full panel snapshot the HUD renders. Shape: scripts/idle/uiModel.lua.
local function panel()
  if not state.director then return nil end
  local env = engine.env()
  local fromEngine = observer.readPanel(env, { cfg = state.cfg })
  local fromDirector = state.director:panelData()
  return {
    status = fromDirector.status,
    mode = fromDirector.mode,
    directive = fromDirector.directive,
    dialogue = fromDirector.dialogue,
    topics = fromDirector.topics,
    log = fromDirector.log,
    player = fromEngine.player,
    inventory = fromEngine.inventory,
    journal = fromEngine.journal,
    quests = fromEngine.quests,
    config = state.cfg,
  }
end

--- Open one of Morrowind's own windows (modes verified in mwlua/uibindings.cpp).
local function openWindow(mode, window)
  local interfaces = engine.interfaces()
  local Ui = interfaces and interfaces.UI
  if not Ui or type(Ui.setMode) ~= 'function' then return false, 'no UI interface' end
  if not mode then return false, 'no mode' end

  local options = {}
  if window then options.windows = { window } end
  -- a target is required by some modes (Dialogue in particular)
  if mode == 'Dialogue' and state.snapshot then
    local nearest = state.snapshot.world and state.snapshot.world.nearest
    options.target = nearest and nearest.talk and nearest.talk.object or nil
  end

  local ok = pcall(Ui.setMode, mode, options)
  if not ok then return false, ('could not open %s'):format(mode) end
  if state.director then state.director:logLine(('Opened %s'):format(mode)) end
  return true
end

local ACTIONS = {}

function ACTIONS.cycle_mode()
  state.director:nextMode()
  applyControlOverride()
  return true
end

--- Pause/resume: toggles between handing the player the controls and auto-play.
function ACTIONS.pause()
  state.director:setMode(state.director:isManual() and 'auto' or 'manual')
  applyControlOverride()
  if state.director:isManual() then pcall(function() self:enableAI(false) end) end
  return true
end

function ACTIONS.order(payload)
  if not (payload and payload.id) then return false end
  return state.director:pushDirective(payload.id) ~= nil
end

function ACTIONS.talk_nearest() return state.director:pushDirective('talk') ~= nil end
function ACTIONS.cancel() state.director:clearDirectives() return true end
function ACTIONS.clear_log() state.director.log:clear() return true end
function ACTIONS.refresh() return true end
function ACTIONS.select() return true end -- selection is UI-local

function ACTIONS.equip(payload)
  if not (payload and payload.id) then return false end
  return state.executor:equip(payload.id)
end

function ACTIONS.sell(payload)
  if not (payload and payload.id) then return false end
  return (state.executor:sellOne(payload.id, payload.count) or 0) > 0
end

function ACTIONS.drop(payload)
  if not (payload and payload.id) then return false end
  return state.executor:dropOne(payload.id, payload.count)
end

function ACTIONS.launch(payload)
  if not (payload and payload.mode) then return false end
  return openWindow(payload.mode, payload.window)
end

local function act(action, payload)
  local handler = ACTIONS[action]
  if not handler then return false, ('unknown action %s'):format(tostring(action)) end
  local ok, result, message = pcall(handler, payload)
  if not ok then
    return false, tostring(result)
  end
  return result ~= false, message
end

-- ---------------------------------------------------------------------------
-- handlers
-- ---------------------------------------------------------------------------

local function onSave()
  if not state.director then return { data = nil } end
  return { data = state.director:serialize(engine.wallClock()) }
end

--- onLoad runs before the first onUpdate, and must not touch `openmw.nearby`;
--- so we only stash the payload and let ensureInit() apply it.
local function onLoad(data)
  state.pendingRestore = data
end

local function onKeyPress(code, modifiers)
  local input = engine.input()
  local constants = input and input.KEY
  -- Tap-to-cycle the play mode from the keyboard too (default: the 'L' key).
  if constants and code == constants.L and not modifiers then
    ensureInit()
    ACTIONS.cycle_mode()
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
  -- the console HUD drives the brain through this
  interfaceName = 'IdleOpenMW',
  interface = {
    getState = function() return state end,
    getConfig = function() return state.cfg end,
    status = function() return state.director and state.director:status() or nil end,
    panel = panel,
    act = act,
    mode = function() return state.director and state.director.mode or nil end,
    setMode = function(mode)
      if not state.director then return nil end
      local applied = state.director:setMode(mode)
      applyControlOverride()
      return applied
    end,
    modes = function() return directorMod.MODES end,
    isAutoPlaying = function() return state.director ~= nil and not state.director:isManual() end,
    toggleAutoPlay = function()
      ACTIONS.pause()
      return state.director and not state.director:isManual()
    end,
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
