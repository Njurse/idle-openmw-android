-- scripts/idle/goalScoring.lua
-- The decision core: given (preferences, capability, world) pick the single best
-- thing to do next.
--
--   score(goal) = bias(goal)
--               * aptitude(goal)          -- mean of weights[c] * capability[c]
--               * need(goal)              -- 0..1, "how badly is it wanted now"
--               * opportunity(goal)       -- 0..1, "how reachable is it now"
--               * (1 + levelScaling * level)
--               - riskWeight(goal) * risk(goal) * RISK_SCALE
--
-- The formula is deliberately transparent: every factor is inspectable from the
-- returned ranking, which the HUD surfaces and the specs assert on.
--
-- Pure: no engine, no I/O.

local util = require('scripts.idle.util')
local classPriorities = require('scripts.idle.classPriorities')

local M = {}

M.RISK_SCALE = 2.0

--: Autonomous roaming bumps, applied to the `explore` goal when
--: `behaviour.roam` is on (see M.scoreAll).
M.ROAM = { bias = 1.0, opportunityFloor = 0.35 }

-- ---------------------------------------------------------------------------
-- small accessors over the world snapshot
-- ---------------------------------------------------------------------------

local function opp(world, key)
  local opportunities = (world and world.opportunities) or {}
  return util.clamp(opportunities[key] or 0, 0, 1)
end
M.opportunity = opp

local function enemies(world) return util.clamp((world and world.enemies) or 0, 0, 999) end
local function danger(world) return util.clamp((world and world.danger) or 0, 0, 1) end

-- ---------------------------------------------------------------------------
-- goal definitions
-- ---------------------------------------------------------------------------

--- @field id           stable identifier (also the command the director emits)
--- @field categories   behaviour categories that make this goal "apt"
--- @field need         function(statView, world, cfg) -> 0..1
--- @field opportunity  function(statView, world, cfg) -> 0..1
--- @field risk         function(statView, world, cfg) -> 0..1 (optional)
--- @field riskWeight   multiplier on the risk penalty (default 1)
--- @field reason       function(statView, world, cfg) -> string (optional)
M.GOALS = {
  {
    id = 'survive', categories = { 'combat', 'magic' },
    need = function(s, _, cfg)
      if s.healthFraction <= cfg.thresholds.criticalHealth then return 1.0 end
      if s.healthFraction <= cfg.thresholds.lowHealth then return 0.45 end
      return 0
    end,
    opportunity = function() return 1.0 end,
    reason = function(s, _, cfg)
      return ('health %d%% (critical at %d%%)'):format(math.floor(s.healthFraction * 100),
        math.floor(cfg.thresholds.criticalHealth * 100))
    end,
  },
  {
    id = 'heal', categories = { 'magic' },
    need = function(s, _, cfg)
      if s.magickaFraction <= cfg.thresholds.lowMagicka then return 0.8 end
      if s.magickaFraction <= 0.5 then return 0.3 end
      return 0
    end,
    opportunity = function(_, world) return math.max(opp(world, 'healing'), 0.4) end,
    reason = function(s) return ('magicka %d%%'):format(math.floor(s.magickaFraction * 100)) end,
  },
  {
    id = 'flee', categories = { 'combat', 'stealth' }, riskWeight = 0,
    need = function(s, world, cfg)
      if enemies(world) == 0 then return 0 end
      if danger(world) >= cfg.thresholds.dangerFlee then return 1.0 end
      if s.healthFraction <= cfg.thresholds.fleeHealthFraction then return 1.0 end
      return 0
    end,
    opportunity = function(_, world) return enemies(world) > 0 and 1 or 0 end,
    reason = function(_, world) return ('danger %.2f, %d hostiles'):format(danger(world), math.floor(enemies(world))) end,
  },
  {
    id = 'fight', categories = { 'combat' }, riskWeight = 1.0,
    need = function(_, world, cfg)
      if enemies(world) == 0 then return 0 end
      if danger(world) <= cfg.thresholds.dangerEngage then return 1.0 end
      return 0.25
    end,
    opportunity = function(_, world) return util.clamp(enemies(world) / 3, 0, 1) end,
    risk = function(_, world) return danger(world) end,
    reason = function(_, world) return ('%d hostiles, danger %.2f'):format(math.floor(enemies(world)), danger(world)) end,
  },
  {
    id = 'rest', categories = { 'combat', 'magic' }, riskWeight = 0.6,
    need = function(s, _, cfg)
      if s.fatigueFraction <= cfg.thresholds.lowFatigue then return 0.9 end
      return (1 - s.fatigueFraction) * 0.5
    end,
    opportunity = function(_, world) return math.max(opp(world, 'rest'), 0.3) end,
    risk = function(_, world) return danger(world) end,
    reason = function(s) return ('fatigue %d%%'):format(math.floor(s.fatigueFraction * 100)) end,
  },
  {
    id = 'train', categories = { 'train' },
    need = function(s, _, cfg)
      if s.gold < cfg.thresholds.trainMinGold then return 0 end
      return s.readyToLevel and 1.0 or 0.7
    end,
    opportunity = function(_, world) return opp(world, 'trainer') end,
    reason = function(s) return ('gold %d, level %d'):format(math.floor(s.gold), math.floor(s.level)) end,
  },
  {
    id = 'shop', categories = { 'economy' },
    need = function(s, _, cfg)
      if s.encumbranceFraction >= cfg.thresholds.encumbranceHigh then return 1.0 end
      if s.healthFraction <= cfg.thresholds.lowHealth then return 0.6 end
      if s.magickaFraction <= cfg.thresholds.lowMagicka then return 0.6 end
      return 0.25
    end,
    opportunity = function(_, world) return opp(world, 'shop') end,
    reason = function(s) return ('encumbrance %d%%'):format(math.floor(s.encumbranceFraction * 100)) end,
  },
  {
    id = 'sell_junk', categories = { 'economy' },
    need = function(s, world, cfg)
      local value = (world and world.junkValue) or 0
      if value <= 0 then return 0 end
      local base = util.clamp(value / (cfg.thresholds.junkValuePerWeight * 10), 0, 1)
      if s.encumbranceFraction >= cfg.thresholds.encumbranceHigh then base = math.max(base, 0.8) end
      return base
    end,
    opportunity = function(_, world) return opp(world, 'shop') end,
    reason = function(_, world) return ('junk worth %d gold'):format(math.floor((world and world.junkValue) or 0)) end,
  },
  {
    id = 'talk', categories = { 'social' },
    need = function() return 0.5 end,
    opportunity = function(_, world) return opp(world, 'talk') end,
    reason = function() return 'someone to talk to' end,
  },
  {
    id = 'quest', categories = { 'social', 'combat' }, riskWeight = 0.5,
    need = function(_, world) return opp(world, 'quest') > 0 and 0.8 or 0 end,
    opportunity = function(_, world) return opp(world, 'quest') end,
    risk = function(_, world) return danger(world) end,
    reason = function() return 'quest objective nearby' end,
  },
  {
    id = 'travel', categories = {}, riskWeight = 0.5,
    -- OFF by default (behaviour.autoTravel). Travelling autonomously moves the
    -- player somewhere they did not ask to go, and the 1000-hour simulation
    -- showed that an unbounded travel goal loops degenerate: it outranks real
    -- work (training, trading) and starves it. The console surfaces travel
    -- destinations so the player can order a journey deliberately instead.
    need = function(_, _, cfg)
      if not (cfg and cfg.behaviour and cfg.behaviour.autoTravel) then return 0 end
      return 0.2
    end,
    opportunity = function(_, world) return opp(world, 'travel') end,
    risk = function(_, world) return danger(world) end,
    reason = function() return 'travel service available' end,
  },
  {
    id = 'explore', categories = { 'stealth' }, riskWeight = 0.4,
    need = function() return 0.4 end,
    opportunity = function(_, world) return opp(world, 'unexplored') end,
    risk = function(_, world) return danger(world) end,
    reason = function() return 'unexplored ground' end,
  },
  {
    id = 'idle', categories = {}, need = function() return 0.05 end,
    opportunity = function() return 1.0 end,
    reason = function() return 'nothing better to do' end,
  },
}

--- Register (or replace) a goal. Useful for mods and for tests.
function M.register(goal)
  assert.is_table(goal)
  for i, existing in ipairs(M.GOALS) do
    if existing.id == goal.id then M.GOALS[i] = goal return goal end
  end
  M.GOALS[#M.GOALS + 1] = goal
  return goal
end

function M.get(id)
  for _, goal in ipairs(M.GOALS) do
    if goal.id == id then return goal end
  end
  return nil
end

function M.ids()
  return util.map(M.GOALS, function(goal) return goal.id end)
end

-- ---------------------------------------------------------------------------
-- scoring
-- ---------------------------------------------------------------------------

--- Mean of weight[c] * capability[c] over a goal's categories.
--- A goal with no categories is neutral (aptitude 1.0).
function M.aptitude(goal, weights, capability)
  local categories = goal.categories or {}
  if #categories == 0 then return 1.0 end
  local total = 0
  for _, cat in ipairs(categories) do
    local w = (weights and weights[cat]) or 1.0
    local c = (capability and capability[cat]) or 1.0
    total = total + w * c
  end
  return total / #categories
end

--- Rank every goal for this tick. Returns a descending list of score rows.
function M.rank(statView, weights, world, cfg)
  statView = statView or {}
  world = world or {}
  local rows = {}
  local level = statView.level or 1

  for index, goal in ipairs(M.GOALS) do
    local need = util.clamp(goal.need(statView, world, cfg) or 0, 0, 1)
    local opportunity = util.clamp(goal.opportunity(statView, world, cfg) or 0, 0, 1)
    local risk = util.clamp((goal.risk and goal.risk(statView, world, cfg)) or 0, 0, 1)
    local aptitude = M.aptitude(goal, weights, statView.capability)
    local bias = (cfg.goalBias and cfg.goalBias[goal.id]) or 1.0
    local riskWeight = goal.riskWeight or 1.0

    -- Autonomous roaming (behaviour.roam): when nothing more pressing needs
    -- doing, prefer to *wander* over standing still. `explore` normally scores
    -- zero once the ground is known (its opportunity comes from "unexplored"),
    -- so roaming floors both its bias and its opportunity -- enough to beat
    -- `idle` (need 0.05) in a quiet moment, never enough to override survive /
    -- heal / fight, which carry far larger need * bias.
    if goal.id == 'explore' and cfg.behaviour and cfg.behaviour.roam then
      bias = math.max(bias, M.ROAM.bias)
      opportunity = math.max(opportunity, M.ROAM.opportunityFloor)
    end

    local raw = bias * aptitude * need * opportunity * (1 + (cfg.levelScaling or 0) * level)
    local score = raw - riskWeight * risk * M.RISK_SCALE

    rows[#rows + 1] = {
      id = goal.id,
      index = index,
      score = score,
      raw = raw,
      need = need,
      opportunity = opportunity,
      risk = risk,
      aptitude = aptitude,
      bias = bias,
      reason = goal.reason and goal.reason(statView, world, cfg) or nil,
    }
  end

  table.sort(rows, function(a, b)
    if math.abs(a.score - b.score) > 1e-12 then return a.score > b.score end
    return a.index < b.index -- stable, declaration-order tie-break
  end)

  return rows
end

--- Pick the single best goal. Returns `id, ranked, chosenRow`.
---
--- `idle` is a true FALLBACK, not a normal competitor: it is only chosen when no
--- other goal has both a positive need and a positive score. That keeps the
--- "do nothing" option from ever masquerading as a real decision.
function M.select(statView, weights, world, cfg)
  local ranked = M.rank(statView, weights, world, cfg)
  for _, row in ipairs(ranked) do
    if row.id ~= 'idle' and row.need > 0 and row.score > 0 then
      return row.id, ranked, row
    end
  end
  local idleRow = util.firstWhere(ranked, function(r) return r.id == 'idle' end)
  return 'idle', ranked, idleRow
end

--- Convenience: the ranked list stripped to { id = score } for logging.
function M.scoreMap(ranked)
  local out = {}
  for _, row in ipairs(ranked) do out[row.id] = util.round(row.score, 4) end
  return out
end

return M
