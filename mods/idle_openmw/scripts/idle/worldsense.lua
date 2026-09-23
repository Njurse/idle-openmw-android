-- scripts/idle/worldsense.lua
-- "What is that actor?" -- and how far away is it.
--
-- This is the module that makes the director's decisions grounded in the actual
-- world instead of placeholder hooks. It is PURE: the runtime feeds it plain
-- descriptors, so every rule here is unit-testable without the engine.
--
-- Verified sources (docs/openmw-lua-api.md §9):
--   NpcRecord/CreatureRecord.servicesOffered  files/lua_api/openmw/types.lua:964,1266
--     keys are bound by MWLua::ServiceNames, apps/openmw/mwlua/types/servicesoffered.hpp:11
--   NpcRecord.travelDestinations              types.lua:1267
--   Actor.stats.ai.fight/alarm/flee           types.lua:538-550
--   Creature vs NPC                           object.type == types.Creature
--
-- NOTE ON HOSTILITY: OpenMW exposes **no** "is at war with the player" flag --
-- grepping the whole Lua API for isInCombat/InCombat returns nothing. Hostility
-- here is therefore an explicit, documented HEURISTIC (see M.hostile), not a
-- claim of certainty.

local util = require('scripts.idle.util')

local M = {}

--- The service keys the engine actually binds (MWLua::ServiceNames, 19 entries).
M.SERVICE_KEYS = {
  'Spells', 'Spellmaking', 'Enchanting', 'Training', 'Repair', 'Barter',
  'Weapon', 'Armor', 'Clothing', 'Books', 'Ingredients', 'Picks', 'Probes',
  'Lights', 'Apparatus', 'RepairItem', 'Misc', 'Potions', 'MagicItems',
}

--- Which services make an actor useful for each idle role.
M.ROLE_SERVICES = {
  shop = { 'Barter' },
  trainer = { 'Training' },
  healer = { 'Spells', 'Potions' },
  repairer = { 'Repair' },
  enchanter = { 'Enchanting', 'Spellmaking' },
}

--- The roles a scan can surface, in the order the console lists them.
M.ROLES = { 'shop', 'trainer', 'healer', 'repairer', 'travel', 'enchanter' }

-- ---------------------------------------------------------------------------
-- classification
-- ---------------------------------------------------------------------------

--- Normalize a `servicesOffered` map into a flag set over M.SERVICE_KEYS.
function M.readServices(record)
  local flags = {}
  local offered = util.isObject(record) and record.servicesOffered or nil
  if type(offered) ~= 'table' then return flags end
  for _, key in ipairs(M.SERVICE_KEYS) do
    flags[key] = offered[key] == true
  end
  return flags
end

function M.offersAnyService(flags)
  for _, key in ipairs(M.SERVICE_KEYS) do
    if flags[key] then return true end
  end
  return false
end

function M.serviceCount(flags)
  local count = 0
  for _, key in ipairs(M.SERVICE_KEYS) do
    if flags[key] then count = count + 1 end
  end
  return count
end

--- Which idle roles an actor fills, from its services and travel destinations.
--- @param flags  result of M.readServices
--- @param record the actor's record (for travelDestinations)
function M.roles(flags, record)
  local roles = { services = M.offersAnyService(flags) }
  -- every role is explicitly boolean: a consumer can tell "not this role" from
  -- "no data", and `pairs()` over the table is meaningful rather than sparse
  for role in pairs(M.ROLE_SERVICES) do
    roles[role] = false
  end
  for role, keys in pairs(M.ROLE_SERVICES) do
    for _, key in ipairs(keys) do
      if flags[key] then roles[role] = true break end
    end
  end

  local destinations = util.isObject(record) and record.travelDestinations or nil
  roles.travel = util.isObject(destinations) and #destinations > 0
  -- An actor that offers nothing and travels nowhere is a "talker": the only
  -- thing left to do with them is start a conversation.
  roles.questing = not roles.services and not roles.travel
  return roles
end

--- Should we treat this actor as an enemy?
---
--- The heuristic, in order:
---   1. essential actors are never enemies (you cannot kill them anyway)
---   2. anyone who offers a service is never an enemy -- a merchant must stay alive
---   3. `sensing.ignoreRecords` is an explicit never-hostile list
---   4. creatures are enemies unless `sensing.creaturesAreHostile` is off
---   5. NPCs are enemies ONLY when `sensing.npcFightHostility` is explicitly
---      enabled, and then only at `sensing.hostileFightThreshold`
---
--- Step 5 is opt-in on purpose. The engine's AI Fight disposition cannot tell a
--- town guard (Fight 100) from a bandit (Fight 95) -- both look identical -- and
--- a mod that attacks a guard is destructive and irreversible in a save file.
--- Creatures, by contrast, are unambiguous.
---
--- @param actor { id?, isCreature?, fight?, isEssential?, offersServices? }
--- @return boolean hostile, string reason
function M.hostile(actor, cfg)
  actor = actor or {}
  local sensing = (cfg and cfg.sensing) or {}

  if actor.isEssential then return false, 'essential — cannot be attacked' end
  if actor.offersServices then return false, 'offers a service' end

  if actor.id and util.isObject(sensing.ignoreRecords) then
    for _, ignored in ipairs(sensing.ignoreRecords) do
      if tostring(ignored) == tostring(actor.id) then return false, 'ignored by config' end
    end
  end

  if actor.isCreature then
    if sensing.creaturesAreHostile == false then return false, 'creatures are not hostile' end
    return true, 'creature'
  end

  if sensing.npcFightHostility ~= true then
    return false, 'NPC hostility is opt-in (sensing.npcFightHostility)'
  end
  local fight = actor.fight
  if type(fight) ~= 'number' then return false, 'no fight disposition available' end
  local threshold = sensing.hostileFightThreshold or 80
  if fight >= threshold then
    return true, ('fight disposition %d >= %d'):format(fight, threshold)
  end
  return false, ('fight disposition %d'):format(fight)
end

--- Everything worth knowing about one actor, from a plain descriptor.
--- @param spec { record?, isCreature?, isEssential?, fight?, name?, position?, object?, level? }
function M.describe(spec, cfg)
  spec = spec or {}
  local record = spec.record or {}
  local flags = M.readServices(record)
  local roles = M.roles(flags, record)

  -- a merchant is not your enemy, so services suppress hostility first
  local offers = roles.services or roles.travel
  local hostile, reason = M.hostile({
    id = spec.id or record.id,
    isCreature = spec.isCreature,
    fight = spec.fight,
    isEssential = spec.isEssential or record.isEssential,
    offersServices = offers,
  }, cfg)

  return {
    id = spec.id or record.id,
    name = spec.name or record.id or spec.id,
    position = spec.position,
    object = spec.object,
    level = spec.level,
    services = flags,
    serviceCount = M.serviceCount(flags),
    roles = roles,
    offersServices = offers,
    travelDestinations = util.isObject(record.travelDestinations) and record.travelDestinations or nil,
    hostile = hostile,
    hostileReason = reason,
    isCreature = spec.isCreature and true or false,
    isEssential = (spec.isEssential or record.isEssential) and true or false,
    fight = spec.fight,
  }
end

-- ---------------------------------------------------------------------------
-- scanning
-- ---------------------------------------------------------------------------

local function proximityTo(origin, at, radius)
  if not origin or not at then return 0.5 end
  local distance = util.distance(origin, at)
  if not distance then return 0.5 end
  return util.clamp(1 - distance / radius, 0, 1)
end

--- Aggregate descriptors into opportunities + nearest targets.
--- @param descriptors list of M.describe results
--- @param opts { position, scanRadius?, questingWeight? }
function M.scan(descriptors, opts)
  opts = opts or {}
  local origin = opts.position
  local radius = opts.scanRadius or 4096
  local questingWeight = opts.questingWeight or 0.6

  local opportunities = {
    shop = 0, trainer = 0, healing = 0, repair = 0, travel = 0,
    enchant = 0, talk = 0, quest = 0, loot = 0, rest = 0, unexplored = 0,
  }
  local nearest = {}
  local enemies = {}

  local function consider(key, descriptor, weight)
    local closeness = proximityTo(origin, descriptor.position, radius) * (weight or 1)
    if closeness > (opportunities[key] or 0) then opportunities[key] = closeness end
    local distance = (origin and descriptor.position)
      and util.distance(origin, descriptor.position) or nil
    local current = nearest[key]
    if not current or (distance and distance < (current.distance or math.huge)) then
      nearest[key] = {
        name = descriptor.name,
        position = descriptor.position,
        distance = distance,
        object = descriptor.object,
        roles = descriptor.roles,
        travelDestinations = descriptor.travelDestinations,
      }
    end
  end

  for _, descriptor in ipairs(descriptors or {}) do
    if descriptor.hostile then
      enemies[#enemies + 1] = {
        id = descriptor.id,
        name = descriptor.name,
        position = descriptor.position,
        object = descriptor.object,
        level = descriptor.level or 1,
        reason = descriptor.hostileReason,
      }
      consider('enemy', descriptor)
    else
      consider('talk', descriptor)
      local roles = descriptor.roles or {}
      if roles.shop then consider('shop', descriptor) end
      if roles.trainer then consider('trainer', descriptor) end
      if roles.healer then consider('healing', descriptor) end
      if roles.repairer then consider('repair', descriptor) end
      if roles.enchanter then consider('enchant', descriptor) end
      if roles.travel then consider('travel', descriptor) end
      -- a talker with nothing to sell might have something to say
      if roles.questing then consider('quest', descriptor, questingWeight) end
    end
  end

  return {
    opportunities = opportunities,
    nearest = nearest,
    enemies = enemies,
    descriptors = descriptors,
  }
end

--- The travel destinations offered by a nearest-travel entry, as display rows.
function M.destinationsOf(entry)
  local out = {}
  if type(entry) ~= 'table' then return out end
  for i, destination in ipairs(entry.travelDestinations or {}) do
    if util.isObject(destination) then
      out[#out + 1] = {
        index = i,
        cell = destination.cell or destination.name,
        price = destination.price,
      }
    end
  end
  return out
end

return M
