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

local function readActor(builder, object, env)
  local engineTypes = env.types
  local actor = engineTypes and engineTypes.Actor
  if not actor then return end

  local stats = actor.stats
  if stats and stats.level and type(stats.level) == 'function' then
    local level = probe(stats.level, object)
    if level then builder:set('level', math.floor(readField(level, 'level') or level)) end
  end
  if actor.isDead then
    local dead = probe(actor.isDead, object)
    if type(dead) == 'boolean' then builder:set('dead', dead) end
  end

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
