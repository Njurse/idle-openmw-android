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
local equipment = require('scripts.idle.equipment')
local worldsense = require('scripts.idle.worldsense')
local uiState = require('scripts.idle.uiState')
local lifecycle = require('scripts.idle.lifecycle')

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
        local resolved = equipment.resolve(object.type, record, env.types)
        out[#out + 1] = {
          id = id,
          count = num(object.count, 1),
          value = num(record and record.value, 0),
          weight = num(record and record.weight, 0),
          equipped = id and equipped[id] or false,
          quest = false,
          kind = resolved.kind,
          typeName = resolved.typeName,
          equipSlot = resolved.slot,
          equippable = resolved.equippable,
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
  return { shop = 0, trainer = 0, healing = 0, repair = 0, travel = 0, enchant = 0,
           rest = 0, talk = 0, quest = 0, loot = 0, unexplored = 0 }
end

--- An actor's level, read the way the engine exposes it (works on any actor).
local function actorLevel(env, object)
  local stats = env.types and env.types.Actor and env.types.Actor.stats
  local stat = safe(stats and stats.level, object)
  return num(stat and (stat.current or stat.base), 1)
end

--- An actor's AI Fight disposition (0..100), or nil when the engine has none.
local function actorFight(env, object)
  local stats = env.types and env.types.Actor and env.types.Actor.stats
  local ai = stats and stats.ai
  local stat = safe(ai and ai.fight, object)
  if type(stat) == 'table' then return num(stat.modified, num(stat.base, nil)) end
  return nil
end

--- Turn one nearby GameObject into a worldsense descriptor, reading the actor's
--- real record (`object.type.record(object)`).
local function describeActor(env, object, cfg)
  local kind = type(object) == 'table' and object.type or nil
  local record = safe(kind and kind.record, object)
  return worldsense.describe({
    record = type(record) == 'table' and record or {},
    isCreature = kind ~= nil and kind == env.types.Creature,
    fight = actorFight(env, object),
    level = actorLevel(env, object),
    name = type(object) == 'table' and (object.name or object.recordId) or nil,
    id = type(object) == 'table' and object.recordId or nil,
    position = point(type(object) == 'table' and object.position or nil),
    object = object,
  }, cfg)
end

--- Scan what is around the player.
---
--- Services come from the real `NpcRecord`/`CreatureRecord.servicesOffered` and
--- `travelDestinations` (docs/openmw-lua-api.md §9) via scripts/idle/worldsense.lua.
--- Hostility is worldsense's documented heuristic, because the engine exposes no
--- direct "at war with the player" flag. `opts.servicesOf` / `opts.isHostile`
--- remain escape hatches that override the defaults.
function M.scanWorld(env, opts, player)
  opts = opts or {}
  local cfg = opts.cfg
  local radius = num(opts.scanRadius, M.DEFAULT_SCAN_RADIUS)
  local position = player and player.position

  local descriptors = {}
  for _, object in ipairs((env.nearby and env.nearby.actors) or {}) do
    descriptors[#descriptors + 1] = describeActor(env, object, cfg)
  end

  -- escape hatch 1: an explicit hostility verdict wins over the heuristic
  local isHostile = opts.isHostile or env.isHostile
  if isHostile then
    for _, descriptor in ipairs(descriptors) do
      local verdict = safe(isHostile, descriptor.object)
      if verdict ~= nil then descriptor.hostile = verdict and true or false end
    end
  end

  -- escape hatch 2: caller-supplied services win over the record's
  local servicesOf = opts.servicesOf or env.servicesOf
  if servicesOf then
    for _, descriptor in ipairs(descriptors) do
      local services = safe(servicesOf, descriptor.object)
      if type(services) == 'table' then
        for role, value in pairs(services) do descriptor.roles[role] = value and true or false end
        descriptor.offersServices = descriptor.roles.services or descriptor.roles.travel
      end
    end
  end

  local scan = worldsense.scan(descriptors, {
    position = position,
    scanRadius = radius,
    questingWeight = (cfg and cfg.sensing and cfg.sensing.questingWeight) or 0.6,
  })

  local opportunities = emptyOpportunities()
  for key, value in pairs(scan.opportunities) do opportunities[key] = value end
  local nearest = scan.nearest
  local enemies = scan.enemies

  local function proximity(at)
    if not position or not at then return 0.5 end
    local d = util.distance(position, at)
    if not d then return 0.5 end
    return util.clamp(1 - d / radius, 0, 1)
  end

  -- containers are not actors, so worldsense does not see them
  for _, container in ipairs((env.nearby and env.nearby.containers) or {}) do
    local at = point(container.position)
    local closeness = proximity(at)
    if closeness > opportunities.loot then opportunities.loot = closeness end
    local distance = (position and at) and util.distance(position, at) or nil
    local current = nearest.loot
    if not current or (distance and distance < (current.distance or math.huge)) then
      nearest.loot = {
        name = type(container) == 'table' and container.recordId or nil,
        position = at,
        distance = distance,
        object = container,
      }
    end
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

--- Read the engine's *live* UI mode stack and classify it.
---
--- This is the real "UI hook": `ui._getUiModeStack()` returns the window
--- manager's current GuiMode stack (apps/openmw/mwlua/uibindings.cpp:276). We
--- fall back to `interfaces.UI.getMode()` when the internal hook is absent, so
--- an engine without it degrades to "we know one mode" rather than guessing.
--- See scripts/idle/uiState.lua for the vocabulary.
function M.readUi(env)
  local stack

  local ui = env.ui
  if ui then
    local raw = safe(ui._getUiModeStack)
    if type(raw) == 'table' then
      stack = {}
      for i = 1, #raw do
        if type(raw[i]) == 'string' and raw[i] ~= '' then stack[#stack + 1] = raw[i] end
      end
      if #stack == 0 then stack = nil end
    end
  end

  local fallback
  if not stack then
    local interfaces = env.interfaces
    local Ui = interfaces and interfaces.UI
    local mode = Ui and safe(Ui.getMode, Ui)
    if type(mode) == 'string' and mode ~= '' then fallback = mode end
  end

  return uiState.fromStack(stack, fallback)
end

--- Read the signals scripts/idle/lifecycle.lua needs to place us in the game's
--- life: whether character creation is finished and whether the actor is dead.
---
--- `types.Player.isCharGenFinished` (apps/openmw/mwlua/types/player.cpp:438) is
--- the definitive "has the player been released into the world" flag; nil means
--- the engine did not expose it, and lifecycle.lua treats unknown as "in world"
--- so the mod is never locked out.
function M.readLifecycle(env)
  local self = env.self or {}
  local actor = self.object or self

  local finished
  local Player = env.types and env.types.Player
  if Player and type(Player.isCharGenFinished) == 'function' then
    local value = safe(Player.isCharGenFinished, actor)
    if type(value) == 'boolean' then finished = value end
  end

  local health = safe(function() return env.types.Actor.stats.dynamic.health(actor) end)
  local dead = type(health) == 'table' and health.current ~= nil and health.current <= 0

  return {
    playerExists = actor ~= nil,
    charGenFinished = finished,
    dead = dead and true or false,
  }
end

--- Recent journal entries (newest last), for the console's Talk tab.
function M.readJournal(env, actor)
  local out = {}
  local Player = env.types and env.types.Player
  if not Player or type(Player.journal) ~= 'function' then return out end
  local journal = safe(Player.journal, actor)
  if type(journal) ~= 'table' then return out end
  local entries = journal.journalTextEntries
  if type(entries) ~= 'table' then return out end

  local count = #entries
  for i = math.max(1, count - 19), count do
    local entry = entries[i]
    if type(entry) == 'table' then
      out[#out + 1] = { text = entry.text, questId = entry.questId, day = entry.day }
    end
  end
  return out
end

--- The conversation topics the player has accumulated, sorted by name.
---
--- `types.Player.journal(player).topics` is a **map** topicName -> PlayerJournalTopic,
--- each holding the lines heard for it (types.lua:1383). This is the closest the
--- engine gets to "the dialogue options you have unlocked": what you can *say* to
--- an NPC. (We cannot pick one for you -- selecting a topic is a UI action Lua
--- has no hook for -- but the console lists them, and tapping one walks you over
--- and opens the real dialogue window. See docs/dialogue.md.)
function M.readJournalTopics(env, actor)
  local out = {}
  local Player = env.types and env.types.Player
  if not Player or type(Player.journal) ~= 'function' then return out end
  local journal = safe(Player.journal, actor)
  if type(journal) ~= 'table' or type(journal.topics) ~= 'table' then return out end

  for name, topic in pairs(journal.topics) do
    if type(name) == 'string' and name ~= '' then
      local lines = 0
      local entries = type(topic) == 'table' and topic.entries or nil
      if type(entries) == 'table' then lines = #entries end
      out[#out + 1] = { topic = name, lines = lines }
    end
  end
  table.sort(out, function(a, b) return a.topic < b.topic end)
  return out
end

--- Started, unfinished quests, sorted by id (deterministic).
function M.readQuests(env, actor)
  local out = {}
  local Player = env.types and env.types.Player
  if not Player or type(Player.quests) ~= 'function' then return out end
  local quests = safe(Player.quests, actor)
  if type(quests) ~= 'table' then return out end

  for id, quest in pairs(quests) do
    if type(quest) == 'table' and quest.started and not quest.finished then
      out[#out + 1] = {
        id = quest.id or id,
        stage = quest.stage,
        started = quest.started,
        finished = quest.finished,
      }
    end
  end
  table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return out
end

--- Everything the console UI needs from the ENGINE. The director-derived half
--- (status, mode, dialogue transcript, log) is added by idleDirector.lua.
--- See scripts/idle/uiModel.lua for the full panel-snapshot contract.
function M.readPanel(env, opts)
  opts = opts or {}
  local cfg = opts.cfg
  local player = M.readPlayer(env, opts)
  local actor = (env.self and env.self.object) or env.self

  local inventory = {}
  for _, item in ipairs(player.inventory) do
    local ratio = economy.valuePerWeight(item)
    inventory[#inventory + 1] = {
      id = item.id,
      count = item.count,
      value = item.value,
      weight = item.weight,
      equipped = item.equipped,
      quest = item.quest,
      kind = item.kind,
      typeName = item.typeName,
      equipSlot = item.equipSlot,
      equippable = item.equippable,
      valuePerWeight = (type(ratio) == 'number' and ratio < 1e9) and util.round(ratio, 1) or nil,
      junk = cfg and economy.isJunk(item, cfg) or false,
    }
  end

  return {
    player = {
      gold = player.gold,
      level = player.level,
      encumbrance = player.encumbrance,
      position = player.position,
      cell = player.cell,
    },
    inventory = inventory,
    journal = M.readJournal(env, actor),
    journalTopics = M.readJournalTopics(env, actor),
    quests = M.readQuests(env, actor),
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

  -- Where are we in the game's life, and what does the engine have on screen?
  -- The lifecycle phase gates the director (scripts/idle/lifecycle.lua): during
  -- character creation and the menu it must not touch the character.
  local ui = M.readUi(env)
  local life = M.readLifecycle(env)
  life.uiKind = ui.kind
  local phase = lifecycle.phase(life)

  return { player = player, world = world, time = time, ui = ui, lifecycle = life, phase = phase }
end

return M
