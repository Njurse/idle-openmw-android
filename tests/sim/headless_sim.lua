-- tests/sim/headless_sim.lua
-- Long-run headless simulation: drives the director for a large number of
-- simulated game-hours against a lightweight world model, and asserts the
-- invariants the project plan asks for:
--
--   * no crashes / no thrown errors,
--   * gold generally increases (and does not run away),
--   * the character does not get stuck on one goal forever,
--   * class priorities are respected (a warrior picks fights a mage does not),
--   * offline catch-up actually applies.
--
-- Run it with:  python tools/run_tests.py --sim --hours 1000 --seed 7
--
-- It runs in the host Lua VM, no engine involved -- the world model below plays
-- the part of OpenMW and applies the director's commands to its own state.

local directorMod = require('scripts.idle.director')
local configMod = require('scripts.idle.config')
local classPriorities = require('scripts.idle.classPriorities')
local statCrunch = require('scripts.idle.statCrunch')
local rngMod = require('scripts.idle.rng')
local offlineProgress = require('scripts.idle.offlineProgress')
local util = require('scripts.idle.util')

local HOURS = tonumber(_G.SIM_HOURS) or 1000
local SEED = tonumber(_G.SIM_SEED) or 1337
local VERBOSE = _G.SIM_VERBOSE == '1'
local STEP_SECONDS = 30 -- simulated seconds per iteration

-- ---------------------------------------------------------------------------
-- world model
-- ---------------------------------------------------------------------------

local SKILL_IDS = {
  'longblade', 'bluntweapon', 'block', 'armorer', 'athletics', 'marksman',
  'destruction', 'mysticism', 'alteration', 'illusion', 'conjuration',
  'restoration', 'alchemy', 'enchant', 'sneak', 'security', 'lightarmor',
  'shortblade', 'acrobatics', 'mercantile', 'speechcraft', 'handtohand', 'unarmored',
}

local World = {}
World.__index = World

function World.new(seed)
  local rng = rngMod.new(seed)
  local skills = {}
  for _, id in ipairs(SKILL_IDS) do
    local base = 5 + rng:range(0, 20)
    skills[id] = { base = base, modified = base, progress = 0 }
  end
  -- make it recognisably a warrior
  for _, id in ipairs({ 'longblade', 'heavyarmor', 'block', 'armorer', 'athletics' }) do
    skills[id] = { base = 45 + rng:range(0, 25), modified = 45, progress = 0 }
    skills[id].modified = skills[id].base
  end

  return setmetatable({
    rng = rng,
    position = { x = 0, y = 0, z = 0 },
    gold = 250,
    startingGold = 250,
    health = { current = 100, base = 100 },
    magicka = { current = 60, base = 60 },
    fatigue = { current = 120, base = 120 },
    encumbrance = { current = 40, max = 250 },
    inventory = {
      { id = 'chitin dagger', count = 2, value = 8, weight = 4 },
      { id = 'longsword', count = 1, value = 90, weight = 15, equipped = true },
    },
    skills = skills,
    attributes = {
      strength = { base = 60, modified = 60 }, endurance = { base = 58, modified = 58 },
      agility = { base = 44, modified = 44 }, speed = { base = 44, modified = 44 },
      personality = { base = 34, modified = 34 }, luck = { base = 40, modified = 40 },
      intelligence = { base = 34, modified = 34 }, willpower = { base = 36, modified = 36 },
    },
    tickCount = 0,
    goldHistory = {},
    goalCounts = {},
    maxStreak = 0,
    currentStreak = 0,
    lastGoal = nil,
  }, World)
end

--- Somewhere between a town and the wilds, drifting over time.
function World:scan()
  local phase = math.floor(self.tickCount / 400) % 3
  local rng = self.rng
  local opportunities = { shop = 0, trainer = 0, healing = 0, rest = 0.3, talk = 0, quest = 0,
                         loot = 0, unexplored = 0, travel = 0, repair = 0, enchant = 0 }
  local enemies, danger = 0, 0

  if phase == 0 then
    opportunities.shop = 0.9
    opportunities.trainer = 0.8
    opportunities.talk = 0.9
    opportunities.healing = 0.7
    opportunities.travel = 0.75
    opportunities.unexplored = 0.2
  elseif phase == 1 then
    opportunities.unexplored = rng:uniform(0.4, 0.95)
    opportunities.loot = rng:uniform(0.2, 0.9)
    enemies = rng:range(0, 3)
    danger = util.clamp(enemies * rng:uniform(0.08, 0.3), 0, 1)
  else
    opportunities.unexplored = 0.6
    opportunities.quest = rng:uniform(0.2, 0.8)
    enemies = rng:range(0, 2)
    danger = util.clamp(enemies * 0.2, 0, 1)
  end

  local nearest = {
    shop = { name = 'Trader', position = { x = 200, y = 0, z = 0 }, distance = 200 },
    trainer = { name = 'Trainer', position = { x = 250, y = 0, z = 0 }, distance = 250 },
    healer = { name = 'Healer', position = { x = 300, y = 0, z = 0 }, distance = 300 },
    rest = { name = 'Bed', position = { x = 50, y = 0, z = 0 }, distance = 50 },
    talk = { name = 'Villager', position = { x = 120, y = 0, z = 0 }, distance = 120 },
    travel = { name = 'Silt strider', position = { x = 600, y = 0, z = 0 }, distance = 600,
               travelDestinations = { { cell = 'Balmora' }, { cell = 'Vivec' } } },
  }
  if enemies > 0 then
    nearest.enemy = { name = 'Cliff racer', position = { x = 400, y = 0, z = 0 }, distance = 400 }
  end

  return {
    opportunities = opportunities,
    enemies = enemies,
    danger = danger,
    junkValue = 0,
    nearest = nearest,
    enemies_nearby = enemies > 0 and { { level = math.max(1, enemies * 3) } } or {},
  }
end

function World:snapshot(cfg)
  local world = self:scan()
  world.junkValue = require('scripts.idle.economy').junkValue(self.inventory, cfg)
  return {
    player = {
      level = 5,
      health = self.health,
      magicka = self.magicka,
      fatigue = self.fatigue,
      encumbrance = self.encumbrance,
      gold = self.gold,
      skills = self.skills,
      attributes = self.attributes,
      inventory = self.inventory,
      position = self.position,
      cell = { name = 'Simulated', isExterior = true },
    },
    world = world,
  }
end

function World:recordGoal(goal)
  self.goalCounts[goal] = (self.goalCounts[goal] or 0) + 1
  if goal == self.lastGoal then
    self.currentStreak = self.currentStreak + 1
  else
    self.currentStreak = 1
    self.lastGoal = goal
  end
  self.maxStreak = math.max(self.maxStreak, self.currentStreak)
end

function World:updateEncumbrance()
  local carried = 0
  for _, item in ipairs(self.inventory) do
    carried = carried + (item.weight or 0) * (item.count or 1)
  end
  self.encumbrance.current = carried
end

--- Apply the director's command batch to the model.
function World:apply(commands, cfg)
  local rng = self.rng
  for _, command in ipairs(commands or {}) do
    if command.type == 'move' and command.dest then
      self.position = { x = command.dest.x or 0, y = command.dest.y or 0, z = command.dest.z or 0 }
    elseif command.type == 'flee' then
      self.health.current = math.min(self.health.base, self.health.current + 5)
      self.position = { x = (self.position.x or 0) + 500, y = 0, z = 0 }
    elseif command.type == 'rest' then
      self.fatigue.current = self.fatigue.base
      self.health.current = math.min(self.health.base, self.health.current + 25)
      self.magicka.current = self.magicka.base
    elseif command.type == 'useItem' then
      self.health.current = math.min(self.health.base, self.health.current + 60)
    elseif command.type == 'sell' then
      local gold = 0
      for _, entry in ipairs(command.plan or {}) do
        for _, item in ipairs(self.inventory) do
          if item.id == entry.id then
            gold = gold + math.floor(item.count * (item.value or 0) * cfg.behaviour.barterRatio)
            item.count = 0
          end
        end
      end
      self.gold = self.gold + gold
      local kept = {}
      for _, item in ipairs(self.inventory) do
        if item.count > 0 then kept[#kept + 1] = item end
      end
      self.inventory = kept
      self:updateEncumbrance()
    elseif command.type == 'buy' then
      for _, entry in ipairs(command.plan or {}) do
        local cost = (entry.unitValue or 0) * (entry.count or 1)
        if self.gold >= cost then
          self.gold = self.gold - cost
          self.inventory[#self.inventory + 1] = {
            id = entry.id, count = entry.count or 1, value = 25, weight = 0.5,
          }
          self:updateEncumbrance()
        end
      end
    elseif command.type == 'train' and command.skill then
      local skill = self.skills[command.skill]
      if skill then
        local cost = (cfg.behaviour.trainGoldPerLevel or 0) * 5
        if self.gold >= cost then
          self.gold = self.gold - cost
          skill.progress = math.min(1, (skill.progress or 0) + 0.2)
          if skill.progress >= 1 then
            skill.progress = 0
            skill.base = skill.base + 1
            skill.modified = skill.base
          end
        end
      end
    elseif command.type == 'activate' then
      if command.kind == 'attack' then
        -- combat: trade damage, sometimes earn loot
        self.health.current = math.max(1, self.health.current - rng:range(2, 12))
        if rng:chance(0.5) then
          self.gold = self.gold + rng:range(5, 40)
        end
      elseif command.kind == 'healer' then
        self.health.current = self.health.base
      end
    elseif command.type == 'explore' or command.type == 'wander' then
      self.position = { x = (self.position.x or 0) + rng:range(-400, 400), y = 0, z = 0 }
    end
  end

  -- natural regeneration and attrition each step
  self.fatigue.current = math.max(0, self.fatigue.current - 0.4)
  self.goldHistory[#self.goldHistory + 1] = self.gold
end

-- ---------------------------------------------------------------------------
-- the run
-- ---------------------------------------------------------------------------

local function run(seed, classDef)
  local cfg = configMod.new({ debug = { seed = seed } })
  local director = directorMod.new({ classDef = classDef, config = cfg })
  local world = World.new(seed)
  local steps = math.floor(HOURS * 3600 / STEP_SECONDS)
  local errors = 0

  for _ = 1, steps do
    world.tickCount = world.tickCount + 1
    local ok, err = pcall(function()
      local snapshot = world:snapshot(cfg)
      local result = director:tick(STEP_SECONDS, snapshot)
      world:recordGoal(result.goal)
      world:apply(result.commands, cfg)
    end)
    if not ok then
      errors = errors + 1
      if VERBOSE and errors <= 3 then print('  sim error: ' .. tostring(err)) end
      if errors > 10 then break end
    end
  end

  return { cfg = cfg, director = director, world = world, errors = errors, steps = steps }
end

local function share(runResult, goals)
  local world = runResult.world
  local total = 0
  for _, count in pairs(world.goalCounts) do total = total + count end
  local hits = 0
  for _, goal in ipairs(goals) do hits = hits + (world.goalCounts[goal] or 0) end
  if total == 0 then return 0 end
  return hits / total
end

local function mean(list)
  if #list == 0 then return 0 end
  local total = 0
  for _, value in ipairs(list) do total = total + value end
  return total / #list
end

local function tail(list, fraction)
  local count = math.max(1, math.floor(#list * fraction))
  local out = {}
  for i = #list - count + 1, #list do out[#out + 1] = list[i] end
  return out
end

-- ---------------------------------------------------------------------------
-- invariants
-- ---------------------------------------------------------------------------

local failures = {}
local function check(condition, message)
  if not condition then failures[#failures + 1] = message end
  return condition
end

local startedAt = os.clock()
local warrior = run(SEED, classPriorities.presets.warrior)
local elapsed = os.clock() - startedAt

local goldHistory = warrior.world.goldHistory
local goldHead = mean(tail(goldHistory, 0.1))
local goldTail = mean({ goldHistory[#goldHistory], goldHistory[#goldHistory - 1] or 0,
                        goldHistory[#goldHistory - 2] or 0 })

check(warrior.errors == 0, ('director threw %d time(s)'):format(warrior.errors))
check(goldTail > goldHead, ('gold did not grow: head %.0f -> tail %.0f'):format(goldHead, goldTail))
check(warrior.world.gold > warrior.world.startingGold, 'final gold did not exceed the starting purse')
check(warrior.world.gold < warrior.world.startingGold + HOURS * 100, 'gold grew implausibly fast')

local goalTotal = 0
for _, count in pairs(warrior.world.goalCounts) do goalTotal = goalTotal + count end
check(goalTotal > 0, 'the director never chose a goal')
check(warrior.world.maxStreak < warrior.steps * 0.5,
  ('director got stuck: longest identical-goal streak was %d of %d steps')
    :format(warrior.world.maxStreak, warrior.steps))

-- at least a handful of distinct behaviours must actually occur
local distinct = 0
for _ in pairs(warrior.world.goalCounts) do distinct = distinct + 1 end
check(distinct >= 3, ('only %d distinct goals occurred'):format(distinct))

-- determinism
local repeatRun = run(SEED, classPriorities.presets.warrior)
check(repeatRun.world.gold == warrior.world.gold, 'the simulation is not deterministic for a fixed seed')

-- class priorities
local mage = run(SEED, classPriorities.presets.mage)
local warriorCombat = share(warrior, { 'fight', 'flee', 'survive' })
local mageCombat = share(mage, { 'fight', 'flee', 'survive' })
local warriorHeal = share(warrior, { 'heal' })
local mageHeal = share(mage, { 'heal' })
check(warriorCombat >= mageCombat,
  ('warrior was less combative than the mage (%.2f vs %.2f)'):format(warriorCombat, mageCombat))
check(mageHeal >= warriorHeal,
  ('mage healed less often than the warrior (%.2f vs %.2f)'):format(mageHeal, warriorHeal))

-- offline catch-up
local offlineAward = offlineProgress.compute(2 * 3600, warrior.cfg)
check(offlineAward.applied and offlineAward.gold > 0, 'offline progress did not apply')

-- an empty world must not crash the director
local emptyOk = pcall(function()
  local d = directorMod.new({ classDef = classPriorities.presets.warrior })
  d:tick(1, {})
end)
check(emptyOk, 'the director threw on an empty snapshot')

-- ---------------------------------------------------------------------------
-- report
-- ---------------------------------------------------------------------------

local function line(message) print('  ' .. message) end

print(('%d simulated hours  ·  %d steps  ·  seed %d  ·  %.2fs'):format(HOURS, warrior.steps, SEED, elapsed))
line(('goals: %s'):format(table.concat(util.map(util.sortedKeys(warrior.world.goalCounts),
  function(id) return ('%s=%d'):format(id, warrior.world.goalCounts[id]) end), ' ')))
line(('gold: %d -> %d'):format(warrior.world.startingGold, warrior.world.gold))
line(('warrior combat share %.2f vs mage %.2f'):format(warriorCombat, mageCombat))
line(('warrior goal changes: %d, log lines: %d'):format(
  warrior.director.counters.goalChanges, warrior.director.log:count()))

_G.SIM_RESULT = {
  ok = (#failures == 0),
  hours = HOURS,
  seed = SEED,
  steps = warrior.steps,
  errors = warrior.errors,
  goldStart = warrior.world.startingGold,
  goldEnd = warrior.world.gold,
  distinctGoals = distinct,
  maxStreak = warrior.world.maxStreak,
  failures = #failures,
}

if #failures > 0 then
  print('\n  SIMULATION FAILURES:')
  for _, message in ipairs(failures) do print('   ✗ ' .. message) end
  print('')
else
  print('  all invariants held\n')
end

-- ---------------------------------------------------------------------------
-- development trace (HARNESS_TRACE=1 -> `python tools/run_tests.py --sim --trace`)
-- ---------------------------------------------------------------------------
-- The decision timeline: every goal transition and order, in order, with the
-- reason and the command count. This is the thing to read when a long run goes
-- wrong -- scripts/idle/trace.lua.
if os ~= nil and type(os.getenv) == 'function' and os.getenv('HARNESS_TRACE') then
  local limit = tonumber(os.getenv('HARNESS_TRACE_LINES')) or 60
  print(('  trace (%s):'):format(warrior.director:traceSummary()))
  local lines = warrior.director:traceLines(limit)
  local skipped = math.max(0, warrior.director.trace:count() - limit)
  if skipped > 0 then line(('... (%d earlier events)'):format(skipped)) end
  for _, l in ipairs(lines) do line(l) end
  print('')
end

return #failures == 0
