-- scripts/runtime/observer.lua
-- Builds the plain-table snapshot the director consumes, from the engine.
--
-- The engine surface is injected as `env` (see scripts/runtime/engine.lua:env),
-- so this module is exercised headlessly against tests/mocks/openmw.lua. Every
-- engine call is pcall-guarded and defensively defaulted: a mod that throws in
-- the middle of the frame is far worse than one that reports a neutral value.
--
-- Record accessors mirror the verified API (docs/openmw-lua-api.md §5):
--   types.Actor.stats.dynamic.health(actor)   -> { base, current, modifier }
--   types.Actor.stats.level(actor)            -> { current, progress }
--   types.NPC.stats.skills.<id>(actor)        -> { base, modified, progress }
--   types.Actor.inventory(actor):countOf(id) / :getAll()
--   types.NPC.record(actor).class             -> class id
--   types.NPC.classes.record(classId)         -> { specialization, majorSkills, minorSkills, attributes }

local util = require('scripts.idle.util')
local economy = require('scripts.idle.economy')
local combat = require('scripts.idle.combat')

local M = {}

M.DEFAULT_SCAN_RADIUS = 4096

-- Currency is surfaced separately as `player.gold`; keeping it out of the item
-- list stops the sell-junk goal from ever considering it merchandise.
M.CURRENCY = { ['gold_001'] = true }

local function safe(fn, ...)
  if type(fn) ~= 'function' then return nil end
  local ok, a = pcall(fn, ...)
  if ok then return a end
  return nil
end

local function num(value, fallback)
  if type(value) == 'number' then return value end
  return fallback
end

local function point(value)
  if type(value) ~= 'table' then return nil end
  return { x = num(value.x, 0), y = num(value.y, 0), z = num(value.z, 0) }
end
M.point = point

-- ---------------------------------------------------------------------------
-- player
-- ---------------------------------------------------------------------------

local function dynamicStat(env, actor, kind)
  local dynamic = env.types and env.types.Actor and env.types.Actor.stats and env.types.Actor.stats.dynamic
  local stat = safe(dynamic and dynamic[kind], actor)
  if type(stat) ~= 'table' then return { current = 1, base = 1, modifier = 0 } end
  local base = num(stat.base, num(stat.current, 1))
  return { current = num(stat.current, base), base = base, modifier = num(stat.modifier, 0) }
end

local function readStatMap(container)
  local out = {}
  if type(container) ~= 'table' then return out end
  for id, getter in pairs(container) do
    if type(id) == 'string' and type(getter) == 'function' then
      -- getter signature: fn(actor)
      out[id] = getter
    end
  end
  return out
end

local function readSkills(env, actor)
  local out = {}
  local stats = env.types and env.types.NPC and env.types.NPC.stats
  for id, getter in pairs(readStatMap(stats and stats.skills)) do
    local stat = safe(getter, actor)
    if type(stat) == 'table' then
      out[id] = {
        base = num(stat.base, 0),
        modified = num(stat.modified, num(stat.base, 0)),
        progress = num(stat.progress, 0),
      }
    end
  end
  return out
end

local function readAttributes(env, actor)
  local out = {}
  local stats = env.types and env.types.NPC and env.types.NPC.stats
  for id, getter in pairs(readStatMap(stats and stats.attributes)) do
    local stat = safe(getter, actor)
    if type(stat) == 'table' then
      out[id] = {
        base = num(stat.base, 0),
        modified = num(stat.modified, num(stat.base, 0)),
      }
    end
  end
  return out
end

local function readEquipped(env, actor)
  local set = {}
  local equipment = safe(env.types and env.types.Actor and env.types.Actor.getEquipment, actor)
  if type(equipment) ~= 'table' then return set end
  for _, item in pairs(equipment) do
    local id = type(item) == 'table' and (item.recordId or item.id) or nil
    if id then set[id] = true end
  end
  return set
end

--- Read the player's inventory as plain item tables, sorted by id (deterministic).
function M.readInventory(env, actor)
  local out = {}
  local inventory = safe(env.types and env.types.Actor and env.types.Actor.inventory, actor)
  if type(inventory) ~= 'table' then return out end

  local equipped = readEquipped(env, actor)
  local items = safe(function() return inventory.getAll and inventory:getAll() end)
  if type(items) ~= 'table' then return out end

  for _, object in pairs(items) do
    if type(object) == 'table' then
      local id = object.recordId or object.id
      if not M.CURRENCY[id] then
        -- record of the item's own type carries value/weight
        local record = safe(object.type and object.type.record, object)
        out[#out + 1] = {
          id = id,
          count = num(object.count, 1),
          value = num(record and record.value, 0),
          weight = num(record and record.weight, 0),
          equipped = id and equipped[id] or false,
          quest = false,
        }
      end
    end
  end
  table.sort(out, function(a, b)
    local ak, bk = tostring(a.id), tostring(b.id)
    if ak == bk then return (a.count or 0) < (b.count or 0) end
    return ak < bk
  end)
  return out
end

--- Resolve the actor's class into the shape classPriorities expects.
function M.readClass(env, actor)
  local npcRecord = safe(env.types and env.types.NPC and env.types.NPC.record, actor)
  local classId = npcRecord and npcRecord.class
  if not classId then return nil end

  local classes = env.types and env.types.NPC and env.types.NPC.classes
  local record
  if classes and type(classes.record) == 'function' then record = safe(classes.record, classId) end
  if type(record) ~= 'table' then return { id = classId, name = classId } end

  return {
    id = record.id or classId,
    name = record.name or classId,
    specialization = record.specialization,
    majorSkills = record.majorSkills,
    minorSkills = record.minorSkills,
    favoredAttributes = record.attributes,
  }
end

--- A plain snapshot of the player character.
function M.readPlayer(env, opts)
  opts = opts or {}
  local self = env.self or {}
  local actor = self.object or self

  local level = safe(function()
    return env.types.Actor.stats.level(actor)
  end) or {}

  local inventory = M.readInventory(env, actor)
  local gold = num(safe(function()
    return env.types.Actor.inventory(actor):countOf('gold_001')
  end), 0)

  local static = safe(function() return env.types.Actor.record(actor) end) or {}
  local encumbranceMax = num(static.capacity, nil)
  if not encumbranceMax and env.types and env.types.Actor and env.types.Actor.getCapacity then
    encumbranceMax = num(safe(env.types.Actor.getCapacity, actor), nil)
  end

  local carried = 0
  for _, item in ipairs(inventory) do
    carried = carried + (item.weight or 0) * (item.count or 1)
  end

  return {
    level = num(level.current, 1),
    levelProgress = util.clamp(num(level.progress, 0), 0, 1),
    health = dynamicStat(env, actor, 'health'),
    magicka = dynamicStat(env, actor, 'magicka'),
    fatigue = dynamicStat(env, actor, 'fatigue'),
    encumbrance = { current = carried, max = encumbranceMax or (carried + 1) },
    gold = gold,
    skills = readSkills(env, actor),
    attributes = readAttributes(env, actor),
    inventory = inventory,
    position = point(self.position) or { x = 0, y = 0, z = 0 },
    yaw = num(self.rotation, 0),
    cell = self.cell and { name = self.cell.name, isExterior = self.cell.isExterior or false } or nil,
    inCombat = false,
  }
end

-- ---------------------------------------------------------------------------
-- world
-- ---------------------------------------------------------------------------

local function emptyOpportunities()
  return { shop = 0, trainer = 0, healing = 0, rest = 0, talk = 0, quest = 0, loot = 0, unexplored = 0 }
end

--- Scan what is around the player.
---
--- Honest limitation: OpenMW's Lua API does not expose an NPC's service flags, so
--- "who is a merchant/trainer" is resolved through the pluggable `servicesOf`
--- hook (`opts.servicesOf` or `env.servicesOf`). When it is absent, only what we
--- can actually detect is reported: people to talk to, hostiles, containers, and
--- whether the current cell has been visited.
function M.scanWorld(env, opts, player)
  opts = opts or {}
  local cfg = opts.cfg
  local radius = num(opts.scanRadius, M.DEFAULT_SCAN_RADIUS)
  local servicesOf = opts.servicesOf or env.servicesOf
  local isHostile = opts.isHostile or env.isHostile
  local position = player and player.position

  local opportunities = emptyOpportunities()
  local nearest = {}
  local enemies = {}

  local function proximity(at)
    if not position or not at then return 0.5 end
    local d = util.distance(position, at)
    if not d then return 0.5 end
    return util.clamp(1 - d / radius, 0, 1)
  end

  local function consider(key, object, at)
    local closeness = proximity(at)
    if closeness > (opportunities[key] or 0) then opportunities[key] = closeness end
    local distance = (position and at) and util.distance(position, at) or nil
    local current = nearest[key]
    if not current or (distance and distance < (current.distance or math.huge)) then
      nearest[key] = {
        name = type(object) == 'table' and (object.recordId or object.name) or nil,
        position = at,
        distance = distance,
        object = object,
      }
    end
  end

  for _, actor in ipairs((env.nearby and env.nearby.actors) or {}) do
    local at = point(actor.position)
    local hostile = isHostile and safe(isHostile, actor) or false
    if hostile then
      enemies[#enemies + 1] = { level = num(actor.level, 1), position = at, name = actor.recordId, object = actor }
      consider('enemy', actor, at)
    else
      consider('talk', actor, at)
      local services = servicesOf and safe(servicesOf, actor) or nil
      if type(services) == 'table' then
        if services.shop then consider('shop', actor, at) end
        if services.trainer then consider('trainer', actor, at) end
        if services.healer then consider('healing', actor, at) end
        if services.quest then consider('quest', actor, at) end
      end
    end
  end

  for _, container in ipairs((env.nearby and env.nearby.containers) or {}) do
    consider('loot', container, point(container.position))
  end

  local capability = opts.capability or {}
  local assessment = cfg and combat.assess(enemies, capability, cfg)
    or { danger = 0, count = #enemies }

  -- Resting is only sensible indoors and out of combat.
  local interior = player and player.cell and player.cell.isExterior == false
  opportunities.rest = interior and (assessment.danger < 0.3 and 1 or 0.2) or 0.2

  -- "Unexplored" needs a memory of visited cells; the runtime supplies it.
  local cellName = player and player.cell and player.cell.name
  local visited = opts.visitedCells
  if cellName and visited then
    opportunities.unexplored = visited[cellName] and 0.2 or 0.9
  else
    opportunities.unexplored = 0.35
  end

  local junkValue = 0
  if cfg and opts.inventory then junkValue = economy.junkValue(opts.inventory, cfg) end

  return {
    opportunities = opportunities,
    enemies = #enemies,
    danger = assessment.danger,
    threat = assessment,
    junkValue = junkValue,
    nearest = nearest,
    enemies_nearby = enemies,
  }
end

--- Build a complete snapshot.
function M.build(env, opts)
  opts = opts or {}
  local player = M.readPlayer(env, opts)
  local capability = opts.capability or {}
  local world = M.scanWorld(env, opts, player)

  if opts.cfg then
    world.junkValue = economy.junkValue(player.inventory, opts.cfg)
  end
  -- the danger assessment needs the character's own capability
  if opts.cfg and world.threat then
    local rated = combat.assess(world.enemies_nearby or {}, capability, opts.cfg)
    world.danger = rated.danger
    world.verdict = rated.verdict
  end

  local time = {}
  if env.core then
    time.simulation = safe(env.core.getSimulationTime)
    time.game = safe(env.core.getGameTime)
    time.real = safe(env.core.getRealTime)
  end

  return { player = player, world = world, time = time }
end

return M
