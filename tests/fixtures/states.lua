-- tests/fixtures/states.lua
-- Snapshot builders. Every builder returns a FRESH deep copy, so specs may
-- mutate their fixtures freely.
local util = require('scripts.idle.util')

local M = {}

local function pool(current, base)
  return { current = current, base = base, max = base }
end

--- Build a skills map from { longblade = 60, ... } -> { longblade = {base,modified,progress} }.
function M.skills(spec)
  local out = {}
  for id, value in pairs(spec or {}) do
    if type(value) == 'table' then out[id] = value
    else out[id] = { base = value, modified = value, progress = 0 } end
  end
  return out
end

--- Build an attributes map the same way.
function M.attributes(spec)
  local out = {}
  for id, value in pairs(spec or {}) do
    if type(value) == 'table' then out[id] = value
    else out[id] = { base = value, modified = value } end
  end
  return out
end

--- Fill a snapshot with sane defaults, then apply `opts` on top.
function M.state(opts)
  local defaults = {
    level = 1,
    levelProgress = 0,
    health = pool(100, 100),
    magicka = pool(50, 50),
    fatigue = pool(100, 100),
    encumbrance = { current = 0, max = 200 },
    gold = 0,
    skills = {},
    attributes = {},
    inCombat = false,
  }
  return util.merge(defaults, opts or {})
end

local WARRIOR = {
  level = 5,
  levelProgress = 0.4,
  health = pool(120, 120),
  magicka = pool(40, 40),
  fatigue = pool(140, 140),
  encumbrance = { current = 80, max = 250 },
  gold = 320,
  attributes = M.attributes({
    strength = 62, endurance = 58, agility = 42, speed = 44,
    personality = 32, luck = 40, intelligence = 34, willpower = 36,
  }),
  skills = M.skills({
    longblade = 64, heavyarmor = 58, block = 52, armorer = 41, athletics = 46,
    marksman = 30, bluntweapon = 26, mediumarmor = 28, restoration = 16, acrobatics = 34,
  }),
}

local MAGE = {
  level = 5,
  health = pool(70, 70),
  magicka = pool(130, 130),
  fatigue = pool(90, 90),
  encumbrance = { current = 30, max = 160 },
  gold = 210,
  attributes = M.attributes({
    intelligence = 66, willpower = 60, strength = 34, endurance = 36,
    agility = 40, speed = 38, personality = 42, luck = 40,
  }),
  skills = M.skills({
    destruction = 62, alteration = 56, mysticism = 50, illusion = 45,
    conjuration = 42, restoration = 40, alchemy = 32, enchant = 24,
    unarmored = 22, shortblade = 18,
  }),
}

--- Fresh warrior snapshot (optionally overridden).
function M.warrior(over) return util.merge(WARRIOR, over or {}) end

--- Fresh mage snapshot (optionally overridden).
function M.mage(over) return util.merge(MAGE, over or {}) end

--- A healthy, unremarkable state.
function M.idle(over)
  return M.state(util.merge({
    level = 3, gold = 500,
    skills = M.skills({ longblade = 30, athletics = 25, mercantile = 20, speechcraft = 20, restoration = 18 }),
    attributes = M.attributes({ strength = 45, endurance = 45, agility = 45, speed = 45,
                                personality = 45, luck = 45, intelligence = 45, willpower = 45 }),
  }, over or {}))
end

return M
