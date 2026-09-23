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
local uiModel = require('scripts.idle.uiModel')
local offlineProgress = require('scripts.idle.offlineProgress')
local guardianMod = require('scripts.idle.guardian')
local settlementMod = require('scripts.idle.settlement')
local cameraMod = require('scripts.idle.camera')
local tapMove = require('scripts.idle.tapMove')
local capabilitiesMod = require('scripts.runtime.capabilities')
local narrationMod = require('scripts.idle.narration')

local self = engine.self()

local state = {
  cfg = nil,
  director = nil,
  executor = nil,
  sinceSnapshot = 0,
  snapshot = nil,
  pendingRestore = nil,
  failures = 0,
  guardian = {
    lastSafe = nil,             -- the last settlement we were healthy in
    sinceIntervention = nil,    -- sim seconds since the last rescue (nil = never)
  },
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
---
--- It also covers character creation: while we are not in the world (chargen,
--- menu, load screen) the engine's own controls must be in charge, exactly as in
--- manual play -- scripts/idle/lifecycle.lua.
local function applyControlOverride()
  local interfaces = engine.interfaces()
  local controls = interfaces and interfaces.Controls
  if not controls or type(controls.overrideMovementControls) ~= 'function' then return end
  local manual = state.director ~= nil and state.director:isManual()
  local phase = state.director and state.director.phase
  local acting = phase == nil or phase.acting == true
  pcall(controls.overrideMovementControls, acting and not manual)
end

--- Lock the camera to an isometric view, if the player asked for it.
--- `openmw.camera` is available to PLAYER scripts (apps/openmw/mwlua/
--- luabindings.cpp:73). A forced setPitch/setYaw latches the angle
--- (mwrender/camera.cpp:320), which is exactly the "lock" an idle game wants.
--- The decision of *whether* to lock lives in scripts/idle/camera.lua; this is
--- only the applying half, and it is a no-op outside the world.
local function applyCamera(phaseId)
  local cam = engine.camera()
  if not cam then return end

  local plan = cameraMod.plan({
    cfg = state.cfg.camera or {},
    phase = phaseId,
    manual = state.director ~= nil and state.director:isManual(),
  })
  if not plan.apply then return end

  pcall(function()
    if type(cam.setMode) == 'function' and cam.MODE and cam.MODE.ThirdPerson ~= nil then
      cam.setMode(cam.MODE.ThirdPerson)
    end
    if type(cam.setPitch) == 'function' then cam.setPitch(plan.pitch) end
    if type(cam.setPreferredThirdPersonDistance) == 'function' then
      cam.setPreferredThirdPersonDistance(plan.distance)
    end
    if plan.yaw and type(cam.setYaw) == 'function' then cam.setYaw(plan.yaw) end
  end)
end

--- What kind of thing did we hit? (types table identity, not record names.)
local function classifyPick(object, types)
  if not object or not types then return 'world' end
  local objectType = object.type
  if objectType == nil then return 'world' end
  if objectType == types.Door then return 'door' end
  if objectType == types.NPC or objectType == types.Creature then return 'actor' end
  if objectType == types.Container then return 'container' end
  if objectType == types.Activator then return 'activator' end
  if types.Item and objectType == types.Item then return 'item' end
  return 'world'
end

--- Turn a normalized screen point (0..1, top-left origin) into a world "pick".
---
---   camera.viewportToWorldVector(pos) -> direction through the pixel
---   nearby.castRay(from, from + dir*R) -> { hit, hitPos, hitObject }
---
--- (docs/openmw-lua-api.md §12). Returns nil if the engine cannot do the pick --
--- it must never throw, since it runs on a tap.
local function pickAt(nx, ny)
  local cam = engine.camera()
  local nearby = engine.nearby()
  local utilEngine = engine.util()
  if not (cam and nearby and utilEngine) then return nil end
  if type(cam.viewportToWorldVector) ~= 'function' or type(cam.getPosition) ~= 'function' then return nil end
  if type(nearby.castRay) ~= 'function' then return nil end
  if type(utilEngine.vector2) ~= 'function' or type(utilEngine.vector3) ~= 'function' then return nil end

  local okDir, dir = pcall(cam.viewportToWorldVector, utilEngine.vector2(nx, ny))
  if not okDir or type(dir) ~= 'table' then return nil end
  local okPos, from = pcall(cam.getPosition)
  if not okPos or type(from) ~= 'table' then return nil end

  local reach = (state.cfg and state.cfg.ui and state.cfg.ui.tapReach) or 4096
  local to = utilEngine.vector3(from.x + dir.x * reach, from.y + dir.y * reach, from.z + dir.z * reach)

  local okCast, result = pcall(nearby.castRay, from, to, { ignore = self and self.object or nil })
  if not okCast or type(result) ~= 'table' or not result.hit then return nil end
  local hitPos = result.hitPos
  if type(hitPos) ~= 'table' then return nil end

  local name
  if result.hitObject and type(result.hitObject.recordId) == 'string' then
    name = result.hitObject.recordId
  end

  local dx, dy, dz = hitPos.x - from.x, hitPos.y - from.y, hitPos.z - from.z
  return {
    hit = true,
    position = { x = hitPos.x, y = hitPos.y, z = hitPos.z },
    distance = math.sqrt(dx * dx + dy * dy + dz * dz),
    kind = classifyPick(result.hitObject, engine.types()),
    id = name,
    name = name,
    object = result.hitObject,
  }
end

--- Ensure the brain exists. Called from onUpdate only: it touches `openmw.nearby`
--- and `openmw.types`, which are unsafe in onLoad (docs/openmw-lua-api.md §7).
--- The operator's narration line, from `narration.txt` in the data folder (nil when
--- absent). Re-read at most every couple of seconds: it is a file, not a hot path.
local function operatorNarration()
  local now = simulationTime()
  if state.narrationReadAt and (now - state.narrationReadAt) < 2 then
    return state.narrationText
  end
  state.narrationReadAt = now
  local ok, text = pcall(engine.readTextFile, 'narration.txt')
  state.narrationText = ok and text or nil
  return state.narrationText
end

local function ensureInit()
  if state.director then return end

  state.cfg = loadUserConfig()
  local env = engine.env()

  -- Ask the engine what it can do, once, and say so. Without this an older engine
  -- (0.48 has none of the chargen flag / UI mode stack / journal topics) degrades
  -- SILENTLY -- the model just stops gating and stops reporting
  -- (scripts/runtime/capabilities.lua).
  state.capabilities = capabilitiesMod.probe(env)
  local capabilityLine = 'idle-openmw: ' .. capabilitiesMod.describe(state.capabilities)
  state.director = directorMod.new({
    classDef = observer.readClass(env, self.object),
    config = state.cfg,
  })
  state.director:logLine(capabilityLine, state.capabilities.ok and 'info' or 'warn')
  -- Also to the engine console/log, so the dev harness (tools/dev/desktop/errors.sh)
  -- can see that the mod ran at all -- the mod is otherwise silent on startup.
  -- (ui.printToConsole, files/lua_api/openmw/ui.lua:65.)
  pcall(function()
    local ui = engine.ui()
    if ui and type(ui.printToConsole) == 'function' then ui.printToConsole(capabilityLine) end
  end)
  -- `print` is the channel that reaches openmw.log (the api-probe proved it: a MENU
  -- script's print lands as `Menu[scripts/api_probe.lua]: ...`). printToConsole only
  -- paints the in-game console, which is invisible to the harness.
  print(capabilityLine)
  local missingRequired = capabilitiesMod.requiredMissing(state.capabilities)
  if #missingRequired > 0 then
    state.director:logLine('idle-openmw: this engine is missing ' ..
      table.concat(missingRequired, ', ') .. ' -- expect degraded behaviour', 'bad')
  end

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

--- "Don't let them die at work."
---
--- Detection only. The policy is scripts/idle/guardian.lua and the two actions
--- that need world authority (teleport, loadGame) are applied by the GLOBAL
--- script scripts/idleWarden.lua -- a PLAYER script cannot call either.
local function guardianTick(snapshot)
  local settings = state.cfg.guardian or {}
  if settings.enabled == false then return end
  if state.director:isManual() and settings.activeInManual ~= true then return end

  local player = snapshot and snapshot.player
  if not player then return end

  local health = player.health or {}
  local current, maximum = health.current, health.base

  -- observer.scanWorld already rates the danger (0..1) via combat.assess; note
  -- `world.enemies` is a COUNT and `world.enemies_nearby` the list, which is an
  -- easy way to write a len() bug here.
  local world = snapshot.world or {}
  local danger = world.danger
  if type(danger) ~= 'number' then
    local nearby = world.enemies_nearby
    danger = (type(nearby) == 'table' and #nearby > 0) and 1 or 0
  end

  -- Remember where we were last safe. Only while healthy, and only in a
  -- settlement: this is what "respawn at the nearest town" degrades to when you
  -- cannot route to a town you have never seen.
  if player.position and guardianMod.worthRemembering(
       settlementMod.isSettlement(player.cell, { cfg = state.cfg }),
       { health = current, healthMax = maximum }, state.cfg) then
    state.guardian.lastSafe = {
      name = settlementMod.displayName(player.cell),
      position = { x = player.position.x, y = player.position.y, z = player.position.z },
    }
  end

  local interval = state.cfg.tick.interval or 1
  state.guardian.sinceIntervention =
    (state.guardian.sinceIntervention == nil) and math.huge
    or (state.guardian.sinceIntervention + interval)

  local action, reason = guardianMod.assess({
    dead = (current ~= nil and current <= 0),
    health = current,
    healthMax = maximum,
    danger = danger,
    hasSafeSpot = state.guardian.lastSafe ~= nil,
    hasSave = settings.saveSlot ~= nil,
    sinceIntervention = state.guardian.sinceIntervention,
  }, state.cfg)

  if action == 'none' then return end

  if action == 'heal' then
    local target = guardianMod.healTarget({ health = current, healthMax = maximum }, state.cfg)
    if target then
      -- healing a pool we cannot write must never take the director down; under
      -- headless tests engine.types() is nil, so this is a genuine no-op there
      pcall(function()
        local types = engine.types()
        if types then
          types.Actor.stats.dynamic.health(self.object).current = target
        end
      end)
    end
  elseif action == 'respawn' or action == 'reload' then
    pcall(function()
      local core = engine.core()
      if not core or type(core.sendGlobalEvent) ~= 'function' then return end
      core.sendGlobalEvent('IdleOpenMW_Guardian', {
        action = action,
        reason = reason,
        safeSpot = state.guardian.lastSafe,
        saveDir = settings.saveDir,
        saveSlot = settings.saveSlot,
      })
    end)
  elseif action == 'retreat' then
    -- The existing flee goal already handles danger, so this is informational:
    -- it must not fight the director for control of the character.
    if state.director then
      pcall(function() state.director:logLine('Guardian: ' .. reason, 'warn') end)
    end
  end

  state.guardian.sinceIntervention = 0
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

      -- Character creation, the main menu and the load screen are not ours to
      -- drive: while we are not in the world, hold every command and let the
      -- engine's own flow run (scripts/idle/lifecycle.lua).
      local acting = snapshot.phase == nil or snapshot.phase.acting == true
      if acting then
        state.director:markVisited(snapshot.player.cell and snapshot.player.cell.name)
      end

      local result = state.director:tick(elapsed, snapshot)
      applyControlOverride()

      if acting then
        state.executor:submit(result.commands)
      else
        -- Character creation / menu / load screen: hold everything, and make sure
        -- no stale command keeps steering the character (see lifecycle.lua).
        state.executor:clear()
      end

      -- The guardian runs regardless of phase: its whole job is death and
      -- critical health, which is exactly the 'dead' phase the director is held
      -- back in. Run after the director so a rescue lands in the same frame; it
      -- may override what the brain just asked for (scripts/idle/guardian.lua).
      guardianTick(snapshot)
    end

    state.executor:update(dt, simulationTime())
    local phaseId = state.snapshot and state.snapshot.phase and state.snapshot.phase.id
    applyCamera(phaseId)

    -- Announce a phase CHANGE to the engine log. This is the harness's signal that
    -- character creation has ended (phase -> world) -- the console only appears in the
    -- world, so without a log line a dev waiting on it has nothing to watch. Logged on
    -- transition only, so it never spams.
    if phaseId ~= state.lastPhaseId then
      state.lastPhaseId = phaseId
      print('idle-openmw: phase -> ' .. tostring(phaseId))
    end
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
    -- Live: the engine's current UI right now, so the "On screen" row keeps up
    -- with what the player just opened (the snapshot is only rebuilt on the tick).
    ui = observer.readUi(env),
    phase = fromDirector.phase,
    capabilities = state.capabilities,
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

--- Tap-to-move. The renderer passes the raw screen point; WE do the raycast.
--- Keeping the pick here (not in portraitUI) means the UI stays a renderer and
--- the engine maths stays in the runtime (docs/tap-to-move.md).
function ACTIONS.walk_to(payload)
  if not (payload and type(payload.x) == 'number' and type(payload.y) == 'number') then return false end
  if not state.director then return false end

  -- normalize against the screen size (mouse events give absolute pixels)
  local nx, ny = payload.x, payload.y
  local ui = engine.ui()
  if ui and type(ui.screenSize) == 'function' then
    local ok, size = pcall(ui.screenSize)
    if ok and type(size) == 'table' and type(size.x) == 'number' and size.x > 0 and size.y > 0 then
      nx, ny = payload.x / size.x, payload.y / size.y
    end
  end

  local pick = pickAt(nx, ny)
  local player = state.snapshot and state.snapshot.player or nil
  local intent = tapMove.intent(pick, player, state.cfg and state.cfg.ui)

  if intent.kind == 'none' then
    state.director:logLine('Tap: ' .. tostring(intent.reason or 'nothing there'), 'info')
    return false
  end
  state.director:pushDirective('walk_to', intent)
  state.director:logLine('Tap: ' .. tapMove.describe(intent), 'info')
  return true
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

--- Persist only what the player changed, so future default changes still apply.
local function persistUserConfig()
  local section = engine.playerStorage(configMod.SECTION_NAME)
  if section and type(section.set) == 'function' then
    pcall(section.set, section, 'config', configMod.overridesOf(state.cfg))
  end
end

--- Cycle a Setup-tab option and persist it.
--- The director, the executor and the panel all read the same config table, so
--- the change lands everywhere at once; re-deriving puts the director's cached
--- weights back in sync.
function ACTIONS.set_option(payload)
  if not (payload and payload.key) then return false, 'no option given' end
  local option = uiModel.findOption(payload.key)
  if not option then return false, ('unknown option %s'):format(tostring(payload.key)) end

  local value = uiModel.nextOptionValue(option, uiModel.optionValue(state.cfg, option))
  if not uiModel.setOptionValue(state.cfg, option, value) then
    return false, ('could not set %s'):format(option.key)
  end

  configMod.validate(state.cfg)
  state.cfg = state.director:setConfig(state.cfg)
  state.executor.cfg = state.cfg
  persistUserConfig()

  local shown = uiModel.formatOptionValue(option, uiModel.optionValue(state.cfg, option))
  state.director:logLine(('%s: %s'):format(option.label, shown), 'info')
  return true
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

--- The GLOBAL warden (scripts/idleWarden.lua) reports back after a rescue. Drop
--- any fight/flee state, because the character has moved and that plan is stale.
local function onGuardianApplied(event)
  state.guardian.sinceIntervention = 0
  if not state.director then return end
  pcall(function()
    state.director:clearDirectives()
    state.director:logLine(
      ('Guardian: %s %s'):format(event.action, event.ok and 'succeeded' or 'failed'),
      event.ok and 'good' or 'bad')
  end)
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
    IdleOpenMW_GuardianApplied = onGuardianApplied,
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
    phase = function()
      return state.director and state.director.phase and state.director.phase.id or nil
    end,
    --- What this engine can do (scripts/runtime/capabilities.lua). Probed once.
    capabilities = function() return state.capabilities end,

    --- The HUD narration line (scripts/idle/narration.lua): the operator's note if
    --- `narration.txt` exists in the data folder, otherwise what the mod is doing.
    narration = function()
      if not state.director then return '' end
      local status = state.director:status()
      local parts = {}
      if status.phase ~= 'world' then
        -- Say WHY nothing is happening: a console that is merely absent looks broken,
        -- and character creation is where a watcher most needs to be told.
        parts[#parts + 1] = 'Holding: ' .. tostring(status.phaseLabel or status.phase or '?')
        parts[#parts + 1] = 'the mod stays out of the way until the character can act'
      else
        parts[#parts + 1] = 'mode ' .. tostring(status.mode or '?')
        if status.goal then parts[#parts + 1] = 'doing ' .. tostring(status.goal) end
        if status.uiLabel then parts[#parts + 1] = 'screen: ' .. tostring(status.uiLabel) end
      end
      return narrationMod.choose(operatorNarration(), table.concat(parts, ' -- '))
    end,
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
