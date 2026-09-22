-- scripts/idle/director.lua
-- The idle director: the brain. It is a PURE function of snapshots -> commands.
--
--   tick(dt, snapshot) -> { goal = <id>, commands = {...}, status = {...} }
--
-- It never touches the engine. The runtime layer (scripts/runtime/*) builds
-- snapshots from `openmw.*`, executes the returned commands, and feeds dialogue
-- events back in. That split is what makes the whole brain testable headlessly.
--
-- SNAPSHOT CONTRACT
-- -----------------
--   snapshot = {
--     player = {                       -- see tests/fixtures/states.lua
--       level, levelProgress,
--       health  = { current, base }, magicka = {...}, fatigue = {...},
--       encumbrance = { current, max },
--       gold, skills = { [id] = {base,modified,progress} },
--       attributes = { [id] = {base,modified} },
--       inventory = { { id, count, value, weight, equipped?, quest? }, ... },
--       position = {x,y,z}, yaw = <radians>, inCombat = bool,
--     },
--     world = {                        -- see tests/fixtures/worlds.lua
--       opportunities = { shop, trainer, healing, rest, talk, quest, loot, unexplored },
--       enemies = <count>, danger = 0..1, junkValue = <gold>,
--       nearest = { shop = { name, position, distance }, trainer, healer, rest, talk, quest, enemy },
--     },
--   }
--
-- COMMAND CONTRACT
-- ----------------
--   { type = 'move',   dest = {x,y,z}, run = bool }
--   { type = 'stop' }
--   { type = 'flee',   from = {x,y,z}, distance = n, run = bool }
--   { type = 'activate', kind = 'shop'|'trainer'|'healer'|'talk'|'quest'|'attack', target = <nearest entry> }
--   { type = 'sell',   plan = {...} }
--   { type = 'buy',    plan = {...} }
--   { type = 'useItem', tag = 'healing'|'magicka'|'fatigue' }
--   { type = 'rest',   hours = n }
--   { type = 'train',  skill = <skillId> }
--   { type = 'wander', radius = n }
--
-- Commands are an ORDERED intent list: e.g. [move, activate] means "walk there,
-- then interact". The executor is responsible for sequencing and reporting back.

local util = require('scripts.idle.util')
local rngMod = require('scripts.idle.rng')
local configMod = require('scripts.idle.config')
local classPriorities = require('scripts.idle.classPriorities')
local statCrunch = require('scripts.idle.statCrunch')
local goalScoring = require('scripts.idle.goalScoring')
local economy = require('scripts.idle.economy')
local dialogue = require('scripts.idle.dialogue')
local directive = require('scripts.idle.directive')
local activityLog = require('scripts.idle.activityLog')
local offlineProgress = require('scripts.idle.offlineProgress')
local worldsense = require('scripts.idle.worldsense')
local lifecycle = require('scripts.idle.lifecycle')

local M = {}

-- Which mode the player is in. Mirrored by uiModel.MODES / uiLayout.MODES.
--   manual    -- the player drives; we emit no commands at all
--   directive -- auto-play, but queued user orders take precedence
--   auto      -- fully self-playing
M.MODES = { 'manual', 'directive', 'auto' }
M.DEFAULT_MODE = 'auto'

-- ---------------------------------------------------------------------------
-- pure planning helpers
-- ---------------------------------------------------------------------------

--- Move command toward a named `nearest` entry, or nil when there is none.
local function moveToEntity(world, key, run)
  local nearest = world and world.nearest and world.nearest[key]
  if not nearest or not nearest.position then return nil end
  return { type = 'move', dest = nearest.position, run = run ~= false, target = nearest }
end

--- The major skill with the lowest current value -- the best thing to train.
function M.lowestMajorSkill(classDef, snapshot)
  local skills = (snapshot and snapshot.player and snapshot.player.skills) or {}
  local best, bestValue = nil, math.huge
  for _, id in ipairs((classDef and classDef.majorSkills) or {}) do
    local entry = skills[id]
    local value = statCrunch.readStat(entry, 5)
    if value < bestValue then best, bestValue = id, value end
  end
  return best
end

--- A point `distance` units directly away from `threat`, starting at `position`.
function M.fleePoint(position, threat, distance)
  if not position or not threat then return nil end
  local dx = (position.x or 0) - (threat.x or 0)
  local dy = (position.y or 0) - (threat.y or 0)
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1e-6 then dx, dy, len = 0, 1, 1 end
  local step = distance or 800
  return {
    x = (position.x or 0) + (dx / len) * step,
    y = (position.y or 0) + (dy / len) * step,
    z = position.z or 0,
  }
end

--- Build the ordered command batch for a goal. Pure -- directly unit-testable.
--- @param goalId string
--- @param statView table result of statCrunch.compute
--- @param world table
--- @param snapshot table
--- @param cfg table
--- @param ctx table { classDef = ..., }
function M.planCommands(goalId, statView, world, snapshot, cfg, ctx)
  ctx = ctx or {}
  local commands = {}
  local player = (snapshot and snapshot.player) or {}
  local inventory = player.inventory or {}

  local function moveThenActivate(key, kind, run)
    local move = moveToEntity(world, key, run)
    if move then commands[#commands + 1] = move end
    local nearest = world and world.nearest and world.nearest[key]
    commands[#commands + 1] = { type = 'activate', kind = kind, target = nearest }
  end

  if goalId == 'survive' then
    if world.nearest and world.nearest.healer then
      moveThenActivate('healer', 'healer', true)
    else
      commands[#commands + 1] = { type = 'useItem', tag = 'healing' }
      commands[#commands + 1] = { type = 'wait', seconds = 5 }
    end

  elseif goalId == 'heal' then
    if world.nearest and world.nearest.healer then
      moveThenActivate('healer', 'healer', false)
    else
      commands[#commands + 1] = { type = 'useItem', tag = 'magicka' }
      commands[#commands + 1] = { type = 'wait', seconds = 5 }
    end

  elseif goalId == 'flee' then
    local enemy = world.nearest and world.nearest.enemy
    local from = enemy and enemy.position or nil
    commands[#commands + 1] = {
      type = 'flee',
      from = from,
      dest = M.fleePoint(player.position, from, 800),
      distance = 800,
      run = true,
    }

  elseif goalId == 'fight' then
    commands[#commands + 1] = { type = 'activate', kind = 'attack', target = world.nearest and world.nearest.enemy }

  elseif goalId == 'rest' then
    local move = moveToEntity(world, 'rest', false)
    if move then commands[#commands + 1] = move end
    commands[#commands + 1] = { type = 'rest', hours = cfg.thresholds.restHours }

  elseif goalId == 'train' then
    moveThenActivate('trainer', 'trainer', false)
    commands[#commands + 1] = { type = 'train', skill = M.lowestMajorSkill(ctx.classDef, snapshot) }

  elseif goalId == 'shop' then
    moveThenActivate('shop', 'shop', false)

  elseif goalId == 'sell_junk' then
    local move = moveToEntity(world, 'shop')
    if move then commands[#commands + 1] = move end
    commands[#commands + 1] = { type = 'sell', plan = economy.planSales(inventory, cfg) }
    commands[#commands + 1] = { type = 'buy', plan = (economy.planPurchases(ctx.desired or {}, world.stock, statView.gold, cfg)) }

  elseif goalId == 'talk' then
    moveThenActivate('talk', 'talk', false)

  elseif goalId == 'quest' then
    moveThenActivate('quest', 'quest', true)

  elseif goalId == 'travel' then
    -- walking up to a silt strider / boat / guild guide opens the travel window
    moveThenActivate('travel', 'travel', false)

  elseif goalId == 'explore' then
    commands[#commands + 1] = { type = 'wander', radius = 1500 }

  elseif goalId == 'idle' then
    commands[#commands + 1] = { type = 'stop' }

  elseif goalId == 'manual' then
    -- the player has the controls; emit nothing at all
    return {}
  end

  return commands
end

-- ---------------------------------------------------------------------------
-- Director
-- ---------------------------------------------------------------------------

local Director = {}
Director.__index = Director

--- @param opts { config?, classDef?, nav?, rng?, log?, now? }
function M.new(opts)
  opts = opts or {}
  local cfg = configMod.validate(configMod.new(opts.config))
  local director = setmetatable({
    cfg = cfg,
    rng = opts.rng or rngMod.new(cfg.debug.seed),
    log = opts.log or activityLog.new(cfg.tick.logLimit),
    nav = opts.nav or nil,
    classDef = opts.classDef or nil,
    desired = opts.desired or {},
    weights = nil,
    goal = nil,
    row = nil,
    ranked = nil,
    view = nil,
    time = 0,
    lastDecisionAt = -math.huge,
    currentGoalAt = -math.huge,
    memory = dialogue.newMemory(),
    dialogueEvents = {},
    mode = (cfg.ui and cfg.ui.startMode) or M.DEFAULT_MODE,
    directives = directive.new(cfg.behaviour.directiveTtl),
    visited = {},
    counters = { ticks = 0, goalChanges = 0, commands = 0 },
  }, Director)

  if director.nav then
    director.route = require('scripts.idle.pathfinder').newRoute(director.nav, cfg)
  end
  director:setClass(director.classDef)
  return director
end

--- (Re)derive the preference weights from a class definition.
function Director:setClass(classDef)
  self.classDef = classDef
  if classDef then
    self.weights = classPriorities.buildWeights(classDef, self.cfg.weightOverrides)
  else
    -- no class: neutral preferences
    self.weights = {}
    for _, cat in ipairs(classPriorities.CATEGORIES) do
      self.weights[cat] = classPriorities.TARGET_MEAN
    end
  end
  return self.weights
end

--- Merge config overrides and revalidate.
function Director:setConfig(overrides)
  self.cfg = configMod.validate(configMod.new(util.merge(self.cfg, overrides or {})))
  if self.route then self.route.cfg = self.cfg end
  self.directives.ttl = self.cfg.behaviour.directiveTtl or directive.DEFAULT_TTL
  self:setClass(self.classDef)
  return self.cfg
end

--- Is `mode` one we understand?
function M.isKnownMode(mode)
  for _, candidate in ipairs(M.MODES) do
    if candidate == mode then return true end
  end
  return false
end

--- Set the play mode. Returns the mode actually in force.
function Director:setMode(mode)
  if not M.isKnownMode(mode) then return self.mode end
  if mode ~= self.mode then
    self.mode = mode
    self:logLine(('Mode: %s'):format(mode), mode == 'manual' and 'warn' or 'info')
  end
  return self.mode
end

--- Cycle manual -> directive -> auto -> manual.
function Director:nextMode()
  for i, candidate in ipairs(M.MODES) do
    if candidate == self.mode then
      return self:setMode(M.MODES[i % #M.MODES + 1])
    end
  end
  return self:setMode(M.DEFAULT_MODE)
end

function Director:isManual() return self.mode == 'manual' end

--- Queue an explicit user directive (the "Directive Auto" mode).
function Director:pushDirective(id, payload)
  local entry = self.directives:push(id, payload, self.time)
  if entry then self:logLine(('Directive: %s'):format(id), 'warn') end
  return entry
end

--- The directive currently in force, or nil.
function Director:currentDirective() return self.directives:peek(self.time) end

--- Cancel all queued directives.
function Director:clearDirectives()
  self.directives:clear()
  return self
end

function Director:logLine(message, level)
  return self.log:add(message, level or 'info', self.time)
end

--- One decision cycle. May be called at any rate; it throttles internally.
function Director:tick(dt, snapshot)
  dt = dt or 0
  snapshot = snapshot or {}
  self.time = self.time + dt
  self.counters.ticks = self.counters.ticks + 1

  local view = statCrunch.compute(snapshot.player or {}, self.classDef)
  local world = snapshot.world or {}
  self.view = view
  self.snapshot = snapshot

  local natural, ranked, naturalRow = goalScoring.select(view, self.weights, world, self.cfg)
  self.ranked = ranked

  -- Where are we in the game's life? During character creation, the main menu or
  -- a load screen the director must not touch the character at all: emitting
  -- movement/act commands there fights the engine's own chargen flow and can
  -- strand the player before Seyda Neen (scripts/idle/lifecycle.lua).
  local phase = snapshot.phase or lifecycle.describe('world')
  self.phase = phase
  self.ui = snapshot.ui

  if not phase.acting then
    self.goal = phase.id
    self.row = { id = phase.id, score = 0, need = 0, opportunity = 0, risk = 0,
                 aptitude = 0, bias = 0, reason = phase.note or phase.label }
    self.commands = {}
    return { goal = self.goal, commands = {}, status = self:status() }
  end

  -- A user directive overrides the director's own choice -- except when the
  -- character is in immediate danger, where safety always wins.
  local pending = self.directives:peek(self.time)
  local chosen, row
  local emergency = (natural == 'survive' or natural == 'flee')
  if self.mode == 'manual' then
    -- the player has the controls: report but do nothing
    chosen = 'manual'
    row = {
      id = 'manual', score = 0, need = 0, opportunity = 0, risk = 0,
      aptitude = 0, bias = 0, reason = 'you have the controls',
    }
  elseif not emergency and pending then
    chosen = pending.goal
    row = {
      id = chosen, score = math.huge, need = 1, opportunity = 1, risk = 0,
      aptitude = 1, bias = 1, reason = 'directive: ' .. pending.id,
    }
  else
    chosen, row = natural, naturalRow
  end

  local changed = (chosen ~= self.goal)
  local stale = (self.time - self.lastDecisionAt) >= self.cfg.tick.interval

  if changed or stale or emergency then
    if changed then
      self.counters.goalChanges = self.counters.goalChanges + 1
      self:logLine(('→ %s%s'):format(chosen, row and row.reason and (' (' .. row.reason .. ')') or ''))
    end
    self.goal = chosen
    self.row = row
    self.lastDecisionAt = self.time
  end

  local commands = M.planCommands(self.goal, view, world, snapshot, self.cfg, {
    classDef = self.classDef,
    desired = self.desired,
  })
  self.commands = commands
  self.counters.commands = self.counters.commands + #commands

  return { goal = self.goal, commands = commands, status = self:status() }
end

--- Feed a DialogueResponse event in (observe-only; see scripts/idle/dialogue.lua).
function Director:onDialogue(event)
  local parsed = dialogue.parse(event)
  if not parsed then return nil end
  self.memory:observe(parsed, self.time)

  -- keep a short transcript for the console's Talk tab
  self.dialogueEvents[#self.dialogueEvents + 1] = {
    actor = dialogue.actorId(parsed.actor),
    kind = parsed.kind,
    recordId = parsed.recordId,
    time = self.time,
    description = dialogue.describe(parsed),
  }
  while #self.dialogueEvents > 20 do table.remove(self.dialogueEvents, 1) end

  local action = dialogue.interpret(parsed)
  if action.intent ~= 'ignore' then
    self:logLine(dialogue.describe(parsed), action.intent == 'note_refusal' and 'warn' or 'info')
  end
  return action
end

--- Record that the player has been in a cell (drives the "unexplored" signal).
function Director:markVisited(cellName)
  if type(cellName) == 'string' then self.visited[cellName] = true end
  return self.visited
end

--- Award offline catch-up. Returns the award table.
function Director:applyOffline(elapsedSeconds)
  local award = offlineProgress.compute(elapsedSeconds, self.cfg)
  if award.applied then
    self.gold = (self.gold or 0) + award.gold
    self:logLine('Offline: ' .. offlineProgress.describe(award), 'good')
  end
  return award
end

--- Data for the HUD.
function Director:status()
  local view = self.view or {}
  local top = {}
  for i = 1, math.min(3, #(self.ranked or {})) do
    local entry = self.ranked[i]
    top[#top + 1] = { id = entry.id, score = util.round(entry.score, 3) }
  end
  return {
    goal = self.goal,
    reason = self.row and self.row.reason or nil,
    directive = self:currentDirective() and self:currentDirective().id or nil,
    mode = self.mode,
    phase = self.phase and self.phase.id or nil,
    phaseLabel = self.phase and self.phase.label or nil,
    acting = self.phase ~= nil and self.phase.acting == true,
    uiMode = self.ui and self.ui.mode or nil,
    uiKind = self.ui and self.ui.kind or nil,
    uiLabel = self.ui and self.ui.label or nil,
    level = view.level,
    gold = view.gold or 0,
    healthFraction = view.healthFraction or 1,
    magickaFraction = view.magickaFraction or 1,
    fatigueFraction = view.fatigueFraction or 1,
    encumbranceFraction = view.encumbranceFraction or 0,
    topGoals = top,
    counters = util.copy(self.counters),
    log = self.log:recent(6),
    time = self.time,
  }
end

--- Everything the console UI needs from the director (the engine-derived parts
--- are added by runtime/observer.lua:readPanel). See scripts/idle/uiModel.lua
--- for the full panel-snapshot contract.
function Director:panelData()
  local nearest = self.snapshot and self.snapshot.world and self.snapshot.world.nearest
  return {
    status = self:status(),
    mode = self.mode,
    directive = self:currentDirective() and self:currentDirective().id or nil,
    -- Where we are in the game's life, and what the engine has on screen. The
    -- console shows this so the player can tell "the bot is idle" from "the bot
    -- is holding fire because you are still creating a character".
    phase = self.phase,
    ui = self.ui,
    dialogue = self.dialogueEvents,
    topics = self.memory:knownTopics(),
    log = self.log:recent(60),
    -- Travel destinations offered by the nearest travel service, so the console
    -- can list them even though autonomous travel is off by default.
    travel = worldsense.destinationsOf(nearest and nearest.travel),
    travelService = nearest and nearest.travel and nearest.travel.name or nil,
  }
end

--- Persistable state. `now` (wall-clock) is supplied by the runtime.
function Director:serialize(now)
  return {
    version = 1,
    time = self.time,
    goal = self.goal,
    mode = self.mode,
    gold = self.gold,
    rngState = self.rng:getState(),
    memory = self.memory:serialize(),
    visited = self.visited,
    counters = util.copy(self.counters),
    lastSeen = now,
  }
end

--- Restore persisted state (does not recompute the class).
function Director:load(data)
  if type(data) ~= 'table' then return self end
  self.time = data.time or 0
  self.goal = data.goal
  self.gold = data.gold
  if data.mode and M.isKnownMode(data.mode) then self.mode = data.mode end
  self.counters = data.counters or self.counters
  if data.rngState then self.rng:setState(data.rngState) end
  if data.memory then self.memory:load(data.memory) end
  if type(data.visited) == 'table' then self.visited = data.visited end
  return self
end

M.Director = Director

return M
