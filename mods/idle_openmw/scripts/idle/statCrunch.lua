-- scripts/idle/statCrunch.lua
-- Turns a raw stat snapshot into *capability* scores: "what the character can
-- actually do right now". The companion of classPriorities ("what it wants").
--
-- capability[category] in [0,1] = a blend of the class-relevant skills and the
-- attributes that back them, normalized against a reference maximum.
--
-- Pure: no engine, no I/O. Input is a plain snapshot table (see director.lua for
-- the full snapshot contract).

local util = require('scripts.idle.util')
local classPriorities = require('scripts.idle.classPriorities')

local M = {}

M.REFERENCE_MAX = 100   -- a skill/attribute value that counts as "fully capable"
M.MISSING_SKILL = 5     -- value assumed for a skill the snapshot does not mention
M.SKILL_WEIGHT = 0.75
M.ATTRIBUTE_WEIGHT = 0.25

--- Attributes that back each behaviour category.
M.CATEGORY_ATTRIBUTES = {
  combat  = { 'strength', 'endurance', 'agility' },
  magic   = { 'intelligence', 'willpower' },
  stealth = { 'speed', 'agility' },
  social  = { 'personality' },
  economy = { 'personality', 'luck' },
  train   = {},
}

local function normalizeId(id)
  if type(id) ~= 'string' then return nil end
  return (id:lower():gsub('[^%a%d]', ''))
end

--- Read a stat entry, accepting either a number or a {base=, modified=, current=} table.
local function readStat(entry, fallback)
  if type(entry) == 'number' then return entry end
  if type(entry) == 'table' then
    if entry.modified ~= nil then return entry.modified end
    if entry.current ~= nil then return entry.current end
    if entry.base ~= nil then return entry.base end
  end
  return fallback
end
M.readStat = readStat

local function mean(list)
  if #list == 0 then return 0 end
  return util.sum(list) / #list
end

--- Weighted-average skill value (as a fraction of REFERENCE_MAX) for one
--- category. A skill's weight comes from classPriorities.contributions, so
--- skills with affinity (e.g. mercantile -> economy) are counted too.
function M.categorySkillScore(state, category)
  local skills = state.skills or {}
  local totalWeight, acc = 0, 0
  for _, entry in ipairs(classPriorities.skillsForCategory(category)) do
    local raw = readStat(skills[entry.id], M.MISSING_SKILL)
    acc = acc + entry.weight * util.clamp(raw / M.REFERENCE_MAX, 0, 1)
    totalWeight = totalWeight + entry.weight
  end
  if totalWeight == 0 then return 0 end
  return util.clamp(acc / totalWeight, 0, 1)
end

--- Average backing-attribute value (as a fraction of REFERENCE_MAX) for one category.
function M.categoryAttributeScore(state, category)
  local attrs = M.CATEGORY_ATTRIBUTES[category] or {}
  local attributes = state.attributes or {}
  local values = {}
  for _, attrId in ipairs(attrs) do
    local raw = readStat(attributes[attrId], M.MISSING_SKILL)
    values[#values + 1] = util.clamp(raw / M.REFERENCE_MAX, 0, 1)
  end
  if #values == 0 then return 0 end
  return util.clamp(mean(values), 0, 1)
end

--- Fraction (0..1) of a dynamic stat pool. Unknown pool => 1 (assumed healthy).
function M.fraction(dyn)
  if type(dyn) ~= 'table' then return 1 end
  local current = readStat({ current = dyn.current, base = dyn.current }, 0)
  local max = readStat({ base = dyn.base, modified = dyn.max }, nil)
  if not max or max <= 0 then return 1 end
  return util.clamp(current / max, 0, 1)
end

--- Encumbrance fraction in [0,1] (1 == at or over capacity).
function M.encumbranceFraction(state)
  local enc = state.encumbrance
  if type(enc) ~= 'table' then return 0 end
  local max = readStat({ base = enc.max, current = enc.max }, 0)
  if not max or max <= 0 then return 0 end
  return util.clamp((readStat({ current = enc.current }, 0)) / max, 0, 1)
end

--- Top-N skills by value, descending: { { id = 'longblade', value = 62 }, ... }.
function M.topSkills(state, n)
  local list = {}
  for id, entry in pairs(state.skills or {}) do
    list[#list + 1] = { id = normalizeId(id), value = readStat(entry, 0) }
  end
  table.sort(list, function(a, b)
    if a.value == b.value then return a.id < b.id end
    return a.value > b.value
  end)
  local out = {}
  for i = 1, math.min(n or 5, #list) do out[i] = list[i] end
  return out
end

--- Compute the full derived view for a snapshot + class definition.
--- @return table
function M.compute(state, classDef)
  state = state or {}

  local totalSkill = 0
  local skillCount = 0
  for _, entry in pairs(state.skills or {}) do
    totalSkill = totalSkill + readStat(entry, 0)
    skillCount = skillCount + 1
  end
  local averageSkill = totalSkill / math.max(1, skillCount)
  local averageSkillFraction = util.clamp(averageSkill / M.REFERENCE_MAX, 0, 1)

  local capability = {}
  for _, category in ipairs(classPriorities.CATEGORIES) do
    local skillScore = M.categorySkillScore(state, category)
    local attrScore = M.categoryAttributeScore(state, category)
    capability[category] = util.clamp(
      M.SKILL_WEIGHT * skillScore + M.ATTRIBUTE_WEIGHT * attrScore, 0, 1)
  end
  -- "Train" is not backed by any skill group: anyone can train. Its capability
  -- therefore expresses how much room there is left to grow.
  capability.train = util.clamp(0.4 + 0.6 * (1 - averageSkillFraction), 0, 1)

  local healthFraction = M.fraction(state.health)
  local magickaFraction = M.fraction(state.magicka)
  local fatigueFraction = M.fraction(state.fatigue)

  local level = readStat({ base = state.level, current = state.level, modified = state.level }, 1) or 1

  return {
    classId = classDef and classDef.id or (state.class and state.class.id) or nil,
    level = level,
    capability = capability,
    -- resource fractions
    healthFraction = healthFraction,
    magickaFraction = magickaFraction,
    fatigueFraction = fatigueFraction,
    encumbranceFraction = M.encumbranceFraction(state),
    -- how safe the character currently is (health + magical remedy potential)
    survivability = util.clamp(0.6 * healthFraction + 0.4 * capability.magic, 0, 1),
    -- progress bookkeeping
    gold = state.gold or 0,
    skillTotal = totalSkill,
    averageSkill = util.round(averageSkill, 1),
    levelProgress = util.clamp(readStat({ current = state.levelProgress }, 0), 0, 1),
    readyToLevel = (readStat({ current = state.levelProgress }, 0) or 0) >= 1,
    inCombat = state.inCombat and true or false,
    topSkills = M.topSkills(state, 5),
  }
end

return M
