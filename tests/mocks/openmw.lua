-- tests/mocks/openmw.lua
-- A fake OpenMW engine good enough to exercise scripts/runtime/* headlessly.
--
--   local mocks = require('tests.mocks.openmw')
--   local env = mocks.install({ ... })      -- also wires package.preload
--   local engine = require('scripts.runtime.engine')
--   assert.equals(engine.types(), env.types)
--   mocks.uninstall()
--
-- The mock keeps round-trip state (inventory counts, stat pools, equipment) so
-- behaviour like "sell junk -> gold goes up" and "equip -> slot filled" can
-- actually be asserted.

local classPriorities = require('scripts.idle.classPriorities')

local M = {}

local ENGINE_MODULES = {
  'openmw.self', 'openmw.world', 'openmw.types', 'openmw.nearby', 'openmw.util',
  'openmw.core', 'openmw.storage', 'openmw.async', 'openmw.interfaces',
  'openmw.input', 'openmw.ui', 'openmw.camera', 'openmw.markup',
}

-- ---------------------------------------------------------------------------
-- engine data tables, mirroring the real numeric values' *names*
-- ---------------------------------------------------------------------------

--- Item type tables, as bound by apps/openmw/mwlua/types/*.cpp.
local TYPE_CLASSES = {
  Armor = { TYPE = { Helmet = 0, Cuirass = 1, LPauldron = 2, RPauldron = 3, Greaves = 4,
                     Boots = 5, LGauntlet = 6, RGauntlet = 7, Shield = 8,
                     LBracer = 9, RBracer = 10 } },
  Clothing = { TYPE = { Amulet = 0, Belt = 1, LGlove = 2, Pants = 3, RGlove = 4,
                        Ring = 5, Robe = 6, Shirt = 7, Shoes = 8, Skirt = 9 } },
  Weapon = { TYPE = { ShortBladeOneHand = 0, LongBladeOneHand = 1, LongBladeTwoHand = 2,
                      BluntOneHand = 3, BluntTwoClose = 4, BluntTwoWide = 5, SpearTwoWide = 6,
                      AxeOneHand = 7, AxeTwoHand = 8, MarksmanBow = 9, MarksmanCrossbow = 10,
                      MarksmanThrown = 11, Arrow = 12, Bolt = 13 } },
  Light = { TYPE = { Default = 0 } },
  Lockpick = { TYPE = {} }, Probe = { TYPE = {} }, Repair = { TYPE = {} },
  Apparatus = { TYPE = {} }, Potion = { TYPE = {} }, Ingredient = { TYPE = {} },
  Book = { TYPE = {} }, Miscellaneous = { TYPE = {} },
}

--- Equipment slot numbers (names matter; the numbers are mock-internal).
local EQUIPMENT_SLOT = {
  Helmet = 0, Cuirass = 1, Greaves = 2, LeftPauldron = 3, RightPauldron = 4,
  LeftGauntlet = 5, RightGauntlet = 6, Boots = 7, Shirt = 8, Pants = 9, Skirt = 10,
  Robe = 11, LeftRing = 12, RightRing = 13, Amulet = 14, Belt = 15,
  CarriedRight = 16, CarriedLeft = 17, Ammunition = 18, NoSlot = -1,
}

local function point(p)
  p = p or {}
  return { x = p.x or 0, y = p.y or 0, z = p.z or 0 }
end

local function dynamicStat(spec)
  spec = spec or {}
  local base = spec.base or spec.current or 100
  return { base = base, current = spec.current or base, modifier = spec.modifier or 0 }
end

-- ---------------------------------------------------------------------------
-- inventory
-- ---------------------------------------------------------------------------

--- An inventory: a live store + the documented Inventory methods.
--- An item spec may carry `class` (which type class it is) and `recordType`.
local function newInventory(items, gold, types)
  local store = {}
  local function ensure(id)
    store[id] = store[id] or { count = 0, value = 0, weight = 0, equipped = false,
                               class = 'Miscellaneous', recordType = 0 }
    return store[id]
  end

  for _, item in ipairs(items or {}) do
    local entry = ensure(item.id)
    entry.count = entry.count + (item.count or 1)
    entry.value = item.value or entry.value
    entry.weight = item.weight or entry.weight
    entry.equipped = item.equipped or entry.equipped
    entry.class = item.class or entry.class
    if item.recordType ~= nil then entry.recordType = item.recordType end
  end
  if gold then ensure('gold_001').count = gold end

  --- A GameObject-like item whose `.type` IS the engine type class table,
  --- exactly as the real API presents it.
  local function itemObject(id)
    local entry = store[id]
    local typeClass = types[entry.class] or TYPE_CLASSES.Miscellaneous
    return {
      recordId = id,
      count = entry.count,
      type = typeClass,
      remove = function(_, n) entry.count = math.max(0, entry.count - (n or entry.count)) end,
    }
  end

  local inventory = { _store = store }
  function inventory:countOf(id)
    local entry = store[id]
    return entry and entry.count or 0
  end
  function inventory:find(id)
    local entry = store[id]
    if not entry or entry.count <= 0 then return nil end
    return itemObject(id)
  end
  function inventory:getAll()
    local out = {}
    for id, entry in pairs(store) do
      if entry.count > 0 then out[#out + 1] = itemObject(id) end
    end
    return out
  end
  function inventory:_insert(id, count)
    local entry = ensure(id)
    entry.count = entry.count + (count or 1)
  end
  function inventory:_entry(id) return store[id] end
  return inventory
end

--- Records with value/weight/type, attached to the type class at build time.
local function attachRecords(types, inventory)
  for id, entry in pairs(inventory._store) do
    local typeClass = types[entry.class] or TYPE_CLASSES.Miscellaneous
    if typeClass then
      typeClass.record = function(object)
        local target = object and object.recordId and inventory._store[object.recordId] or entry
        return {
          id = target and target.recordId or id,
          value = target and target.value or entry.value,
          weight = target and target.weight or entry.weight,
          type = target and target.recordType or entry.recordType,
        }
      end
    end
  end
end

local typeClassesFallback = TYPE_CLASSES.Miscellaneous

local function makeActorObject(actor)  return {
    recordId = actor.recordId,
    count = actor.count or 1,
    type = TYPE_CLASSES.Miscellaneous,
    -- mock-only: lets the per-actor types.Actor.stats.* / kind.record getters
    -- find the spec that described this actor (a real GameObject is engine-side).
    _spec = actor,
    moveInto = function(_, inventory)
      if inventory and inventory._insert then inventory:_insert(actor.recordId, actor.count or 1) end
    end,
    remove = function(_, n) actor.removed = (actor.removed or 0) + (n or 1) end,
    activateBy = function() actor.activated = (actor.activated or 0) + 1 end,
    teleport = function() end,
    split = function() end,
  }
end

-- ---------------------------------------------------------------------------
-- env
-- ---------------------------------------------------------------------------

--- Build a fake engine env.
--- @param spec table see tests/spec/runtime_spec.lua for the full surface
function M.env(spec)
  spec = spec or {}

  local inventory -- forward declaration: the types table below closes over it

  local equipmentBySlot = {}
  local equipCalls = {}

  -- ---- storage (real, in-memory) -----------------------------------------
  local playerSections, globalSections = {}, {}
  local function sectionFor(scope, name)
    name = name or 'IdleOpenMW'
    if not scope[name] then
      local data = {}
      scope[name] = {
        _data = data,
        get = function(self, key) return self._data[key] end,
        set = function(self, key, value) self._data[key] = value return true end,
        remove = function(self, key) self._data[key] = nil return true end,
        has = function(self, key) return self._data[key] ~= nil end,
      }
    end
    return scope[name]
  end

  -- ---- types -------------------------------------------------------------
  -- A real NpcRecord/CreatureRecord. Note servicesOffered and
  -- travelDestinations: these are the fields scripts/idle/worldsense.lua reads.
  local function actorRecord(entry)
    entry = entry or {}
    return {
      id = entry.recordId,
      name = entry.name or entry.recordId,
      class = entry.classId or 'warrior',
      servicesOffered = entry.servicesOffered,
      travelDestinations = entry.travelDestinations,
      isEssential = entry.isEssential,
    }
  end

  local types = {
    Armor = TYPE_CLASSES.Armor,
    Clothing = TYPE_CLASSES.Clothing,
    Weapon = TYPE_CLASSES.Weapon,
    Light = TYPE_CLASSES.Light,
    Lockpick = TYPE_CLASSES.Lockpick,
    Probe = TYPE_CLASSES.Probe,
    Repair = TYPE_CLASSES.Repair,
    Apparatus = TYPE_CLASSES.Apparatus,
    Potion = TYPE_CLASSES.Potion,
    Ingredient = TYPE_CLASSES.Ingredient,
    Book = TYPE_CLASSES.Book,
    Miscellaneous = TYPE_CLASSES.Miscellaneous,
    Item = {},
    Player = {},
    NPC = {},
    Creature = {},
    -- Distinct sentinels so tap-to-move's pick classification is testable
    -- (idleDirector.classifyPick compares object.type against these).
    Door = { __name = 'Door' },
    Activator = { __name = 'Activator' },
    Container = { __name = 'Container' },
  }

  local actor = { recordId = spec.recordId or 'player' }

  local controls = {
    movement = 0, sideMovement = 0, yawChange = 0, pitchChange = 0,
    run = false, sneak = false, jump = false,
  }

  local skillStats = {}
  for _, category in ipairs(classPriorities.CATEGORIES) do
    for _, skillId in ipairs(classPriorities.skillsInCategory(category)) do
      skillStats[skillId] = { base = 5, modified = 5, progress = 0 }
    end
  end
  for id, values in pairs(spec.skills or {}) do
    local v = type(values) == 'table' and values or { base = values, modified = values }
    skillStats[id] = { base = v.base or 5, modified = v.modified or v.base or 5, progress = v.progress or 0 }
  end

  local ATTRIBUTES = { 'strength', 'intelligence', 'willpower', 'agility', 'speed', 'endurance',
                       'personality', 'luck' }
  local attributeStats = {}
  for _, id in ipairs(ATTRIBUTES) do attributeStats[id] = { base = 40, modified = 40 } end
  for id, values in pairs(spec.attributes or {}) do
    local v = type(values) == 'table' and values or { base = values, modified = values }
    attributeStats[id] = { base = v.base or 40, modified = v.modified or v.base or 40 }
  end

  local pools = {
    health = dynamicStat(spec.health),
    magicka = dynamicStat(spec.magicka),
    fatigue = dynamicStat(spec.fatigue),
  }
  local levelStat = { current = spec.level or 1, progress = spec.levelProgress or 0 }

  local skillsApi, attributesApi = {}, {}
  for id, stat in pairs(skillStats) do skillsApi[id] = function() return stat end end
  for id, stat in pairs(attributeStats) do attributesApi[id] = function() return stat end end

  -- ---- inventory (needs `types` for item type classes) -------------------
  inventory = newInventory(spec.inventory, spec.gold, types)
  attachRecords(types, inventory)

  types.Creature = {
    record = function(target)
      local entry = type(target) == 'table' and target._spec or nil
      return actorRecord(entry)
    end,
  }

  types.Actor = {
    EQUIPMENT_SLOT = EQUIPMENT_SLOT,
    stats = {
      dynamic = {
        health = function() return pools.health end,
        magicka = function() return pools.magicka end,
        fatigue = function() return pools.fatigue end,
      },
      level = function(target)
        local entry = type(target) == 'table' and target._spec or nil
        if entry then return { current = entry.level or 1, progress = 0 } end
        return levelStat
      end,
      -- AI dispositions, 0..100, exactly as types.Actor.stats.ai exposes them.
      ai = {
        fight = function(target)
          local entry = type(target) == 'table' and target._spec or nil
          local value = entry and entry.fight or spec.fight
          if type(value) ~= 'number' then return nil end
          return { base = value, modified = value }
        end,
      },
    },
    inventory = function() return inventory end,
    record = function() return { capacity = spec.capacity or 400 } end,
    getEquipment = function()
      local out = {}
      for _slot, id in pairs(equipmentBySlot) do
        out[#out + 1] = { recordId = id }
      end
      for id, entry in pairs(inventory._store) do
        if entry.equipped and entry.count > 0 then out[#out + 1] = { recordId = id } end
      end
      return out
    end,
    getCapacity = function() return spec.capacity or 400 end,
    setEquipment = function(_actor, equipment)
      equipCalls[#equipCalls + 1] = equipment
      if spec.refuseEquip then error('the engine refused to equip (mock)') end
      equipmentBySlot = {}
      for slot, item in pairs(equipment or {}) do
        local id = type(item) == 'table' and (item.recordId or item.id) or item
        equipmentBySlot[slot] = id
        local entry = id and inventory._store[id]
        if entry then entry.equipped = true end
      end
    end,
    getBarterGold = function() return spec.barterGold or 500 end,
    setBarterGold = function() end,
    isDead = function() return false end,
    getStance = function() return 0 end,
    setStance = function() end,
    getSelectedSpell = function() return nil end,
    setSelectedSpell = function() end,
  }

  types.NPC = {
    record = function(target)
      local entry = type(target) == 'table' and target._spec or nil
      return actorRecord(entry or spec)
    end,
    classes = {
      record = function(classId)
        local preset = classPriorities.presets[classId]
        if preset then
          return {
            id = preset.id, name = preset.name, specialization = preset.specialization,
            majorSkills = preset.majorSkills, minorSkills = preset.minorSkills,
            attributes = preset.favoredAttributes,
          }
        end
        return spec.classRecord
      end,
    },
    stats = { skills = skillsApi, attributes = attributesApi },
  }

  types.Player = {
    journal = function()
      return { journalTextEntries = spec.journal or {}, topics = spec.journalTopics or {} }
    end,
    quests = function() return spec.quests or {} end,
    addTopic = function() end,
  }

  -- types.Player.isCharGenFinished (apps/openmw/mwlua/types/player.cpp:438): the
  -- definitive "has the player been released into the world" flag. Default true
  -- so ordinary specs are in the world; pass charGenFinished = false to model a
  -- character still being created (scripts/idle/lifecycle.lua).
  types.Player.isCharGenFinished = function()
    if spec.charGenFinished == nil then return true end
    return spec.charGenFinished == true
  end

  -- ---- nearby ------------------------------------------------------------
  -- `nearby.actors` is a list of GameObjects in the real API, so the mock hands
  -- back real objects too -- not a convenience wrapper with fields like
  -- `.services` or `.hostile` that the engine would never provide.
  local nearbyActors, nearbyContainers = {}, {}
  for _, entry in ipairs(spec.actors or {}) do
    local object = makeActorObject(entry)
    object.type = entry.creature and types.Creature or types.NPC
    object.position = point(entry.position)
    nearbyActors[#nearbyActors + 1] = object
  end
  for _, entry in ipairs(spec.containers or {}) do
    nearbyContainers[#nearbyContainers + 1] = {
      recordId = entry.recordId, position = point(entry.position), object = makeActorObject(entry),
    }
  end

  -- ---- ui ----------------------------------------------------------------
  local createdElements = {}
  local uiMock = {
    TYPE = { Widget = 'Widget', Text = 'Text', TextEdit = 'TextEdit', Window = 'Window',
             Image = 'Image', Flex = 'Flex', Container = 'Container' },
    ALIGNMENT = { Start = 1, Center = 2, End = 3 },
    layers = {},
    screenSize = function() return point(spec.screen or { x = 1080, y = 2340 }) end,
    content = function(list) return list end,
    showMessage = function() end,
    printToConsole = function() end,
    -- The one supported widget-injection point (uibindings.cpp:246); the
    -- capability probe looks for it (scripts/runtime/capabilities.lua).
    registerSettingsPage = function() end,
    -- The real live-UI hook: the window manager's GuiMode stack
    -- (apps/openmw/mwlua/uibindings.cpp:276). Array of mode names, newest last.
    _getUiModeStack = function() return spec.uiModes or {} end,
    create = function(layout)
      local element = { layout = layout, updates = 0, destroyed = false }
      function element:update() self.updates = self.updates + 1 end
      function element:destroy() self.destroyed = true end
      createdElements[#createdElements + 1] = element
      return element
    end,
  }

  -- ---- camera ------------------------------------------------------------
  -- Faithful to apps/openmw/mwlua/camerabindings.cpp: modes + the setters the
  -- isometric lock uses. Calls are recorded so specs can assert on them.
  local cameraCalls = {}
  local cameraMock = {
    MODE = { Static = 0, FirstPerson = 1, ThirdPerson = 2, Vanity = 3, Preview = 4 },
    setMode = function(mode) cameraCalls[#cameraCalls + 1] = { 'setMode', mode } end,
    setPitch = function(value) cameraCalls[#cameraCalls + 1] = { 'setPitch', value } end,
    setYaw = function(value) cameraCalls[#cameraCalls + 1] = { 'setYaw', value } end,
    setRoll = function(value) cameraCalls[#cameraCalls + 1] = { 'setRoll', value } end,
    setPreferredThirdPersonDistance = function(value)
      cameraCalls[#cameraCalls + 1] = { 'setDistance', value }
    end,
    getMode = function() return 2 end,
    -- Picking (camerabindings.cpp:103). Specs drive tap-to-move by setting
    -- spec.cameraDirection / spec.cameraPosition, and nearby.castRay's result.
    getPosition = function() return point(spec.cameraPosition or spec.position) end,
    viewportToWorldVector = function()
      return point(spec.cameraDirection or { x = 0, y = 1, z = 0 })
    end,
  }

  local createdObjects = {}

  local world = {
    players = { actor },
    activeActors = { actor },
    createObject = function(recordId, count)
      local object = makeActorObject({ recordId = recordId, count = count })
      createdObjects[#createdObjects + 1] = object
      return object
    end,
    createRecord = function() return {} end,
  }

  local self = {
    object = actor,
    position = point(spec.position),
    rotation = spec.rotation or 0,
    cell = spec.cell and { name = spec.cell.name, isExterior = spec.cell.isExterior } or nil,
    controls = controls,
    type = types.NPC,
    recordId = actor.recordId,
    enableAI = function() end,
  }

  local FIND_PATH_STATUS = { Success = 1, Failed = 0, InProgress = 2 }

  local nearby = {
    actors = nearbyActors,
    containers = nearbyContainers,
    doors = {}, activators = {}, items = {},
    FIND_PATH_STATUS = FIND_PATH_STATUS,
    COLLISION_TYPE = { Default = 1, Camera = 2, VisualOnly = 3 },
    -- Ray picking for tap-to-move. Specs set spec.rayHit = { hitPos, hitObject }.
    castRay = function()
      local hit = spec.rayHit
      if not hit then return { hit = false } end
      return { hit = true, hitPos = point(hit.hitPos), hitObject = hit.hitObject }
    end,
    --- Faithful to the real API: returns TWO values (status, points).
    findPath = function(from, to)
      local points = {}
      local dx, dy, dz = (to.x or 0) - (from.x or 0), (to.y or 0) - (from.y or 0), (to.z or 0) - (from.z or 0)
      local total = math.sqrt(dx * dx + dy * dy + dz * dz)
      local count = math.max(1, math.ceil(total / 50))
      for i = 1, count do
        local t = i / count
        points[i] = { x = (from.x or 0) + dx * t, y = (from.y or 0) + dy * t, z = (from.z or 0) + dz * t }
      end
      if spec.findPathFails then return FIND_PATH_STATUS.Failed, nil end
      return FIND_PATH_STATUS.Success, points
    end,
  }

  local interfaceCalls = {}
  local uiModesSet = {}

  -- Global events the scripts send. The guardian's two rescue actions
  -- (teleport / loadGame) go out this way -- see scripts/idleWarden.lua.
  local globalEvents = {}

  local env = {
    self = self,
    world = world,
    types = types,
    nearby = nearby,
    util = {
      vector2 = function(x, y) return { x = x or 0, y = y or 0 } end,
      vector3 = function(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end,
      color = {
        rgb = function(r, g, b) return { r = r, g = g, b = b } end,
        rgba = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end,
      },
    },
    core = {
      getSimulationTime = function() return spec.simulationTime or 0 end,
      getGameTime = function() return spec.gameTime or 0 end,
      getRealTime = function() return spec.realTime or 0 end,
      getSimulationTimeScale = function() return 1 end,
      -- Morrowind's font colours are exposed as "r,g,b" strings
      -- (files/openmw.cfg fallback=FontColor_color_*). Absent by default so the
      -- theme falls back to its shipped palette, exactly as on a bare engine.
      getGMST = function(name) return spec.gmst and spec.gmst[name] or nil end,
      -- The engine's Lua API revision (core.lua:11), read by
      -- scripts/runtime/capabilities.lua. Override with spec.apiRevision.
      API_REVISION = spec.apiRevision or 100,
      -- Recorded, not dropped: the guardian's two rescue actions go out this way
      -- (see scripts/idleWarden.lua), so tests must be able to see them.
      sendGlobalEvent = function(name, data)
        globalEvents[#globalEvents + 1] = { name = name, data = data }
      end,
    },
    storage = {
      -- A real in-memory section store, so persistence round-trips can be tested.
      -- Sections are keyed by name, exactly as openmw.storage behaves.
      playerSection = function(name) return sectionFor(playerSections, name) end,
      globalSection = function(name) return sectionFor(globalSections, name) end,
    },
    async = {
      registerTimerCallback = function() return function() end end,
      newSimulationTimer = function() return { cancel = function() end } end,
      newGameTimer = function() return { cancel = function() end } end,
      newRealTimeTimer = function() return { cancel = function() end } end,
      -- `async.callback` is a METHOD on the engine (async.lua:54 documents `@param self`,
      -- and the engine's own scripts all write `async:callback(...)`). Calling it with a
      -- dot passes the function where the package id belongs and throws
      -- "expected userdata, received function" -- which silently disabled the console
      -- in a real game. This mock reproduces that strictness so the bug cannot come back.
      callback = function(self, fn)
        -- `self` must be the async package itself: called as `async.callback(fn)` the
        -- first argument arrives as `fn`, which is exactly the real engine's failure.
        if type(self) ~= 'table' or type(self.registerTimerCallback) ~= 'function' then
          error('async.callback must be called as a method: async:callback(fn)', 2)
        end
        return fn
      end,
    },
    interfaces = {
      AI = { startPackage = function() end },
      Controls = {
        overrideMovementControls = function(...) interfaceCalls[#interfaceCalls + 1] = { 'movement', ... } end,
        overrideCombatControls = function() end,
        overrideUiControls = function() end,
      },
      UI = {
        MODE = { Interface = 'Interface', Journal = 'Journal', Dialogue = 'Dialogue',
                 Barter = 'Barter', Rest = 'Rest', Training = 'Training' },
        setMode = function(mode, options)
          uiModesSet[#uiModesSet + 1] = { mode = mode, options = options }
        end,
        getMode = function() return uiModesSet[#uiModesSet] and uiModesSet[#uiModesSet].mode end,
      },
      MWUI = {
        templates = {
          boxTransparentThick = { name = 'boxTransparentThick' },
          boxTransparent = { name = 'boxTransparent' },
          boxSolidThick = { name = 'boxSolidThick' },
          textNormal = { name = 'textNormal' },
          textHeader = { name = 'textHeader' },
        },
      },
    },
    input = { KEY = { L = 38 } },
    ui = uiMock,
    camera = cameraMock,
    -- Optional escape hatches, mirroring what observer.scanWorld accepts as
    -- opts.isHostile / opts.servicesOf. They are NOT real engine fields, so they
    -- are absent by default: the default classification must go through the real
    -- record + worldsense, or the mock would be hiding exactly the bugs the
    -- headless suite exists to catch.
    servicesOf = spec.servicesOf,
    isHostile = spec.isHostile,
    -- test introspection
    _createdObjects = createdObjects,
    _createdElements = createdElements,
    _playerSections = playerSections,
    _globalSections = globalSections,
    _equipCalls = equipCalls,
    _equipmentBySlot = function() return equipmentBySlot end,
    _interfaceCalls = interfaceCalls,
    _uiModesSet = uiModesSet,
    _cameraCalls = cameraCalls,
    _setUiModes = function(modes) spec.uiModes = modes end,
    _setRayHit = function(hit) spec.rayHit = hit end,
    _pools = pools,
    _globalEvents = globalEvents,
  }

  return env
end

-- ---------------------------------------------------------------------------
-- package.preload wiring (so scripts/runtime/engine.lua resolves the mock)
-- ---------------------------------------------------------------------------

function M.install(spec)
  local env = M.env(spec)
  local modules = {
    ['openmw.self'] = env.self,
    ['openmw.world'] = env.world,
    ['openmw.types'] = env.types,
    ['openmw.nearby'] = env.nearby,
    ['openmw.util'] = env.util,
    ['openmw.core'] = env.core,
    ['openmw.storage'] = env.storage,
    ['openmw.async'] = env.async,
    ['openmw.interfaces'] = env.interfaces,
    ['openmw.input'] = env.input,
    ['openmw.ui'] = env.ui,
    ['openmw.camera'] = env.camera,
  }
  for name, value in pairs(modules) do
    package.loaded[name] = nil
    package.preload[name] = function() return value end
  end
  require('scripts.runtime.engine').reset()
  env._modules = modules
  return env
end

function M.uninstall()
  for _, name in ipairs(ENGINE_MODULES) do
    package.preload[name] = nil
    package.loaded[name] = nil
  end
  require('scripts.runtime.engine').reset()
end

--- A nav port that returns a straight line of waypoints (for pathfinder tests).
function M.nav(step, failAt)
  local nav = { calls = 0 }
  nav.findPath = function(from, to)
    nav.calls = nav.calls + 1
    if failAt then return false, nil end
    local points = {}
    local dx, dy, dz = (to.x or 0) - (from.x or 0), (to.y or 0) - (from.y or 0), (to.z or 0) - (from.z or 0)
    local total = math.sqrt(dx * dx + dy * dy + dz * dz)
    local count = math.max(1, math.ceil(total / (step or 50)))
    for i = 1, count do
      local t = i / count
      points[i] = { x = (from.x or 0) + dx * t, y = (from.y or 0) + dy * t, z = (from.z or 0) + dz * t }
    end
    return true, points
  end
  return nav
end

return M
