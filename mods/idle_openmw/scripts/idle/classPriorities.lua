-- scripts/idle/classPriorities.lua
-- Turns a Morrowind class definition into a *preference* weight vector over the
-- six behaviour categories. This is "what the character wants to do".
--
-- The weights are derived from the class's real skill makeup (specialization +
-- major/minor skills) rather than a hand-written table, so any modded class --
-- not just the four archetypes -- gets sensible behaviour. The four archetypes
-- are provided as presets.
--
-- Pure: no engine, no I/O.

local util = require('scripts.idle.util')

local M = {}

M.CATEGORIES = { 'combat', 'magic', 'stealth', 'social', 'economy', 'train' }

-- Morrowind's 27 skills, grouped by the specialization they belong to.
local COMBAT_SKILLS = {
  'block', 'armorer', 'mediumarmor', 'heavyarmor', 'bluntweapon', 'longblade',
  'axe', 'spear', 'athletics', 'marksman',
}
local MAGIC_SKILLS = {
  'enchant', 'destruction', 'alteration', 'illusion', 'conjuration',
  'mysticism', 'restoration', 'alchemy',
}
local STEALTH_SKILLS = {
  'sneak', 'lightarmor', 'security', 'shortblade', 'acrobatics',
  'mercantile', 'speechcraft', 'handtohand', 'unarmored',
}

--- skill id -> its specialization category
local SKILL_CATEGORY = {}
local function register(category, skills)
  for _, s in ipairs(skills) do SKILL_CATEGORY[s] = category end
end
register('combat', COMBAT_SKILLS)
register('magic', MAGIC_SKILLS)
register('stealth', STEALTH_SKILLS)

--- Skills that *additionally* feed the social / economy categories, on top of
--- their specialization. Values are final weights (1.0 == as important as a
--- skill's primary category).
local SKILL_AFFINITY = {
  speechcraft = { social = 0.5 },
  mercantile  = { social = 0.25, economy = 0.5 },
  illusion    = { social = 0.2 },
  security    = { economy = 0.25 },
  alchemy     = { economy = 0.25 },
  handtohand  = { social = 0.05 },
}

M.MAJOR_WEIGHT = 2.0
M.MINOR_WEIGHT = 1.0
M.SPECIALIZATION_BONUS = 0.6
M.BASE = 0.55
M.TARGET_MEAN = 1.0
M.MIN_WEIGHT = 0.05
M.MAX_WEIGHT = 6.0

--- Normalize a skill id: "Long Blade" / "long-blade" / "LONG_BLADE" -> "longblade".
function M.normalizeSkillId(id)
  if type(id) ~= 'string' then return nil end
  return (id:lower():gsub('[^%a%d]', ''))
end

--- The specialization category a skill belongs to, or nil.
function M.categoryOf(skillId)
  return SKILL_CATEGORY[M.normalizeSkillId(skillId)]
end

function M.skillsInCategory(category)
  local out = {}
  for skill, cat in pairs(SKILL_CATEGORY) do
    if cat == category then out[#out + 1] = skill end
  end
  table.sort(out)
  return out
end

--- How much a skill feeds each category: its specialization at weight 1.0 plus
--- any affinity extras. This is the single source of truth shared by
--- classPriorities (weights) and statCrunch (capability).
function M.contributions(skillId)
  local skill = M.normalizeSkillId(skillId)
  local out = {}
  local primary = SKILL_CATEGORY[skill]
  if primary then out[primary] = 1.0 end
  for cat, amount in pairs(SKILL_AFFINITY[skill] or {}) do
    out[cat] = (out[cat] or 0) + amount
  end
  return out
end

--- Every skill that feeds `category`, with its weight: { { id, weight }, ... }.
--- The `train` category is intentionally backed by no skill.
function M.skillsForCategory(category)
  local out = {}
  for skill in pairs(SKILL_CATEGORY) do
    local weight = M.contributions(skill)[category]
    if weight and weight > 0 then out[#out + 1] = { id = skill, weight = weight } end
  end
  for skill in pairs(SKILL_AFFINITY) do
    if not SKILL_CATEGORY[skill] then
      local weight = M.contributions(skill)[category]
      if weight and weight > 0 then out[#out + 1] = { id = skill, weight = weight } end
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

--- Build the raw (pre-normalization) category scores for a class definition.
local function rawWeights(classDef)
  local raw = {}
  for _, cat in ipairs(M.CATEGORIES) do raw[cat] = M.BASE end
  -- social/economy start a little lower: they are the "derived" categories
  raw.social = M.BASE * 0.8
  raw.economy = M.BASE * 0.8

  local function add(list, weight)
    for _, rawId in ipairs(list or {}) do
      for cat, amount in pairs(M.contributions(rawId)) do
        raw[cat] = raw[cat] + amount * weight
      end
    end
  end

  add(classDef.majorSkills, M.MAJOR_WEIGHT)
  add(classDef.minorSkills, M.MINOR_WEIGHT)

  local spec = classDef.specialization
  if type(spec) == 'string' then
    spec = spec:lower()
    if raw[spec] then raw[spec] = raw[spec] + M.SPECIALIZATION_BONUS end
  end

  -- training appetite grows a little with how many skills the class majors in
  raw.train = raw.train + #(classDef.majorSkills or {}) * 0.05
  return raw
end

--- Scale raw scores so their mean equals TARGET_MEAN, then clamp.
local function normalize(raw)
  local total = 0
  for _, cat in ipairs(M.CATEGORIES) do total = total + raw[cat] end
  local scale = (M.TARGET_MEAN * #M.CATEGORIES) / (total > 0 and total or 1)
  local out = {}
  for _, cat in ipairs(M.CATEGORIES) do
    out[cat] = util.clamp(raw[cat] * scale, M.MIN_WEIGHT, M.MAX_WEIGHT)
  end
  return out
end

--- Build the preference weight vector for a class definition.
--- @param classDef table { specialization, majorSkills, minorSkills, ... }
--- @param overrides table|nil { combat=1.2, economy=0.8, ... } multipliers
--- @return table weights { combat, magic, stealth, social, economy, train }
function M.buildWeights(classDef, overrides)
  classDef = classDef or {}
  local weights = normalize(rawWeights(classDef))
  return M.applyOverrides(weights, overrides)
end

--- Multiply selected categories by the given factors (missing factor == 1.0).
function M.applyOverrides(weights, overrides)
  if type(overrides) ~= 'table' then return weights end
  local out = util.copy(weights)
  for _, cat in ipairs(M.CATEGORIES) do
    local factor = overrides[cat]
    if type(factor) == 'number' and factor >= 0 then
      out[cat] = util.clamp(out[cat] * factor, M.MIN_WEIGHT, M.MAX_WEIGHT)
    end
  end
  return out
end

--- The category with the highest weight (deterministic alphabetical tie-break).
function M.dominantCategory(weights)
  local best, bestValue = nil, -math.huge
  for _, cat in ipairs(M.CATEGORIES) do
    local v = weights[cat] or 0
    if v > bestValue + 1e-12 or (math.abs(v - bestValue) <= 1e-12 and best and cat < best) then
      best, bestValue = cat, v
    end
  end
  return best, bestValue
end

-- ---------------------------------------------------------------------------
-- Archetype presets (used by fixtures, the UI, and the "quick start" picker).
-- ---------------------------------------------------------------------------

M.presets = {
  warrior = {
    id = 'warrior', name = 'Warrior', specialization = 'combat',
    favoredAttributes = { 'strength', 'endurance' },
    majorSkills = { 'longblade', 'heavyarmor', 'block', 'armorer', 'athletics' },
    minorSkills = { 'marksman', 'bluntweapon', 'mediumarmor', 'restoration', 'acrobatics' },
  },
  mage = {
    id = 'mage', name = 'Mage', specialization = 'magic',
    favoredAttributes = { 'intelligence', 'willpower' },
    majorSkills = { 'destruction', 'alteration', 'mysticism', 'illusion', 'conjuration' },
    minorSkills = { 'restoration', 'alchemy', 'enchant', 'unarmored', 'shortblade' },
  },
  thief = {
    id = 'thief', name = 'Thief', specialization = 'stealth',
    favoredAttributes = { 'speed', 'agility' },
    majorSkills = { 'sneak', 'security', 'lightarmor', 'shortblade', 'acrobatics' },
    minorSkills = { 'marksman', 'mercantile', 'speechcraft', 'handtohand', 'athletics' },
  },
  healer = {
    id = 'healer', name = 'Healer', specialization = 'magic',
    favoredAttributes = { 'personality', 'willpower' },
    majorSkills = { 'restoration', 'alchemy', 'speechcraft', 'mysticism', 'alteration' },
    minorSkills = { 'illusion', 'conjuration', 'mercantile', 'unarmored', 'shortblade' },
  },
}

return M
