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
local uiStateMod = require('scripts.idle.uiState')
local uiReportMod = require('scripts.idle.uiReport')
local bridgeMod = require('scripts.idle.bridge')
local hudMod = require('scripts.idle.hud')
local entitiesMod = require('scripts.runtime.entities')
local registryMod = require('scripts.idle.registry')
local util = require('scripts.idle.util')
local aimMod = require('scripts.idle.aim')
local interactMod = require('scripts.runtime.interact')
local uiLayoutMod = require('scripts.idle.uiLayout')

local self = engine.self()

--- The in-game console's INPUT MODE, as a string -- which is NOT "is the console open".
---
--- These are two different engine facts, and an earlier revision of this mod conflated them:
---
---   * `ui.getConsoleMode()` -> `Console::getConsoleMode()` -> `mConsoleMode`
---     (apps/openmw/mwlua/uibindings.cpp:123, apps/openmw/mwgui/console.hpp:72). This is the
---     input-routing mode: empty by default, and when non-empty the console passes typed input
---     to Lua instead of running mwscript. It says nothing about whether the window is up.
---   * `WindowManager::isConsoleMode()` -> `mConsole->isVisible()`
---     (apps/openmw/mwgui/windowmanagerimp.cpp:1746) is the ACTUAL pause cause
---     (apps/openmw/mwworld/datetimemanager.cpp:259). It is **not exposed to Lua at all**.
---
--- So Lua can neither read whether the console is open nor close it, and `setConsoleMode('')`
--- only resets the input mode -- it never hid the window. The old `ui.closeConsole` bridge method
--- was built on the conflation and could not have worked; it is gone. Read the value below only
--- as "what the console will do with typed input", never as a pause cause.
local function consoleInputMode()
  local ui = engine.ui()
  if not (ui and type(ui.getConsoleMode) == 'function') then return nil end
  local ok, mode = pcall(ui.getConsoleMode)
  if not ok then return nil end
  if type(mode) == 'string' and mode ~= '' then return mode end
  return nil
end

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

  -- Doors and water are expressed through the BITMASK `includeFlags`, not a boolean
  -- (docs/openmw-lua-api.md §3). The engine default already allows all four -- which is why a
  -- path can run THROUGH a door -- but passing them explicitly documents the intent and survives
  -- a build that changes the default. Opening the door is the separate step the executor does
  -- (scripts/runtime/executor.lua:_openDoorsAhead).
  local navFlags = nearby.NAVIGATOR_FLAGS
  local function includeFlags(opts)
    if type(navFlags) ~= 'table' then return nil end
    opts = opts or {}
    local names = { 'Walk' }
    if opts.swim ~= false then names[#names + 1] = 'Swim' end
    if opts.doors ~= false then names[#names + 1] = 'OpenDoor' end
    names[#names + 1] = 'UsePathgrid'
    local total, any = 0, false
    for _, name in ipairs(names) do
      local value = navFlags[name]
      if type(value) == 'number' then total, any = total + value, true end
    end
    if any then return total end
    return nil
  end

  return {
    findPath = function(from, to, opts)
      opts = opts or {}
      local options = { destinationTolerance = opts.tolerance or 32 }
      local flags = includeFlags(opts)
      if flags then options.includeFlags = flags end
      local ok, status, points = pcall(nearby.findPath, vec(from), vec(to), options)
      if not ok then return false, nil end
      local statuses = nearby.FIND_PATH_STATUS
      local success = status == true
        or (statuses and status == statuses.Success)
        or status == 'Success'
      if not success or type(points) ~= 'table' or #points == 0 then return false, nil end
      return true, points
    end,
    --- Snap a point onto walkable ground, for a target that sits OFF the navmesh (on a table,
    --- inside a wall, behind a counter). `nearby.findNearestNavMeshPosition` (docs §3) returns a
    --- Vector3; a partial read is reported as nothing rather than as confident nonsense.
    snap = function(point)
      if type(nearby.findNearestNavMeshPosition) ~= 'function' then return nil end
      local ok, snapped = pcall(nearby.findNearestNavMeshPosition, vec(point), {})
      if not ok or not snapped then return nil end
      local out = nil
      pcall(function() out = { x = snapped.x, y = snapped.y, z = snapped.z } end)
      if out and (out.x == nil or out.y == nil or out.z == nil) then return nil end
      return out
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

  -- Vector3 is a USERDATA usertype (util.lua:199) and `castRay` returns the registered
  -- RayCastingResult usertype (nearbybindings.cpp:72-73), so `type(x) == 'table'` rejected every
  -- one of these and tap-picking could NEVER work on a real engine.
  local okDir, dir = pcall(cam.viewportToWorldVector, utilEngine.vector2(nx, ny))
  if not okDir or not util.isObject(dir) then return nil end
  local okPos, from = pcall(cam.getPosition)
  if not okPos or not util.isObject(from) then return nil end

  local reach = (state.cfg and state.cfg.ui and state.cfg.ui.tapReach) or 4096
  local to = utilEngine.vector3(from.x + dir.x * reach, from.y + dir.y * reach, from.z + dir.z * reach)

  local okCast, result = pcall(nearby.castRay, from, to, { ignore = self and self.object or nil })
  if not okCast or not util.isObject(result) or not result.hit then return nil end
  local hitPos = result.hitPos
  if not util.isObject(hitPos) then return nil end

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
  -- Re-read about twice a second. Counted in FRAMES rather than seconds: this is called
  -- from the UI (which has no dt), and the only clock available is the sandboxed one.
  local frame = state.frameCount or 0
  if state.narrationReadFrame and (frame - state.narrationReadFrame) < 30 then
    return state.narrationText
  end
  state.narrationReadFrame = frame
  local ok, text = pcall(engine.readTextFile, 'narration.txt')
  state.narrationText = ok and text or nil
  return state.narrationText
end

--- Everything we can know about the UI and our own drawing, as one report.
---
--- ui.getElements() enumerates ONLY elements the Lua layer created, so this is the mod's
--- own drawing -- the engine's widgets (the chargen dialogs, the journal) are not in it and
--- cannot be enumerated from Lua at all. docs/ui-inventory.md says what is and is not
--- observable; the report says what is true right now.
local function gatherUiReport()
  local data = {}
  do -- the engine's open windows
    local ui = engine.ui()
    if ui and type(ui._getUiModeStack) == 'function' then
      -- through the ONE reader: the raw value is engine userdata, and treating it as a table
      -- made this report say "empty" while a window was open
      local ok, raw = pcall(ui._getUiModeStack)
      data.uiModes = ok and uiStateMod.stackOf(raw) or ('error: ' .. tostring(raw))
    else
      data.uiModes = 'no _getUiModeStack'
    end
    if ui and type(ui.getElements) == 'function' then
      local ok, elements = pcall(ui.getElements)
      -- say WHY it is missing: "unavailable" with no reason sent me looking in the wrong
      -- place once already
      data.elements = ok and elements or ('error: ' .. tostring(elements))
    else
      data.elements = 'ui.getElements is not a function'
    end
    if ui and type(ui.screenSize) == 'function' then
      local ok, size = pcall(ui.screenSize)
      if ok then data.screen = size end
    end
  end
  do -- game state
    -- phase straight off the director: status() did not carry it, so the report read nil
    -- while the director knew perfectly well that it was in chargen
    -- The SNAPSHOT is authoritative: that is what the phase gate reads. The director's
    -- own self.phase is only set while acting, so it read nil during chargen.
    local snapshotPhase = state.snapshot and state.snapshot.phase
    data.phase = (snapshotPhase and snapshotPhase.id) or state.director.phase
    data.phaseLabel = (snapshotPhase and snapshotPhase.label) or state.director.phaseLabel
    local ok, status = pcall(function() return state.director:status() end)
    if ok and status then
      data.acting = status.acting
      data.mode = status.mode
      data.uiKind = status.uiKind
      data.uiLabel = status.uiLabel
    end
    data.paused = engine.isWorldPaused()

  do -- what the DIRECTOR decided, and what the executor is doing about it
    -- A host watching the game needs this, and the plain log does not show it: "the world is
    -- running and NOTHING is happening" is the single hardest state to debug from outside, and
    -- it is the state this report is most often asked about.
    local ok, status = pcall(function() return state.director:status() end)
    if ok and status then
      data.goal = status.goal
      data.goalReason = status.reason
      data.directive = status.directive
      data.topGoals = status.topGoals
    end
    local executor = state.executor
    if executor then
      data.pending = executor:pending()
      data.moving = executor:isMoving()
      local head = executor:peek()
      data.nextCommand = head and head.type or nil
      data.moveTarget = head and head.dest or nil
      data.routeTarget = executor.route and executor.route.target or nil
      data.routeSnapped = executor.route and executor.route.snapped or nil
    end
    -- the LIVE position, through the ONE reader the rest of the mod uses
    -- (entities.positionOf). NOTE: `self.position` is correct, but `self.object.position` reads
    -- (0,0,0) for a PLAYER script -- so the object wrapper is NOT the place to read it from.
    do
      local object = engine.self()
      data.position = object and entitiesMod.positionOf(object) or nil
    end
  end

  do -- the SHAPE of the nearby lists
    -- These are the values the world model is built from, and they are the AGENTS.md #7 trap:
    -- the engine pushes an ObjectList (a userdata with __len/__index/__ipairs, objectbindings.cpp
    -- :169-180), while the mocks use plain tables -- so the specs can be green while the real
    -- world reads empty. Report the shape so the failure is visible instead of silent.
    local nearby = engine.nearby()
    local lists = {}
    if nearby then
      for _, name in ipairs({ 'actors', 'doors', 'containers', 'items', 'activators', 'players' }) do
        local list = nil
        pcall(function() list = nearby[name] end)
        if list ~= nil then
          local entry = { type = type(list) }
          local okLen, len = pcall(function() return #list end)
          if okLen then entry.length = len end
          local okIp, counted = pcall(function()
            local c = 0
            for _ in ipairs(list) do c = c + 1 end
            return c
          end)
          entry.ipairs = okIp and counted or 'error'
          local okP, countedPairs = pcall(function()
            local c = 0
            for _ in pairs(list) do c = c + 1 end
            return c
          end)
          entry.pairs = okP and countedPairs or 'error'
          lists[name] = entry
        end
      end
    end
    data.nearbyLists = lists
  end

  do -- WHY the model thinks something is hostile
    -- A bare count is not actionable: "25 hostiles" in a town of shopkeepers is a classifier
    -- bug, not a danger, and the two are indistinguishable from outside without the reason.
    local nearby = state.snapshot and state.snapshot.world
      and state.snapshot.world.enemies_nearby
    if util.isObject(nearby) and #nearby > 0 then
      local rows = {}
      for index = 1, math.min(#nearby, 4) do
        local enemy = nearby[index] or {}
        rows[#rows + 1] = { name = enemy.name, reason = enemy.reason }
      end
      data.enemyReasons = rows
    end
  end

  do -- what the CAMERA is actually doing (an isometric lock is otherwise invisible)
    local cam = engine.camera()
    if cam then
      local camera = {}
      pcall(function() if type(cam.getMode) == 'function' then camera.mode = cam.getMode() end end)
      pcall(function() if type(cam.getPitch) == 'function' then camera.pitch = cam.getPitch() end end)
      pcall(function() if type(cam.getYaw) == 'function' then camera.yaw = cam.getYaw() end end)
      pcall(function()
        if type(cam.getThirdPersonDistance) == 'function' then
          camera.distance = cam.getThirdPersonDistance()
        end
      end)
      data.camera = camera
    end
  end
    -- A paused world with no window open is a MESSAGE BOX: Morrowind's messages are not UI
    -- modes, so the mode stack is empty while a modal stops the world. Say so, because Lua
    -- cannot click a native widget -- the host has to, and it has to know when.
    do
      -- Report the console's INPUT MODE if set -- deliberately NOT as a pause cause. Whether the
      -- console window is open is invisible to Lua (see consoleInputMode above), so the
      -- pause-cause check cannot use it: a console-held pause lands in "unknown" with the console
      -- named among the candidates, which is the honest answer.
      data.consoleMode = consoleInputMode()
      local state = uiStateMod.blocking(data.paused, data.uiModes)
      data.blocked = state.blocked
      data.hint = state.hint
      data.blockedCause = state.cause
      data.blockedMode = state.mode
    end
    data.ticking = state.lastDt and state.lastDt > 0
    -- the FLAG's value, not the capability: reporting features.charGenFlag said "true"
    -- merely because the API exists, which read as "chargen is finished" and was wrong
    do
      local types = engine.types()
      local flag = types and types.Player and types.Player.isCharGenFinished
      if type(flag) == 'function' then
        -- the player object lives in the injected env; fetch it if we do not hold it
        local player = state.env and state.env.self
        if not player then
          local okEnv, env = pcall(engine.env)
          if okEnv and env then player = env.self end
        end
        local okFlag, done = pcall(flag, player)
        data.charGenDone = okFlag and tostring(done) or ('error: ' .. tostring(done))
      else
        data.charGenDone = 'no isCharGenFinished'
      end
    end
    local snapshot = state.snapshot
    if snapshot then
      data.cell = snapshot.world and snapshot.world.cellName
      -- the BRAIN's view of where the player is -- what the director steers from. `position`
      -- above is the LIVE engine value; keeping both is what makes a disagreement (the world
      -- model lying to the director) visible instead of silent.
      data.snapshotPosition = snapshot.player and snapshot.player.position or nil
    end
  end
  do -- our geometry
    -- state.layout only exists once the console has been BUILT (world phase), but the
    -- narration is drawn during chargen too -- so fall back to computing the base layout,
    -- which is what the narration actually positions itself from.
    local base = state.layout and state.layout.base
    if not base then
      local screen = nil
      if data.screen then screen = data.screen end
      local cfg = {}
      if state.director and state.director.cfg then cfg = state.director.cfg.ui or {} end
      local okBase, computed = pcall(uiLayoutMod.compute, screen, cfg)
      if okBase then base = computed end
    end
    if base then
      data.scale = base.scale
      data.textScale = base.textScale
      data.narrationRect = base.narration
    end
    data.capabilities = state.capabilities and capabilitiesMod.describe(state.capabilities)
    -- Is there a snapshot at all? A nil phase almost always means "no snapshot yet",
    -- which is a different fault from a wrong phase, and saying so saves a hunt.
    data.snapshot = state.snapshot and 'yes' or 'nil (never built)'
    local life = state.snapshot and state.snapshot.lifecycle
    if life then
      data.lifecycle = ('playerExists=%s charGenFinished=%s uiKind=%s dead=%s'):format(
        tostring(life.playerExists), tostring(life.charGenFinished),
        tostring(life.uiKind), tostring(life.dead))
    end
  end
  return data
end

--- Print a UI report to the engine log.
local function reportUi()
  local ok, text = pcall(function() return uiReportMod.format(gatherUiReport()) end)
  if ok then print(text) else print('idle-openmw: ui report failed: ' .. tostring(text)) end
end

--- The dev command channel: `dev_command.txt` in the data folder, polled.
---
--- Injecting keystrokes into the running game proved unreliable (the console does not take
--- them), while READING a file does not: the mod polls it through openmw.vfs. So asking the
--- running game for something is a matter of writing a line. Nothing here changes gameplay.
--- A throttle that still fires while the world is paused.
---
--- `dt` is 0 for every frame of a paused world (measured: `dt=0 sinceSnapshot=0` for thousands
--- of consecutive frames), so a dt-accumulated throttle NEVER fires during chargen, a modal
--- window or a message box -- that is, in exactly the situations where a host most wants to ask
--- the mod what is going on. It made the whole request channel look dead.
---
--- Frames advance either way (the engine calls onUpdate regardless of pause), so count frames.
--- 30 frames is roughly half a second at 60 fps and a whole second at 30, which is the right
--- order for a file-based request channel.
---
--- @param store table where to keep the counter (so this stays testable without globals)
--- @param key string the counter's name inside `store`
--- @param frames number how many calls to let pass between firings
--- @return boolean true on the call that fires
local function everyFrames(store, key, frames)
  if type(store) ~= 'table' then return false end
  local count = (store[key] or 0) + 1
  if count < (frames or 1) then
    store[key] = count
    return false
  end
  store[key] = 0
  return true
end

local function pollDevCommand()
  -- frame-counted, not dt-accumulated: see everyFrames
  if not everyFrames(state, 'devTick', 30) then return end

  local ok, text = pcall(engine.readTextFile, 'dev_command.txt', 512)
  if not ok or type(text) ~= 'string' then return end
  text = text:gsub('%s+$', '')
  if text == '' or text == state.lastDevCommand then return end
  state.lastDevCommand = text

  local command = uiReportMod.parseCommand(text)
  if not command then return end
  print('idle-openmw: dev command -> ' .. command.verb)
  if command.verb == 'dump' then
    reportUi()
  elseif command.verb == 'heartbeat' then
    state.heartbeatSeconds = command.seconds or 10
    state.heartbeatElapsed = 0
    print('idle-openmw: heartbeat every ' .. tostring(state.heartbeatSeconds) .. 's')
  elseif command.verb == 'note' then
    state.operatorNote = command.text
  elseif command.verb == 'economy' then
    -- A live probe of the player -> warden -> engine channel, and the only way an operator can
    -- exercise the economy without a merchant in front of them. The mod's own trades (sell/buy/
    -- drop) go through the same `_requestEconomy`.
    local op, rest = (command.text or ''):match('^(%S+)%s*(.*)$')
    op = (op or ''):lower()
    local first, second = rest:match('^(%S+)%s*(%S*)$')
    local payload = nil
    if op == 'gold' then
      payload = { op = 'gold', amount = tonumber(first) }
    elseif op == 'give' or op == 'take' then
      payload = { op = op, recordId = first, count = tonumber(second) or 1 }
    end
    if not payload or not state.executor then
      print('idle-openmw: economy needs "gold <n>", "give <recordId> [n]" or "take <recordId> [n]"')
      state.lastDevCommand = nil
      return
    end
    print('idle-openmw: economy -> ' .. op .. ' ' .. tostring(first or ''))
    state.executor:_requestEconomy(payload)
  elseif command.verb == 'camera' then
    state.cfg.camera = state.cfg.camera or {}
    local set, rest = (command.text or ''):match('^(%S+)%s*(.*)$')
    set = (set or ''):lower()
    if set == 'on' then
      state.cfg.camera.isometric = true
    elseif set == 'off' then
      state.cfg.camera.isometric = false
    elseif set == 'pitch' then
      state.cfg.camera.pitch = tonumber(rest) or state.cfg.camera.pitch
    elseif set == 'distance' then
      state.cfg.camera.distance = tonumber(rest) or state.cfg.camera.distance
    else
      print('idle-openmw: camera needs on|off|pitch <radians>|distance <units>')
      state.lastDevCommand = nil
      return
    end
    print('idle-openmw: camera isometric=' .. tostring(state.cfg.camera.isometric)
      .. ' pitch=' .. tostring(state.cfg.camera.pitch)
      .. ' distance=' .. tostring(state.cfg.camera.distance))
  elseif command.verb == 'telemetry' then
    state.telemetrySeconds = command.seconds or 10
    state.telemetryElapsed = 0
    print('idle-openmw: telemetry every ' .. tostring(state.telemetrySeconds) .. 's')
  elseif command.verb == 'stop' then
    state.heartbeatSeconds = nil
    state.operatorNote = nil
  else
    print('idle-openmw: unknown dev command: ' .. tostring(command.text))
  end
end

--- Where the bridge gets its answers (scripts/idle/bridge.lua, docs/bridge-api.md).
---
--- Every source is defensive: a bridge that cannot answer says "unavailable" rather than
--- taking the mod down, and this runs in a live game where any of these can be missing.
--- The player object, from wherever it is available.
---
--- `state.env` is only populated on some paths, so a fallback that read `state.env.self`
--- found nothing and reported an empty player -- silently, which is the failure mode this
--- session has been about. Ask the engine instead.
local function playerObject()
  if state.env and state.env.self then return state.env.self end
  local ok, env = pcall(engine.env)
  if ok and env and env.self then
    state.env = env
    return env.self
  end
  return nil
end

--- Remember an entity we have just read, so a host can name it in the next request.
---
--- Failures are swallowed on purpose: the registry is a convenience for a host, and a mod that
--- throws while taking a note is worse than one that forgets. The clock is the frame counter (a
--- monotonic tick) rather than a wall clock, because a paused game has no wall clock to trust.
local function remember(entity)
  if type(entity) ~= 'table' then return entity end
  if state.registry then
    pcall(function() state.registry:remember(entity, state.frameCount or 0) end)
  end
  return entity
end

local function rememberAll(list)
  if type(list) ~= 'table' then return list end
  if state.registry then
    pcall(function() state.registry:rememberAll(list, state.frameCount or 0) end)
  end
  return list
end
local function uiControl()
  local interfaces = engine.interfaces()
  if not interfaces then return nil end
  local ok, ui = pcall(function() return interfaces.UI end)
  if ok and ui then return ui end
  return nil
end

--- Copy the active mode stack as a plain list, so it serialises.
local function modeStack()
  local ui = uiControl()
  if not ui then return nil end
  local out = {}
  local ok = pcall(function()
    for _, mode in ipairs(ui.modes) do out[#out + 1] = tostring(mode) end
  end)
  if not ok then return nil end
  return out
end

--- Report the UI: what is open, and whether it is pausing the world.
local function uiState()
  local ui = uiControl()
  if not ui then return nil end
  local current = nil
  pcall(function() current = ui.getMode() end)
  return {
    current = current,
    stack = modeStack(),
    paused = engine.isWorldPaused(),
  }
end

--- Close a window (or all of them), which is how a host unblocks a paused world.
local function uiClose(params)
  local ui = uiControl()
  if not ui or type(ui.setMode) ~= 'function' then return nil end
  local mode = type(params) == 'table' and params.mode or nil
  local ok, err
  if mode then
    ok, err = pcall(ui.removeMode, mode)
  else
    -- setMode with no argument drops every active mode (scripts/omw/ui.lua:213)
    ok, err = pcall(ui.setMode)
  end
  local state = uiState() or {}
  state.closed = mode or 'all'
  if not ok then state.error = tostring(err) end
  return state
end

--- Open a window, optionally targeting an actor (Barter, Dialogue...).
local function uiOpen(params)
  local ui = uiControl()
  if not ui or type(ui.addMode) ~= 'function' then return nil end
  if type(params) ~= 'table' or type(params.mode) ~= 'string' then return nil end
  local options = {}
  if params.windows then options.windows = params.windows end
  local ok, err = pcall(ui.addMode, params.mode, options)
  local state = uiState() or {}
  state.opened = params.mode
  if not ok then state.error = tostring(err) end
  return state
end

--- Say whether a mode should pause the game. Windows pause by default; an idle game with its
--- own HUD often wants the world to keep running underneath.
local function uiSetPauseOnMode(params)
  local ui = uiControl()
  if not ui or type(ui.setPauseOnMode) ~= 'function' then return nil end
  if type(params) ~= 'table' or type(params.mode) ~= 'string' then return nil end
  local pause = params.pause
  if pause == nil then pause = false end
  local ok, err = pcall(ui.setPauseOnMode, params.mode, pause and true or false)
  if not ok then return { mode = params.mode, error = tostring(err) } end
  return { mode = params.mode, pause = pause and true or false }
end

local function bridgeSources()
  local function snapshot() return state.snapshot end

  --- The object under the crosshair, and what can be done with it.
  ---
  --- This is the answer to "look up at the hatch and press space": the engine will not hand
  --- over its own prompt text, but a ray from the camera tells us the same thing.
  local function lookAt()
    local camera = engine.camera()
    local nearby = engine.nearby()
    if not (camera and nearby and type(nearby.castRay) == 'function') then return nil end

    local hitObject = nil
    pcall(function()
      local from = camera.getPosition()
      local direction = camera.viewportToWorldVector(0.5, 0.5)
      if not (from and direction) then return end
      local reach = state.cfg.ui and state.cfg.ui.tapReach or 4096
      local to = {
        x = from.x + direction.x * reach,
        y = from.y + direction.y * reach,
        z = from.z + direction.z * reach,
      }
      local hit = nearby.castRay(from, to, { ignore = playerObject() })
      if hit and hit.hit and hit.hitObject then hitObject = hit.hitObject end
    end)
    if not hitObject then return nil end

    -- the object under the crosshair IS an entity, read the same way as any other
    local from = entitiesMod.positionOf(playerObject())
    local read = entitiesMod.read(hitObject, engine.env(), from)
    if read then read.hit = true end
    return remember(read)
  end

  --- Nearby things the player could interact with, nearest first.
  local function interactables(params)
    local radius = type(params) == 'table' and tonumber(params.radius) or 1024
    local from = entitiesMod.positionOf(playerObject())
    local nearby = entitiesMod.readNearby(engine.env(), from)
    if not nearby then return nil end
    local out = {}
    for _, read in ipairs(nearby) do
      if not read.distance or read.distance <= radius then out[#out + 1] = read end
    end
    return rememberAll(out)
  end

  --- The derived on-screen advice.
  local function hints()
    local target = lookAt()
    local snap = snapshot()
    return hudMod.hints({
      target = target,
      -- OpenMW exposes no action->key lookup (only key codes to names), so this is the
      -- documented default rather than a guess dressed up as a fact.
      activateKey = state.cfg.ui and state.cfg.ui.activateKey or 'Space',
      paused = engine.isWorldPaused(),
      phase = snap and snap.phase and snap.phase.id,
      interactables = interactables({ radius = 512 }),
    })
  end

  return {
    hasRealClock = function() return engine.hasRealClock() end,
    capabilities = function()
      return { line = capabilitiesMod.describe(state.capabilities) }
    end,
    --- The player, through the ONE reader, so its shape matches every other entity.
    player = function()
      local object = playerObject()
      if not object then
        -- no engine object (very early, or a script context without self): report what the
        -- snapshot knows rather than an empty table
        local snap = snapshot()
        return snap and snap.player or {}
      end
      local read = entitiesMod.read(object, engine.env())
      if not read then return {} end
      -- the player is the reference point, so distance/vertical are meaningless for it
      read.distance, read.vertical = nil, nil
      return remember(read)
    end,
    cell = function()
      local snap = snapshot()
      local cell = snap and snap.world and snap.world.cell
      if not cell then
        -- the player's own cell object is readable without a snapshot; a paused world never
        -- builds one, and a host should still be able to ask where it is
        local object = playerObject()
        local own = nil
        pcall(function() own = object and object.cell end)
        cell = own
      end
      if not cell then return nil end
      -- readCell may be handed an engine Cell or the snapshot's plain table
      if type(cell) == 'table' and cell.name and not cell.id then
        return { kind = 'cell', id = cell.name, name = cell.name, region = cell.region,
                 isExterior = cell.isExterior, gridX = cell.gridX, gridY = cell.gridY,
                 contentsFetched = false }
      end
      return entitiesMod.readCell(cell, engine.env())
    end,
    entities = function(params)
      local from = entitiesMod.positionOf(playerObject())
      local nearby = entitiesMod.readNearby(engine.env(), from)
      if not nearby then return nil end
      local radius = type(params) == 'table' and tonumber(params.radius) or nil
      local out = {}
      for _, read in ipairs(nearby) do
        -- group by which nearby list it came from, which is what a caller filters on
        local bucket = out[read.list] or {}
        if not radius or not read.distance or read.distance <= radius then
          bucket[#bucket + 1] = read
        end
        out[read.list] = bucket
      end
      -- out is grouped by kind, so remember each bucket rather than the map
      for _, bucket in pairs(out) do rememberAll(bucket) end
      return out
    end,
    --- A remembered entity, by the id an earlier response reported.
    ---
    --- This is the join between two requests: a host cannot hold an engine object, so the mod
    --- keeps the little needed to find one again (scripts/idle/registry.lua). What comes back is
    --- the REMEMBERED record -- identity plus the position we last saw it at -- not a fresh
    --- read, which is why this method is declared 'free' rather than 'entity': a remembered
    --- record is honestly a subset, and calling it an entity would be a quiet lie.
    ---
    --- An unknown id (forgotten, or evicted) is a MISS and returns nil, with a line in the
    --- decision trace so a stale reference is visible rather than mysterious.
    entityGet = function(params)
      local id = type(params) == 'table' and params.id or nil
      if type(id) ~= 'string' or id == '' then return nil end
      local entry = state.registry and state.registry:get(id)
      if not entry then
        if state.director and state.director.trace then
          state.director.trace:add('registry', 'entity.get miss: ' .. id, nil, { id = id })
        end
        return nil
      end
      return entry
    end,
    --- Leave the cell the player is in: walk to the door, look at it, use it.
    ---
    --- The whole reason the bridge exists (docs/bridge-api.md): a goal, not a read. It runs
    --- across frames, so the answer is "started", and the outcome arrives in the log/narration
    --- as `idle-openmw: exit -> ...` lines -- including `-> OUT: <before> -> <after>` when the
    --- player's cell actually changes.
    worldExit = function()
      if not startExit() then return { started = false, reason = 'the director is not up yet' } end
      local exit = state.exit or {}
      return {
        started = true,
        fromCell = exit.cellBefore,
        note = 'watch for "idle-openmw: exit ->" lines; OUT when the cell changes',
      }
    end,
    --- Ask the warden WHY the world is stopped, and print the answer.
    ---
    --- `core.isWorldPaused()` says only THAT it is; the pause tags say who is holding it. The
    --- answer arrives as a log line from the global script (`[idle-openmw/warden] global: pause
    --- tags = ...`), because a global event cannot return a value and everything else the mod
    --- says goes to the log anyway.
    worldPauseTags = function()
      if not (engine.core() and type(engine.core().sendGlobalEvent) == 'function') then
        return { requested = false, reason = 'this build cannot send global events' }
      end
      local ok, err = pcall(engine.core().sendGlobalEvent, 'IdleOpenMW_PauseTags', {})
      if not ok then return { requested = false, reason = tostring(err) } end
      return { requested = true, note = 'the tags are in the engine log, from [idle-openmw/warden]' }
    end,
    --- Release the world's pause, by tag (or by the engine's own defaults when no tag is given).
    ---
    --- This is deliberately explicit about the tag: clearing a pause we did not take is not
    --- obviously ours to clear, so the caller says which one it means.
    worldUnpause = function(params)
      local tag = type(params) == 'table' and params.tag or nil
      if not (engine.core() and type(engine.core().sendGlobalEvent) == 'function') then
        return { requested = false, reason = 'this build cannot send global events' }
      end
      local ok, err = pcall(engine.core().sendGlobalEvent, 'IdleOpenMW_Unpause', { tag = tag })
      if not ok then return { requested = false, reason = tostring(err) } end
      return { requested = true, tag = tag, note = 'result in the engine log, from [idle-openmw/warden]' }
    end,
    --- What the exit run is doing, for a host that would rather poll than read the log.
    exitState = function()
      local exit = state.exit
      if not exit then return { running = false } end
      return {
        running = true,
        phase = exit.phase,
        targetId = exit.targetId,
        aimed = exit.aimed,
        tries = exit.tries,
        fromCell = exit.cellBefore,
        cell = state.snapshot and state.snapshot.world and state.snapshot.world.cell
          and state.snapshot.world.cell.name or nil,
      }
    end,
    --- What is currently remembered, most recent first. A host that lost an id can find it
    --- again without re-reading the cell, and `evicted` says whether anything was dropped.
    registry = function(params)
      if not state.registry then return nil end
      local kind = type(params) == 'table' and params.kind or nil
      return {
        cap = state.registry.cap,
        count = state.registry:count(),
        evicted = state.registry:evictedCount(),
        entities = state.registry:list(kind),
      }
    end,
    quests = function()
      local types = engine.types()
      local player = playerObject()
      if not (types and types.Player and type(types.Player.quests) == 'function') then
        return nil
      end
      local ok, list = pcall(types.Player.quests, player)
      -- `types.Player.quests(player)` is a `Quests` USERDATA (player.cpp:297) that iterates via
      -- `__pairs`, so `type(list) == 'table'` rejected it and this view was always empty. The
      -- pcall keeps a Lua build without `__pairs` from throwing instead of reporting nothing.
      if not ok or not util.isObject(list) then return nil end
      local out = {}
      local iterated = pcall(function()
        for id, quest in pairs(list) do
          out[#out + 1] = {
            id = id,
            stage = quest and quest.stage,
            started = quest and quest.started,
            finished = quest and quest.finished,
            name = quest and quest.name,
          }
        end
      end)
      if not iterated then return nil end
      table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
      return out
    end,
    topics = function()
      local snap = snapshot()
      local topics = snap and snap.journalTopics
      if type(topics) ~= 'table' then return nil end
      local out = {}
      for name in pairs(topics) do out[#out + 1] = { topic = name } end
      table.sort(out, function(a, b) return a.topic < b.topic end)
      return out
    end,
    ui = function() return gatherUiReport() end,
    -- UI CONTROL: a host can close a window, open one, or stop one pausing the world. This is
    -- how a paused-by-a-menu game gets unblocked, and it needs no input synthesis because
    -- interfaces.UI is the game's own Lua module.
    uiState = function() return uiState() end,
    uiClose = function(params) return uiClose(params) end,
    uiOpen = function(params) return uiOpen(params) end,
    uiPauseOnMode = function(params) return uiSetPauseOnMode(params) end,
    uiTarget = function() return lookAt() end,
    uiInteractables = function(params) return interactables(params) end,
    uiHints = function() return hints() end,
  }
end

--- The bridge instance, built lazily.
local function bridge()
  if not state.bridge then
    state.bridge = bridgeMod.new(bridgeSources(), {
      onAction = function(goal, ttl)
        if not state.director then return { accepted = false, reason = 'not initialised' } end
        -- Actions go through the director's own directive channel, so a request from a
        -- host is the same thing as a tap in the console: one path, one set of rules.
        local ok, result = pcall(function()
          return state.director:pushDirective(goal, ttl)
        end)
        if not ok then return { accepted = false, reason = tostring(result) } end
        return { accepted = true, goal = goal, directive = result }
      end,
    })
  end
  return state.bridge
end

--- Answer request lines from `idle_api.txt`, one response line each.
---
--- OpenMW's Lua cannot open a socket or write a file, so a file in and a print out is the
--- whole channel: the host writes a line, the mod answers into the log (and stdout).
local function pollApiRequests()
  -- frame-counted, not dt-accumulated: while the world is paused dt is 0 every frame, so a
  -- dt-gated poll never runs -- and a paused game is EXACTLY when a host is asking what is
  -- going on. See everyFrames.
  if not everyFrames(state, 'apiTick', 30) then return end

  local ok, text = pcall(engine.readTextFile, 'idle_api.txt', 8192)
  if not ok or type(text) ~= 'string' or text == '' then return end
  -- Answer each request once: the file is re-read every second, so remembering what we have
  -- served is what stops one request being answered forever.
  if text == state.lastApiText then return end
  state.lastApiText = text

  local instance = bridge()
  local answered = 0
  for line in text:gmatch('[^\r\n]+') do
    local response = instance:handleLine(line)
    if response then
      print(response)
      answered = answered + 1
    end
  end
  if answered == 0 then print('idle-openmw: idle_api.txt had no requests') end
end

local function ensureInit()
  if state.director then return end

  state.cfg = loadUserConfig()
  -- The memory of named entities (scripts/idle/registry.lua). A host speaks text and cannot
  -- hold an engine object, so "the hatch you told me about" has to be something we remember
  -- between requests. Bounded and LRU, because the alternative is a leak.
  state.registry = registryMod.new(state.cfg.ui and state.cfg.ui.registryCap or nil)
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

-- ===========================================================================
-- LEAVING THE SHIP -- the goal the whole bridge exists to serve
-- ===========================================================================
--
-- This is a hand-played sequence written down: walk to the hatch, LOOK UP AT IT, press use.
-- Three things make it more than a wrapper:
--
--   * the decisions are pure (scripts/idle/aim.lua: chooseExit, step) so they are testable
--     without a game, and the narration can say WHY it is doing what it is doing;
--   * the engine I/O is its own layer (scripts/runtime/interact.lua: reach, aimAndVerify,
--     activate), including a ray-verified aim that corrects the pitch convention once;
--   * it VERIFIES the outcome: a teleport door changes the player's cell, so "did we get out?"
--     is answered by comparing the cell before and after rather than by assuming the call worked.

--- How long to keep trying before reporting failure. At 60 fps this is ~45 s, which is a
--- leisurely walk across the ship's cabin.
local EXIT_MAX_FRAMES = 60 * 45
--- How many times to try using the door. Morrowind teleport doors fire on use, but a door that
--- is merely closed needs the second call to travel.
local EXIT_ACTIVATION_TRIES = 4
--- Frames between progress lines, so a slow walk is visibly a walk and not a hang.
local EXIT_REPORT_EVERY = 90

--- The doors near the player, each paired with the engine object that activates it.
---
--- The pairing is the point: the schema entity is what we reason about and report, the engine
--- object is the only thing `activateBy` accepts, and neither can be derived from the other
--- after the fact.
local function nearbyDoors(from)
  local nearby = engine.nearby()
  local list = nearby and nearby.doors
  if not util.isObject(list) then return {} end
  local out = {}
  for _, raw in ipairs(list) do
    local read = entitiesMod.read(raw, engine.env(), from)
    if read and read.position then out[#out + 1] = { entity = read, object = raw } end
  end
  return out
end

--- Note which door the crosshair is already on, so an existing look is respected rather than
--- overridden (aim.chooseExit uses this).
local function markLookedAt(doors, crosshair)
  local crosshairId = interactMod.objectId(crosshair)
  if not crosshairId then return end
  for _, door in ipairs(doors) do
    if door.entity.id == crosshairId then door.entity.hit = true end
  end
end

--- Start leaving by the nearest door: the console's "Go out" action and the bridge's
--- `world.exit`.
function startExit()
  if not state.director then return false end
  local world = state.snapshot and state.snapshot.world
  local cell = world and world.cell
  state.exit = {
    started = state.frameCount or 0,
    phase = 'seek',
    aimed = false,
    tries = 0,
    cellBefore = cell and cell.name or nil,
    targetId = nil,
    lastReport = 0,
    reason = nil,
  }
  -- stop the idle brain steering, and let our own loop own the frame
  state.executor:clear()
  print('idle-openmw: exit -> looking for a way out of '
    .. tostring(state.exit.cellBefore or '?'))
  return true
end

--- One frame of the exit loop. Called from update() on EVERY frame (not on snapshot ticks)
--- because looking and using want to be responsive, while the idle brain can stay slow.
local function updateExit()
  local exit = state.exit
  if not exit then return end

  local frame = state.frameCount or 0
  local elapsed = frame - (exit.started or frame)
  if elapsed > EXIT_MAX_FRAMES then
    exit.phase = 'failed'
    exit.reason = string.format('gave up after %d frames', elapsed)
    print('idle-openmw: exit -> FAILED: ' .. exit.reason)
    state.exit = nil
    state.executor:clear()
    return
  end

  local env = engine.env()
  local player = playerObject()
  local from = entitiesMod.positionOf(player)
  local reach = interactMod.reach(env)
  local eye = interactMod.eye(env)
  local crosshair = interactMod.crosshairObject(env, eye, player)

  -- ---- pick a target -----------------------------------------------------
  local doors = nearbyDoors(from)
  markLookedAt(doors, crosshair)

  local entities = {}
  local byId = {}
  for _, door in ipairs(doors) do
    entities[#entities + 1] = door.entity
    byId[door.entity.id] = door
  end

  local chosen, why = aimMod.chooseExit(entities, reach, from)
  if not chosen then
    exit.phase = 'failed'
    exit.reason = why
    print('idle-openmw: exit -> FAILED: ' .. tostring(why))
    state.exit = nil
    return
  end
  if exit.targetId ~= chosen.id then
    exit.targetId = chosen.id
    exit.aimed = false
    exit.tries = 0
    print(string.format('idle-openmw: exit -> target %s (%s): %s',
      tostring(chosen.name or chosen.recordId or chosen.id), tostring(chosen.id), tostring(why)))
  end

  local target = byId[chosen.id]
  if not target then
    state.exit = nil
    return
  end

  -- ---- decide the step ---------------------------------------------------
  local decision = aimMod.step(chosen, from, reach, { aimed = exit.aimed })

  if decision.step == 'move' then
    exit.phase = 'move'
    -- the executor's own route: it pathfinds and steers the character controls
    state.executor:submit({ { type = 'move', dest = chosen.position, run = false } })
    if elapsed - (exit.lastReport or 0) >= EXIT_REPORT_EVERY then
      exit.lastReport = elapsed
      print(string.format('idle-openmw: exit -> walking to it (%.0f away, reach %.0f)',
        decision.distance or 0, decision.reach or 0))
    end
    return
  end

  if decision.step == 'aim' then
    exit.phase = 'aim'
    state.executor:clear()   -- arrived: stop walking so the aim is measured standing still
    local trace = interactMod.aimAndVerify(env, target.object, chosen.position, {
      ignore = player, eye = eye,
    })
    if trace.verified then
      exit.aimed = true
      print('idle-openmw: exit -> ' .. interactMod.describeAim(trace)
        .. (trace.above and ' -- it is UP, so we look up' or ''))
    else
      -- not a failure yet: the camera may need a frame to settle before the ray agrees
      if elapsed - (exit.lastReport or 0) >= EXIT_REPORT_EVERY then
        exit.lastReport = elapsed
        print('idle-openmw: exit -> ' .. interactMod.describeAim(trace))
      end
    end
    return
  end

  if decision.step == 'activate' then
    exit.phase = 'activate'
    exit.tries = (exit.tries or 0) + 1
    local result = interactMod.activate(env, target.object, player)
    print(string.format('idle-openmw: exit -> using %s (try %d): %s',
      tostring(chosen.name or chosen.recordId or chosen.id), exit.tries,
      result.ok and 'called' or ('failed: ' .. tostring(result.reason))))
    exit.phase = 'verify'
    exit.verifyAt = frame
    return
  end

  -- ---- verify the outcome ------------------------------------------------
  if exit.phase == 'verify' then
    local world = state.snapshot and state.snapshot.world
    local cell = world and world.cell
    local now = cell and cell.name or nil
    if now and exit.cellBefore and now ~= exit.cellBefore then
      print(string.format('idle-openmw: exit -> OUT: %s -> %s', exit.cellBefore, now))
      state.exit = nil
      return
    end
    -- the snapshot only refreshes on the director's tick, so give it a couple of ticks before
    -- deciding the door did nothing
    local waited = frame - (exit.verifyAt or frame)
    if waited > 120 then
      if (exit.tries or 0) >= EXIT_ACTIVATION_TRIES then
        exit.phase = 'failed'
        exit.reason = 'used it ' .. tostring(exit.tries) .. ' times and did not move'
        print('idle-openmw: exit -> FAILED: ' .. exit.reason)
        state.exit = nil
      else
        -- aim again (the use may have turned the character) and try once more
        exit.phase = 'aim'
        exit.aimed = false
      end
    end
  end
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

      if acting and not state.exit then
        state.executor:submit(result.commands)
      elseif state.exit then
        -- the exit loop owns movement and looking right now: the idle brain must not fight it
        -- for the character controls
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

    -- Announce a change of on-screen UI. This is the machine-readable answer to "what is
    -- the game asking right now", which is otherwise only knowable by squinting at
    -- pixels: the UI mode stack names the open window (Chargen*, Dialogue, Interface,
    -- Loading, ...). Driving character creation without it is guesswork.
    do
      -- Sample dt across frames, not just the first: the first frame of a run legitimately
      -- has dt=0, and one sample cannot tell "dt is always 0" from "dt starts at 0". The
      -- snapshot, the dev channel, the API poll and the heartbeat all accumulate dt, so if
      -- dt never grows, the whole director silently does nothing.
      do
        state.frames = (state.frames or 0) + 1
        local frame = state.frames
        if frame == 1 or frame == 2 or frame == 3 or frame == 60 or frame == 300
          or frame % 600 == 0 then
          pcall(print, 'idle-openmw: frame ' .. frame .. ' dt=' .. tostring(dt)
            .. ' sinceSnapshot=' .. tostring(state.sinceSnapshot))
        end
      end
      -- Read the stack RAW, not through the director's summary: when the summary says
      -- nothing it is because the director is gated, and we would learn nothing about
      -- whether the engine had a mode to report at all.
      local ui = engine.ui()
      local raw = 'no-api'
      if ui and type(ui._getUiModeStack) == 'function' then
        local okStack, stack = pcall(ui._getUiModeStack)
        if not okStack then
          raw = 'error'
        else
          -- stackOf normalises whatever `_getUiModeStack` returns -- a Lua table of mode names
          -- (uibindings.cpp:276-282), though a reader that assumes ONE shape is exactly how a
          -- real window gets called "empty", after which the trace lies about the one thing it
          -- exists to show. stackOf takes either shape and drops unusable entries.
          local modes = uiStateMod.stackOf(stack)
          raw = #modes == 0 and 'empty' or table.concat(modes, ',')
        end
      end
      if raw ~= state.lastUiKey then
        state.lastUiKey = raw
        print('idle-openmw: screen -> ' .. raw)
      end
    end

    -- Announce blocking separately from pausing: "paused" is a state, "blocked" is something
    -- the host must act on, and for a while those looked like the same thing.
    do
      local ui = engine.ui()
      local modes = nil
      if ui and type(ui._getUiModeStack) == 'function' then
        local okStack, stack = pcall(ui._getUiModeStack)
        if okStack and type(stack) == 'table' then modes = stack end
      end
      local paused = engine.isWorldPaused()
      local state_ = uiStateMod.blocking(paused, modes or {})
      if state_.blocked ~= state.wasBlocked or state_.cause ~= state.blockedCause then
        state.wasBlocked = state_.blocked
        state.blockedCause = state_.cause
        if state_.blocked then
          print('idle-openmw: BLOCKED (' .. tostring(state_.cause) .. ') '
            .. tostring(state_.hint or ''))
        else
          print('idle-openmw: unblocked')
        end
      end
    end

    -- Poll the pause state, and announce a CHANGE: a paused game looks exactly like a
    -- broken one from the outside, so the transition is worth a log line.
    local paused = engine.isWorldPaused()
    if paused ~= nil and paused ~= state.paused then
      state.paused = paused
      print('idle-openmw: world ' .. (paused and 'PAUSED' or 'running'))
    end

    -- the dev channel, then any heartbeat the operator asked for
    state.lastDt = dt
    state.frameCount = (state.frameCount or 0) + 1
    -- OBSERVATION TIME vs SIMULATION TIME.
    --
    -- OpenMW hands Lua dt=0 on every frame the world is paused (measured: 0 while paused,
    -- 1/60 while running). Anything accumulating dt therefore stalls exactly when a host
    -- most wants to ask what is wrong. So the observation channels -- the dev command file,
    -- the API requests, the heartbeats -- advance on a nominal frame time instead, while
    -- the director's own tick keeps the real dt and still refuses to act during a pause.
    local observeDt = dt
    if not (type(observeDt) == 'number' and observeDt > 0) then observeDt = 1 / 60 end
    pollDevCommand()
    pollApiRequests()
    -- the exit loop runs EVERY frame, unlike the idle brain: looking at a thing and using it
    -- should not wait for the director's slow tick
    updateExit()
    if state.telemetrySeconds and state.telemetrySeconds > 0 then
      -- frame-counted for the same reason as the pollers: a paused world has dt = 0, and
      -- telemetry that stops the moment the game pauses is telemetry you cannot use to find
      -- out WHY it paused. ~60 frames per requested second.
      if everyFrames(state, 'telemetryTick', math.floor(state.telemetrySeconds * 60)) then
        print(bridge():telemetry())
      end
    end
    if state.heartbeatSeconds and state.heartbeatSeconds > 0 then
      -- Accumulate dt rather than comparing wall clocks: the wall-clock version fired on
      -- EVERY frame (3603 reports in under a minute) and buried the log it was meant to
      -- make readable.
      state.heartbeatElapsed = (state.heartbeatElapsed or 0) + observeDt
      if state.heartbeatElapsed >= state.heartbeatSeconds then
        state.heartbeatElapsed = 0
        reportUi()
      end
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
    -- Report the first few failures to the ENGINE log as well as the activity log: from
    -- outside the game the activity log is invisible, so a director throwing every frame
    -- is indistinguishable from an idle mod. That blindness cost real time.
    if state.failures <= 5 then
      pcall(print, 'idle-openmw: director error (' .. state.failures .. '): ' .. tostring(err))
    end
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
--- Walk out of the building: to the door, look at it, use it (the "Go out" action).
function ACTIONS.go_out() return startExit() end
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

--- The GLOBAL warden reports back on an economy request (see `Executor:_requestEconomy`).
--- A player script cannot remove items or create gold, so "did it actually happen?" is only
--- answerable here -- and a silent failure would look exactly like a working trade.
local function onEconomyApplied(event)
  if not state.director then return end
  pcall(function()
    state.director:logLine(
      ('Economy %s: %s'):format(
        tostring(event.op),
        event.ok and ('done' .. (event.detail and (' (' .. tostring(event.detail) .. ')') or ''))
          or ('FAILED - ' .. tostring(event.detail))),
      event.ok and 'good' or 'bad')
  end)
end

return {
  -- exposed for tests: the throttle that keeps working while the world is paused
  everyFrames = everyFrames,
  engineHandlers = {
    onUpdate = update,
    onSave = onSave,
    onLoad = onLoad,
    onKeyPress = onKeyPress,
  },
  eventHandlers = {
    DialogueResponse = onDialogueResponse,
    IdleOpenMW_GuardianApplied = onGuardianApplied,
    IdleOpenMW_EconomyApplied = onEconomyApplied,
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
      local line = table.concat(parts, ' -- ')
      if state.operatorNote then line = state.operatorNote end
      -- Say when the world is paused: a paused game runs no simulation and takes no input,
      -- so "nothing is happening" and "the mod is stuck" look the same from outside.
      if state.paused == true then line = 'PAUSED -- ' .. line end
      return narrationMod.choose(operatorNarration(), line)
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
