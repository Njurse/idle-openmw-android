-- scripts/idle/config.lua
-- All tunables in one place, with validation. Pure (no engine, no I/O) so the
-- whole config surface is unit-tested. The OpenMW layer reads user overrides
-- from `storage.playerSection('IdleOpenMW')` and merges them here.

local util = require('scripts.idle.util')

local M = {}

M.SECTION_NAME = 'IdleOpenMW'

M.defaults = {
  -- version of the config schema; bump when a migration is needed
  version = 1,

  tick = {
    interval = 2.0,   -- simulation seconds between director decisions
    minInterval = 0.5,
    maxInterval = 10.0,
    logLimit = 200,   -- activity-log ring-buffer size
  },

  -- Multipliers applied on top of the class-derived weight vector.
  -- 1.0 = "as the class naturally is".
  weightOverrides = {
    combat = 1.0,
    magic = 1.0,
    stealth = 1.0,
    social = 1.0,
    economy = 1.0,
    train = 1.0,
  },

  thresholds = {
    criticalHealth = 0.25,   -- health fraction below which SURVIVE dominates
    lowHealth = 0.50,
    lowMagicka = 0.20,
    lowFatigue = 0.15,
    encumbranceHigh = 0.85,  -- encumbrance fraction that forces a sell trip
    junkValuePerWeight = 20, -- items below this gold/weight ratio are junk
    keepItemCount = 1,       -- keep at least this many of a valuable item
    minGoldReserve = 100,    -- never spend below this
    restHours = 8,           -- hours per rest action
    trainMinGold = 50,       -- minimum gold to consider training
    fleeHealthFraction = 0.20,
    dangerFlee = 0.70,       -- danger level at which fleeing is preferred
    dangerEngage = 0.35,     -- danger level below which fighting is fine
  },

  -- Relative desirability of each goal, on top of category weights.
  goalBias = {
    survive = 2.0,
    flee = 1.5,
    heal = 1.3,
    rest = 1.0,
    train = 1.0,
    fight = 1.0,
    shop = 1.0,
    sell_junk = 1.1,
    talk = 0.9,
    quest = 1.2,
    explore = 0.6,
    idle = 0.05,
  },

  -- Level scaling: score *= 1 + levelScaling * level. Rewards growth a little.
  levelScaling = 0.02,

  offline = {
    enabled = true,
    maxRealHours = 8,          -- cap catch-up to avoid exploitation
    gameHoursPerRealMinute = 1, -- project plan: 1 real minute == 1 game hour
    goldPerGameHour = 10,
    skillProgressPerGameHour = 2,
    itemsPerGameHour = 0.5,
    riskOccupancy = 0.85,      -- fraction of the window assumed productive
  },

  behaviour = {
    arriveTolerance = 96,      -- engine units; close enough to "arrived"
    repathDistance = 256,      -- re-path when the target drifts this far
    pathCacheTtl = 30,         -- simulation seconds before a cached path expires
    maxPathWaypoints = 64,
    stuckTimeout = 45,         -- sim seconds without progress -> give up on a move
    restWhenFatigued = true,

    -- OpenMW's Lua API exposes no way to drive the barter/rest/training UI
    -- (see docs/openmw-lua-api.md §4). When true, the runtime performs those
    -- actions directly instead -- moving items/gold between inventories with
    -- world.createObject + GameObject:remove, and restoring pools with
    -- types.Actor.stats -- so the idle loop is actually functional.
    -- Set to false to make the mod purely advisory (it will only navigate and
    -- open the relevant UI) if you prefer no "simulated" actions.
    simulateActions = true,
    barterRatio = 0.8,         -- merchant pays this fraction of book value
    trainGoldPerLevel = 20,    -- simulated training cost, per character level

    -- How long a user directive ("go shop", "rest") stays in force, in
    -- simulation seconds, before the director resumes choosing for itself.
    directiveTtl = 120,
  },

  debug = {
    verbose = false,
    seed = 1337,
  },

  ui = {
    enabled = true,
    refresh = 0.5,      -- seconds between HUD text refreshes
    -- Safe-area insets in UI units, for the notch / gesture bar in portrait.
    topInset = 24,
    bottomInset = 24,
    textScale = 1.0,
    -- 'manual'  -- you drive; the game's own touch controls are active
    -- 'directive' -- auto-play, but your orders take precedence
    -- 'auto'    -- fully self-playing (default)
    startMode = 'auto',
  },
}

--- Deep-merge user overrides over the defaults.
function M.new(overrides)
  local cfg = util.merge(M.defaults, overrides)
  return cfg
end

local function clampProblem(problems, path, value, lo, hi)
  if type(value) ~= 'number' then
    problems[#problems + 1] = path .. ' must be a number'
  elseif value < lo or value > hi then
    problems[#problems + 1] = ('%s (%s) out of range [%s, %s]'):format(path, tostring(value), tostring(lo), tostring(hi))
  end
end

--- Validate a config in place, clamping where sensible.
--- Returns the config and a list of human-readable problems (empty == clean).
function M.validate(cfg)
  local problems = {}
  if type(cfg) ~= 'table' then
    return M.new(), { 'config must be a table' }
  end

  cfg.tick = cfg.tick or util.deepCopy(M.defaults.tick)
  clampProblem(problems, 'tick.interval', cfg.tick.interval, 0.05, 60)
  cfg.tick.interval = util.clamp(cfg.tick.interval, 0.05, 60)

  cfg.thresholds = cfg.thresholds or util.deepCopy(M.defaults.thresholds)
  for _, key in ipairs({ 'criticalHealth', 'lowHealth', 'lowMagicka', 'lowFatigue',
                         'encumbranceHigh', 'dangerFlee', 'dangerEngage', 'fleeHealthFraction' }) do
    if cfg.thresholds[key] ~= nil then
      clampProblem(problems, 'thresholds.' .. key, cfg.thresholds[key], 0, 1)
      cfg.thresholds[key] = util.clamp(cfg.thresholds[key], 0, 1)
    end
  end

  cfg.offline = cfg.offline or util.deepCopy(M.defaults.offline)
  if cfg.offline.maxRealHours ~= nil then
    clampProblem(problems, 'offline.maxRealHours', cfg.offline.maxRealHours, 0, 24 * 7)
    cfg.offline.maxRealHours = util.clamp(cfg.offline.maxRealHours, 0, 24 * 7)
  end

  cfg.behaviour = cfg.behaviour or util.deepCopy(M.defaults.behaviour)
  if cfg.behaviour.arriveTolerance ~= nil then
    clampProblem(problems, 'behaviour.arriveTolerance', cfg.behaviour.arriveTolerance, 1, 4096)
    cfg.behaviour.arriveTolerance = util.clamp(cfg.behaviour.arriveTolerance, 1, 4096)
  end

  cfg.weightOverrides = cfg.weightOverrides or util.deepCopy(M.defaults.weightOverrides)
  for key, value in pairs(cfg.weightOverrides) do
    if type(value) ~= 'number' or value < 0 then
      problems[#problems + 1] = 'weightOverrides.' .. tostring(key) .. ' must be a non-negative number'
      cfg.weightOverrides[key] = 1.0
    end
  end

  return cfg, problems
end

return M
