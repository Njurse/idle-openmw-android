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
local traceMod = require('scripts.idle.trace')

local M = {}

--- Goals that are allowed to produce NO command.
---
--- Everything else must either act or hand over: a goal with nothing to act on ('flee' with no
--- threat, 'fight' with nothing in reach) otherwise parks the character forever while the reason
--- line still claims it is doing something.
local PASSIVE_GOALS = { idle = true, manual = true }

--- U+2192 RIGHTWARDS ARROW, as bytes: see the ASCII policy in AGENTS.md.
local ARROW = string.char(226, 134, 146)

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
--- Should we switch goals, or stay? (Pure; see the call site for the why.)
--- Returns the possibly-unchanged `(goal, row)`.
function M.applyHysteresis(goal, row, current, ranked, cfg)
  local margin = (cfg and cfg.behaviour and cfg.behaviour.hysteresis) or 0
  if margin <= 0 or not current or not goal or goal == current then return goal, row end
  -- never get in the way of an emergency
  if goal == 'survive' or goal == 'flee' then return goal, row end
  if current == 'idle' or current == 'survive' or current == 'flee' then return goal, row end
  local currentRow = util.firstWhere(ranked or {}, function(r) return r.id == current end)
  -- drop the current goal the moment it stops being viable
  if not currentRow or (currentRow.need or 0) <= 0 or (currentRow.score or 0) <= 0 then
    return goal, row
  end
  local best = row and (row.score or 0) or 0
  if best < (currentRow.score or 0) * (1 + margin) then
    return current, currentRow
  end
  return goal, row
end

function M.planCommands(goalId, statView, world, snapshot, cfg, ctx)
  ctx = ctx or {}
  local commands = {}
  local player = (snapshot and snapshot.player) or {}
  local inventory = player.inventory or {}

  local function moveThenActivate(key, kind, run)
    local nearest = world and world.nearest and world.nearest[key]
    -- Nothing to act on? Emit NOTHING, so the goal falls through to one that can act (see
    -- Director:tick). Emitting an attack with a nil target is a command that cannot do anything.
    if not nearest then return end
    -- CLOSE ENOUGH TO ACT? THEN DO NOT WALK FIRST. `move` is BLOCKING in the executor, so the
    -- activate behind it waits for the route to report arrival -- and a route to a CREATURE can
    -- never arrive, because the character cannot stand inside the thing it is attacking. Body
    -- radii floor the distance at roughly 100 units against an arrival tolerance of 96, so the
    -- route hovers just short forever and the attack behind it never runs. Measured live: distance
    -- oscillating 106.7 - 110.9 while a mudcrab sat at 15 hp and `moving` stayed true.
    --
    -- So proximity to the target, not path arrival, gates acting on it.
    local range = (cfg and cfg.behaviour and cfg.behaviour.interactRange) or nil
    local inReach = range ~= nil and nearest.distance ~= nil and nearest.distance <= range
    if not inReach then
      local move = moveToEntity(world, key, run)
      if move then commands[#commands + 1] = move end
    end
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
    -- A character with nothing to DRAW cannot attack: `activateBy` does nothing at all with the
    -- hands empty, so this is a goal that cannot act (measured live -- the character walked to a
    -- slaughterfish, swung indefinitely and never drew). Emit NOTHING, and the fall-through in
    -- Director:tick hands over to a goal that can.
    local player = snapshot and snapshot.player
    -- `return commands` (the empty table), NOT a bare `return`: a bare return gives nil, and the
    -- fall-through in Director:tick asks `#alternative > 0`, which would throw on nil.
    if player and player.canFight == false then return commands end
    -- Move INTO reach first. Attacking a creature thousands of units away is a "goal that cannot
    -- act" wearing a command: the character stands still and swings at air.
    moveThenActivate('enemy', 'attack', true)

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

  elseif goalId == 'go_town' then
    -- "Take me somewhere with people." Prefer a service that relocates you (silt
    -- strider / boat / guild guide -- its window lists the destinations), else
    -- walk to the nearest town-ish fixture. Directive-only: it is never scored.
    local nearest = (world and world.nearest) or {}
    if nearest.travel then
      moveThenActivate('travel', 'travel', false)
    else
      local townKey = nearest.shop and 'shop'
        or (nearest.healer and 'healer')
        or (nearest.trainer and 'trainer')
      if townKey then
        moveThenActivate(townKey, townKey, false)
      else
        commands[#commands + 1] = { type = 'wander', radius = 3000 }
      end
    end

  elseif goalId == 'idle' then
    commands[#commands + 1] = { type = 'stop' }

  elseif goalId == 'walk_to' then
    -- Tap-to-move: the *runtime* did the raycast and put the decision on the
    -- directive payload (scripts/idle/tapMove.lua). Emit the walk, and the
    -- interaction when the tap landed on something you can use.
    local intent = ctx.directive and ctx.directive.payload
    if type(intent) == 'table' and intent.dest then
      commands[#commands + 1] = { type = 'move', dest = intent.dest, run = intent.run == true }
      if intent.target then
        commands[#commands + 1] = { type = 'activate', kind = intent.kind, target = intent.target }
      end
    else
      commands[#commands + 1] = { type = 'stop' }
    end

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
    -- Development trace: every decision, with its numbers (scripts/idle/trace.lua).
    trace = traceMod.new(400),
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
  if entry then self.trace:add('order', id, self.time) end
  return entry
end

--- Development trace helpers (scripts/idle/trace.lua). The trace records goal
--- transitions, directives and dialogue, with their numbers -- the thing you
--- read when a long run goes wrong. `tools/run_tests.py --trace` prints it.
function Director:traceLines(n) return self.trace:lines(n) end
function Director:traceSummary() return self.trace:summary() end

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

  -- Goal hysteresis. Without it the director flaps between comparable goals: the
  -- decision trace showed `quest` <-> `fight` changing almost every step (~40% of
  -- all steps -- docs/observability.md). Keep the goal we are on unless another
  -- beats it by a margin. Emergencies ignore this: flee/survive always take over,
  -- and a goal that is no longer viable (need 0) is dropped at once.
  natural, naturalRow = M.applyHysteresis(natural, naturalRow, self.goal, ranked, self.cfg)

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
    self.trace:add('phase', phase.id, self.time)
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

  local ctx = {
    classDef = self.classDef,
    desired = self.desired,
    -- The directive in force, so a goal whose behaviour depends on it (walk_to)
    -- can read it (scripts/idle/tapMove.lua).
    directive = pending,
  }
  local commands = M.planCommands(chosen, view, world, snapshot, self.cfg, ctx)

  -- FALL THROUGH when the chosen goal cannot act.
  --
  -- 'flee' with no threat to flee from, or 'fight' with nothing in reach, produces NO command --
  -- and a goal that produces nothing parks the character while the reason line still claims it is
  -- doing something. Measured live: the director sat on `fight` in Seyda Neen and never moved.
  -- Only genuinely passive goals are allowed to be empty.
  if #commands == 0 and not PASSIVE_GOALS[chosen] then
    for _, entry in ipairs(self.ranked or {}) do
      if entry.id ~= chosen and not PASSIVE_GOALS[entry.id] then
        local alternative = M.planCommands(entry.id, view, world, snapshot, self.cfg, ctx)
        if #alternative > 0 then
          -- the arrow is built as bytes: a literal one in source is the exact mangling
          -- the repo's ASCII policy exists to prevent (AGENTS.md, tools/dev/check_ascii.py)
          self:logLine((ARROW .. ' %s (%s had nothing to act on)'):format(entry.id, chosen))
          chosen, row, commands = entry.id, entry, alternative
          break
        end
      end
    end
  end

  local changed = (chosen ~= self.goal)
  local stale = (self.time - self.lastDecisionAt) >= self.cfg.tick.interval

  if changed or stale or emergency then
    if changed then
      self.counters.goalChanges = self.counters.goalChanges + 1
      self:logLine((ARROW .. ' %s%s'):format(chosen, row and row.reason and (' (' .. row.reason .. ')') or ''))
    end
    self.goal = chosen
    self.row = row
    self.lastDecisionAt = self.time
  end

  self.commands = commands
  self.counters.commands = self.counters.commands + #commands

  -- Trace the transition (not every tick): this is the timeline you read when a
  -- run goes wrong -- see scripts/idle/trace.lua and tools/run_tests.py --trace.
  if changed or emergency then
    self.trace:add('goal', ('%s%s'):format(chosen, row and row.reason and (' (' .. row.reason .. ')') or ''),
      self.time, { ('cmds=%d'):format(#commands) })
  end

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
