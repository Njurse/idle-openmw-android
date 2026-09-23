-- scripts/runtime/entities.lua
-- The one place that reads an engine object into a schema entity.
--
-- WHY
-- ---
-- Entity reading used to be copy-pasted per response: `bridgeSources()` built the player one
-- way, `entities.nearby` another, `ui.target` a third, and each drifted. This module is the
-- single reader, so every method that returns an entity returns the SAME shape, and the pure
-- normaliser (scripts/idle/entity.lua) is the single place the shape is decided.
--
-- RULES, learned the hard way in this codebase:
--   * engine values are USERDATA, not tables, so nothing here tests `type(x) == 'table'` for
--     an engine value (scripts/idle/util.lua:isObject is the test that works);
--   * every engine call is pcall-guarded and a failure reads as nil (unknown), never as a
--     crash and never as a fabricated zero;
--   * assignment/creation is NOT here: object mutation is global-only, so it lives in
--     scripts/runtime/warden.lua and the write layer.

local engine = require('scripts.runtime.engine')
local entity = require('scripts.idle.entity')
local util = require('scripts.idle.util')
local schema = require('scripts.idle.schema')

local M = {}

--- Call `fn(...)` and return its value, or nil plus a reason. Engine calls throw for
--- perfectly ordinary reasons (an object removed between frames, a stats pool that does not
--- exist on that type), so a throw is information, not an emergency.
local function probe(fn, ...)
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil, tostring(value)
end

--- Read a field of an engine object, tolerating userdata.
local function readField(object, name)
  if object == nil then return nil end
  return probe(function() return object[name] end)
end

--- Which engine type is this? Returns a list-name (the same names `nearby` uses) so the
--- precedence in scripts/idle/entity.lua can decide the kind.
function M.classify(object, env)
  env = env or engine.env()
  local engineTypes = env.types
  if not engineTypes or not object then return nil end
  local flags = {}
  local checks = {
    actors = { engineTypes.Player, engineTypes.NPC, engineTypes.Creature },
    doors = { engineTypes.Door },
    containers = { engineTypes.Container },
    activators = { engineTypes.Activator },
    items = { engineTypes.Item },
  }
  for listName, classes in pairs(checks) do
    for _, class in ipairs(classes) do
      if class and type(class.objectIsInstance) == 'function' then
        local yes = probe(class.objectIsInstance, object)
        if yes == true then flags[listName] = true end
      end
    end
  end
  return entity.kindFor(flags), flags
end

--- The kind, refined where the engine can be more specific than the list name.
function M.kindOf(object, env)
  env = env or engine.env()
  local engineTypes = env.types
  if not engineTypes or not object then return nil end
  local isPlayer = engineTypes.Player and probe(engineTypes.Player.objectIsInstance, object)
  if isPlayer == true then return 'player' end
  local listName = M.classify(object, env)
  if listName == 'npc' then
    -- classify returns 'npc' for anything actor-shaped; separate the humanoids
    local isNpc = engineTypes.NPC and probe(engineTypes.NPC.objectIsInstance, object)
    if isNpc == true then return 'npc' end
    local isCreature = engineTypes.Creature and probe(engineTypes.Creature.objectIsInstance, object)
    if isCreature == true then return 'creature' end
    return 'npc'
  end
  return listName
end

--- The shared identity and placement fields.
local function readIdentity(builder, object, env)
  builder:set('id', readField(object, 'id'))
  builder:set('recordId', readField(object, 'recordId'))
  builder:set('contentFile', readField(object, 'contentFile'))
  builder:set('enabled', readField(object, 'enabled'))

  local cell = readField(object, 'cell')
  if cell then
    builder:set('cell', readField(cell, 'name'))
    builder:set('cellId', readField(cell, 'id'))
  end

  local position = readField(object, 'position')
  if position then
    local x = readField(position, 'x')
    if type(x) == 'number' then
      builder:set('position', { x = x, y = readField(position, 'y'), z = readField(position, 'z') })
    end
  end

  local engineTypes = env.types
  if engineTypes and type(engineTypes.getRecordName) == 'function' then
    builder:set('name', probe(engineTypes.getRecordName, object))
  end
  return builder
end

--- formId, if the engine can produce one. `core.getFormId(contentFile, index)` needs the
--- object's index; when that is not exposed we leave formId out rather than guess.
local function readFormId(builder, object, env)
  local core = env.core
  local contentFile, index = readField(object, 'contentFile'), readField(object, 'index')
  if core and type(core.getFormId) == 'function' and contentFile and index then
    builder:set('formId', probe(core.getFormId, contentFile, index))
  end
end

local function readPool(builder, name, object, env)
  local engineTypes = env.types
  local dynamic = engineTypes and engineTypes.Actor and engineTypes.Actor.stats
    and engineTypes.Actor.stats.dynamic
  local pool = dynamic and dynamic[name]
  if type(pool) ~= 'function' then return end
  local stat = probe(pool, object)
  if not stat then return end
  local current, base = readField(stat, 'current'), readField(stat, 'base')
  local modifier = readField(stat, 'modifier')
  if current == nil and base == nil then return end
  builder:set(name, { current = current, base = base, modifier = modifier })
end

--- The engine's equipment slots, in the order the 0.51 docs list them (types.lua:74-91).
--- Needed because Actor.EQUIPMENT_SLOT is a BEAN, not a Lua table: `pairs()` over it yields
--- nothing, so a slot number could only be turned back into a name by asking for each name.
local EQUIPMENT_SLOTS = {
  'Helmet', 'Cuirass', 'Greaves', 'LeftPauldron', 'RightPauldron',
  'LeftGauntlet', 'RightGauntlet', 'Boots', 'Shirt', 'Pants', 'Skirt', 'Robe',
  'LeftRing', 'RightRing', 'Amulet', 'Belt', 'CarriedRight', 'CarriedLeft', 'Ammunition',
}

local STANCES = { 'Nothing', 'Weapon', 'Spell' }

--- Turn an engine enum value back into its NAME.
---
--- `Actor.getStance` returns 0/1/2 and equipment slots come back as numbers, so a client that
--- displays the raw number shows the wrong thing. The enum cannot be iterated (it is a bean),
--- so we ask for each known name in turn and compare.
local function enumName(enumBean, names, value)
  if value == nil then return nil end
  for _, name in ipairs(names) do
    local code = readField(enumBean, name)
    if code ~= nil and code == value then return name end
  end
  return nil
end

--- Which slot is this number? Falls back to the number, which is still meaningfully readable
--- next to the item it holds.
local function slotName(actor, slot)
  return enumName(actor and actor.EQUIPMENT_SLOT, EQUIPMENT_SLOTS, slot) or tostring(slot)
end

--- Which stance is this number?
local function stanceName(actor, stance)
  return enumName(actor and actor.STANCE, STANCES, stance) or (stance ~= nil and tostring(stance))
end

--- Read a stat bean whose fields are {base, damage, modified, modifier} (+ progress).
local function readStatBean(getter, object, extraField)
  local stat = probe(getter, object)
  if not stat then return nil end
  local out = {
    base = readField(stat, 'base'),
    damage = readField(stat, 'damage'),
    modified = readField(stat, 'modified'),
    modifier = readField(stat, 'modifier'),
  }
  if extraField then out[extraField] = readField(stat, extraField) end
  if out.base == nil and out.modified == nil then return nil end
  return out
end

--- The character sheet: attributes, skills, level progress, reputation, spells, movement.
---
--- The player's stats ARE NpcStats (types.lua:760-763), so this is the same reader for the
--- player and for NPCs -- which matters, because an idle RPG wants both sides of a fight.
local function readSheet(builder, object, env)
  local engineTypes = env.types
  local actor = engineTypes and engineTypes.Actor
  if not actor then return end

  -- SKILLS live on NpcStats, not on the base ActorStats: `types.NPC.stats` is the extended
  -- bean (types.lua:909) and the player is an NPC type instance, so this is the same call for
  -- the character we care about and for every humanoid we might fight. Reading only
  -- `Actor.stats` is why skills came back empty the first time on a real engine.
  local stats = (engineTypes.NPC and engineTypes.NPC.stats) or actor.stats
  if not stats then return end

  -- attributes: eight named getters (types.lua AttributeStats)
  if stats.attributes then
    local attributes = {}
    for _, name in ipairs(schema.ATTRIBUTES) do
      local getter = stats.attributes[name]
      if type(getter) == 'function' then
        local read = readStatBean(getter, object)
        if read then attributes[name] = read end
      end
    end
    if next(attributes) then builder:set('attributes', attributes) end
  end

  -- skills: twenty-seven named getters, each with progress towards the next point
  if stats.skills then
    local skills = {}
    for _, name in ipairs(schema.SKILLS) do
      local getter = stats.skills[name]
      if type(getter) == 'function' then
        local read = readStatBean(getter, object, 'progress')
        if read then skills[name] = read end
      end
    end
    if next(skills) then builder:set('skills', skills) end
  end

  -- level and progress towards the next one
  if type(stats.level) == 'function' then
    local level = probe(stats.level, object)
    if level then
      local current = readField(level, 'current')
      if type(current) == 'number' then builder:set('level', math.floor(current)) end
      builder:set('levelProgress', readField(level, 'progress'))
    end
  end

  -- reputation (NpcStats only)
  local reputation = stats.reputation and probe(stats.reputation, object)
  if reputation then builder:set('reputation', readField(reputation, 'current')) end

  -- spells, powers and abilities; and what is currently affecting the actor
  if type(actor.spells) == 'function' then
    local spells = probe(actor.spells, object)
    if spells then
      local list = {}
      pcall(function()
        for _, spell in pairs(spells) do
          local id = readField(spell, 'id')
          if id then list[#list + 1] = { id = id, type = readField(spell, 'type') } end
        end
      end)
      if #list > 0 then
        table.sort(list, function(a, b) return tostring(a.id) < tostring(b.id) end)
        builder:set('spells', list)
      end
    end
  end

  if type(actor.activeSpells) == 'function' then
    local active = probe(actor.activeSpells, object)
    if active then
      local list = {}
      pcall(function()
        for _, spell in pairs(active) do
          local id = readField(spell, 'id')
          if id then list[#list + 1] = { id = id, temporary = readField(spell, 'temporary') } end
        end
      end)
      if #list > 0 then builder:set('activeSpells', list) end
    end
  end

  if type(actor.getSelectedSpell) == 'function' then
    local selected = probe(actor.getSelectedSpell, object)
    if selected then
      local id = readField(selected, 'id')
      builder:set('selectedSpell', id or (type(selected) == 'string' and selected or nil))
    end
  end

  -- movement and load, which is what "can I do anything right now" depends on
  local plain = {
    runSpeed = actor.getRunSpeed, walkSpeed = actor.getWalkSpeed,
    currentSpeed = actor.getCurrentSpeed, encumbrance = actor.getEncumbrance,
    capacity = actor.getCapacity, canMove = actor.canMove,
    swimming = actor.isSwimming, onGround = actor.isOnGround,
  }
  for name, getter in pairs(plain) do
    if type(getter) == 'function' then
      local value = probe(getter, object)
      if value ~= nil then builder:set(name, value) end
    end
  end
  if type(actor.getStance) == 'function' then
    local stance = probe(actor.getStance, object)
    -- the engine gives a number from Actor.STANCE; name it through the enum
    builder:set('stance', stanceName(actor, stance))
  end
end

--- What the actor is wearing and wielding.
---
--- `Actor.getEquipment(actor)` with a single argument returns slot -> GameObject
--- (types.lua:170-180). Slots come back as numbers, so they are named through
--- Actor.EQUIPMENT_SLOT rather than a list of names we would have to keep in step.
local function readEquipment(builder, object, env)
  local actor = env.types and env.types.Actor
  if not actor or type(actor.getEquipment) ~= 'function' then return end
  local worn = probe(actor.getEquipment, object)
  if type(worn) ~= 'table' then return end

  local equipment = {}
  for slot, item in pairs(worn) do
    local name = slotName(actor, slot)
    local read = M.read(item, env)
    equipment[name] = read or { id = readField(item, 'id'), kind = 'item' }
  end
  if next(equipment) then builder:set('equipment', equipment) end
end

--- Factions and lycanthropy: NPC-scoped, and the closest thing to "standing" the engine has.
local function readStanding(builder, object, env)
  local npc = env.types and env.types.NPC
  if not npc then return end

  if type(npc.getFactions) == 'function' then
    local ids = probe(npc.getFactions, object)
    if type(ids) == 'table' then
      local factions = {}
      for _, id in ipairs(ids) do
        if type(npc.getFactionRank) == 'function' then
          local rank = probe(npc.getFactionRank, object, id)
          if rank ~= nil then factions[tostring(id)] = rank end
        else
          factions[tostring(id)] = nil
        end
      end
      if next(factions) then builder:set('factions', factions) end
    end
  end

  if type(npc.isWerewolf) == 'function' then
    local werewolf = probe(npc.isWerewolf, object)
    if type(werewolf) == 'boolean' then builder:set('werewolf', werewolf) end
  end
end

local function readActor(builder, object, env)
  local engineTypes = env.types
  local actor = engineTypes and engineTypes.Actor
  if not actor then return end

  local stats = actor.stats
  -- Level and level progress are read by readSheet: the engine's LevelStat has BOTH `current`
  -- and `progress` (types.lua:443-445), and having the old `stats.level.level` guess here as
  -- well meant a bean reached math.floor and threw.
  if actor.isDead then
    local dead = probe(actor.isDead, object)
    if type(dead) == 'boolean' then builder:set('dead', dead) end
  end

  readSheet(builder, object, env)
  readEquipment(builder, object, env)
  readStanding(builder, object, env)

  readPool(builder, 'health', object, env)
  readPool(builder, 'magicka', object, env)
  readPool(builder, 'fatigue', object, env)

  -- AI dispositions, NOT a hostility flag: 0..100 how likely to fight/flee/greet.
  if stats and stats.ai then
    local ai = {}
    for _, key in ipairs({ 'alarm', 'fight', 'flee', 'hello' }) do
      local getter = stats.ai[key]
      if type(getter) == 'function' then
        local value = probe(getter, object)
        if value ~= nil then ai[key] = value end
      end
    end
    if next(ai) then builder:set('ai', ai) end
  end

  -- disposition exists on NPCs only
  local npc = engineTypes.NPC
  if npc and type(npc.getDisposition) == 'function' and env.self then
    local disposition = probe(npc.getDisposition, object, env.self)
    if disposition ~= nil then builder:set('disposition', disposition) end
  end
  if npc and npc.record and type(npc.record) == 'function' then
    local record = probe(npc.record, object)
    if record then
      builder:set('race', readField(record, 'race'))
      builder:set('class', readField(record, 'class'))
      local faction = readField(record, 'faction')
      if faction and faction ~= '' then builder:set('faction', faction) end
    end
  end

  -- services and travel offers, which the engine does expose
  local function readRecordField(name)
    if not (actor.record and type(actor.record) == 'function') then return nil end
    local record = probe(actor.record, object)
    if not record then return nil end
    return readField(record, name)
  end
  local services = readRecordField('servicesOffered')
  if util.isObject(services) then
    local out = {}
    for service, offered in pairs(services) do
      if offered == true then out[tostring(service)] = true end
    end
    if next(out) then builder:set('services', out) end
  end

  -- inventory as item stacks
  local inventory = actor.inventory and probe(actor.inventory, object)
  if inventory then
    local stacks = {}
    local ok = pcall(function()
      for _, item in ipairs(inventory:getAll()) do
        local stack = M.read(item, env)
        if stack then stacks[#stacks + 1] = stack end
      end
    end)
    if ok and #stacks > 0 then builder:set('inventory', entity.sortStacks(stacks)) end
  end
end

local function readDoor(builder, object, env)
  local engineTypes = env.types
  local door = engineTypes and engineTypes.Door
  if not door then return end
  if door.destCell and type(door.destCell) == 'function' then
    local destCell = probe(door.destCell, object)
    if destCell and destCell.name then builder:set('destCell', readField(destCell, 'name')) end
  end
  if door.destPosition and type(door.destPosition) == 'function' then
    local dest = probe(door.destPosition, object)
    if dest then
      local x = readField(dest, 'x')
      if type(x) == 'number' then
        builder:set('destPosition', { x = x, y = readField(dest, 'y'), z = readField(dest, 'z') })
      end
    end
  end
  if door.isTeleport and type(door.isTeleport) == 'function' then
    local teleport = probe(door.isTeleport, object)
    if type(teleport) == 'boolean' then builder:set('isTeleport', teleport) end
  end
end

local function readContainer(builder, object, env)
  local engineTypes = env.types
  local container = engineTypes and engineTypes.Container
  if not container then return end
  -- the engine names these getCapacity / content (types.lua:2243, 2279)
  if type(container.getCapacity) == 'function' then
    builder:set('capacity', probe(container.getCapacity, object))
  end
  if container.content and type(container.content) == 'function' then
    local content = probe(container.content, object)
    if util.isObject(content) then
      local stacks = {}
      pcall(function()
        for _, item in ipairs(content:getAll()) do
          local stack = M.read(item, env)
          if stack then stacks[#stacks + 1] = stack end
        end
      end)
      builder:set('inventory', entity.sortStacks(stacks))
    end
  end
end

local function readItem(builder, object, env)
  local engineTypes = env.types
  local item = engineTypes and engineTypes.Item
  if not item then return end
  if item.count and type(item.count) == 'function' then
    local count = probe(item.count, object)
    if type(count) == 'number' then builder:set('count', count) end
  end
  if item.itemData and type(item.itemData) == 'function' then
    local data = probe(item.itemData, object)
    if data then
      builder:set('condition', readField(data, 'condition'))
      builder:set('enchantmentCharge', readField(data, 'enchantmentCharge'))
      local soul = readField(data, 'soul')
      if soul and soul ~= '' then builder:set('soul', soul) end
    end
  end
end

--- Read one engine object into a schema entity.
--- @param object engine GameObject
--- @param env table|nil the injected engine env (defaults to scripts.runtime.engine.env())
--- @param fromPosition table|nil the player position, for distance/vertical
--- @return table|nil entity
function M.read(object, env, fromPosition)
  if not util.isObject(object) then return nil end
  env = env or engine.env()
  local kind = M.kindOf(object, env)
  if not kind then return nil end

  local builder = entity.new(kind)
  readIdentity(builder, object, env)
  readFormId(builder, object, env)

  if kind == 'player' or kind == 'npc' or kind == 'creature' then
    readActor(builder, object, env)
  elseif kind == 'door' then
    readDoor(builder, object, env)
  elseif kind == 'container' then
    readContainer(builder, object, env)
  elseif kind == 'item' then
    readItem(builder, object, env)
  end

  local out = builder:get()
  if fromPosition then entity.derivePlacement(out, fromPosition) end
  entity.compact(out)
  return out
end

--- Read a cell's METADATA. Contents are deliberately not included: `cell:getAll()` is
--- global-only and force-loads the cell (core.lua:337-346), so it belongs to a deliberate
--- request, not to every read.
function M.readCell(cell, env)
  env = env or engine.env()
  if not util.isObject(cell) then return nil end
  local builder = entity.new('cell')
  builder:set('id', readField(cell, 'id'))
  builder:set('name', readField(cell, 'name'))
  builder:set('displayName', readField(cell, 'displayName'))
  builder:set('region', readField(cell, 'region'))
  builder:set('isExterior', readField(cell, 'isExterior'))
  builder:set('gridX', readField(cell, 'gridX'))
  builder:set('gridY', readField(cell, 'gridY'))
  builder:set('hasWater', readField(cell, 'hasWater'))
  builder:set('waterLevel', readField(cell, 'waterLevel'))
  builder:set('hasSky', readField(cell, 'hasSky'))
  builder:set('worldSpaceId', readField(cell, 'worldSpaceId'))
  builder:set('contentsFetched', false)
  local out = builder:get()
  entity.compact(out)
  return out
end

--- Read a list of engine objects, dropping anything unreadable rather than emitting holes.
function M.readList(objects, env, fromPosition)
  local out = {}
  if type(objects) ~= 'table' then return out end
  env = env or engine.env()
  for _, object in ipairs(objects) do
    local read = M.read(object, env, fromPosition)
    if read then out[#out + 1] = read end
  end
  return out
end

--- Read the named `nearby` lists into schema entities, nearest first.
--- @param lists table|nil which nearby lists to read (default: all of them)
function M.readNearby(env, fromPosition, lists)
  env = env or engine.env()
  local nearby = env.nearby
  if not nearby then return nil end
  local wanted = lists or { 'actors', 'doors', 'containers', 'items', 'activators' }
  local out = {}
  for _, listName in ipairs(wanted) do
    local list = nearby[listName]
    if type(list) == 'table' then
      for _, read in ipairs(M.readList(list, env, fromPosition)) do
        read.list = listName
        out[#out + 1] = read
      end
    end
  end
  table.sort(out, function(a, b)
    local da, db = a.distance or math.huge, b.distance or math.huge
    if da ~= db then return da < db end
    return tostring(a.id or '') < tostring(b.id or '')
  end)
  return out
end

return M
