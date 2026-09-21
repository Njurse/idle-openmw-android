-- tests/mocks/openmw.lua
-- A fake OpenMW engine good enough to exercise scripts/runtime/* headlessly.
--
--   local mocks = require('tests.mocks.openmw')
--   local env = mocks.install({ ... })      -- also wires package.preload
--   local engine = require('scripts.runtime.engine')
--   assert.equals(engine.types(), env.types)
--   mocks.uninstall()
--
-- The mock keeps round-trip state (inventory counts, stat pools) so behaviour
-- like "sell junk -> gold goes up" can actually be asserted.

local classPriorities = require('scripts.idle.classPriorities')

local M = {}

local ENGINE_MODULES = {
  'openmw.self', 'openmw.world', 'openmw.types', 'openmw.nearby', 'openmw.util',
  'openmw.core', 'openmw.storage', 'openmw.async', 'openmw.interfaces',
  'openmw.input', 'openmw.ui', 'openmw.camera', 'openmw.markup',
}

-- ---------------------------------------------------------------------------
-- small builders
-- ---------------------------------------------------------------------------

local function point(p)
  p = p or {}
  return { x = p.x or 0, y = p.y or 0, z = p.z or 0 }
end

local function dynamicStat(spec)
  spec = spec or {}
  local base = spec.base or spec.current or 100
  return { base = base, current = spec.current or base, modifier = spec.modifier or 0 }
end

--- An inventory: a live store + the documented Inventory methods.
local function newInventory(items, gold)
  local store = {}
  local function ensure(id)
    store[id] = store[id] or { count = 0, value = 0, weight = 0, equipped = false }
    return store[id]
  end

  for _, item in ipairs(items or {}) do
    local entry = ensure(item.id)
    entry.count = entry.count + (item.count or 1)
    entry.value = item.value or entry.value
    entry.weight = item.weight or entry.weight
    entry.equipped = item.equipped or entry.equipped
  end
  if gold then ensure('gold_001').count = gold end

  local function itemObject(id)
    local entry = store[id]
    return {
      recordId = id,
      count = entry.count,
      type = {
        record = function() return { id = id, value = entry.value, weight = entry.weight } end,
      },
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
  return inventory
end

local function makeActorObject(actor, store)
  return {
    recordId = actor.recordId,
    count = actor.count or 1,
    _store = store,
    type = { record = function() return { value = actor.value or 0, weight = actor.weight or 0 } end },
    moveInto = function(_, inventory)
      if inventory and inventory._insert then inventory:_insert(actor.recordId, actor.count or 1) end
    end,
    remove = function() end,
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

  local inventory = newInventory(spec.inventory, spec.gold)
  local actor = { recordId = spec.recordId or 'player' }
  local controls = {
    movement = 0, sideMovement = 0, yawChange = 0, pitchChange = 0,
    run = false, sneak = false, jump = false,
  }

  -- skills: every known skill defaults to 5, overridden by the spec
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

  local attributeStats = {}
  local ATTRIBUTES = {
    'strength', 'intelligence', 'willpower', 'agility', 'speed', 'endurance',
    'personality', 'luck',
  }
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
  for id, stat in pairs(skillStats) do
    skillsApi[id] = function() return stat end
  end
  for id, stat in pairs(attributeStats) do
    attributesApi[id] = function() return stat end
  end

  -- nearby actors
  local nearbyActors = {}
  for _, entry in ipairs(spec.actors or {}) do
    local object = makeActorObject(entry, entry.store or {})
    nearbyActors[#nearbyActors + 1] = {
      recordId = entry.recordId,
      position = point(entry.position),
      level = entry.level or 1,
      hostile = entry.hostile or false,
      services = entry.services,
      object = object,
      _entry = entry,
    }
  end

  local nearbyContainers = {}
  for _, entry in ipairs(spec.containers or {}) do
    nearbyContainers[#nearbyContainers + 1] = {
      recordId = entry.recordId,
      position = point(entry.position),
      object = makeActorObject(entry, entry.store or {}),
    }
  end

  local createdObjects = {}
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
    create = function(layout)
      local element = { layout = layout, updates = 0, destroyed = false }
      function element:update() self.updates = self.updates + 1 end
      function element:destroy() self.destroyed = true end
      createdElements[#createdElements + 1] = element
      return element
    end,
  }

  local types = {
    Actor = {
      stats = {
        dynamic = {
          health = function() return pools.health end,
          magicka = function() return pools.magicka end,
          fatigue = function() return pools.fatigue end,
        },
        level = function() return levelStat end,
      },
      inventory = function() return inventory end,
      record = function() return { capacity = spec.capacity or 400 } end,
      getEquipment = function()
        local out = {}
        for id, entry in pairs(inventory._store) do
          if entry.equipped and entry.count > 0 then out[#out + 1] = { recordId = id } end
        end
        return out
      end,
      getCapacity = function() return spec.capacity or 400 end,
    },
    NPC = {
      record = function() return { class = spec.classId or 'warrior' } end,
      classes = {
        record = function(classId)
          local preset = classPriorities.presets[classId]
          if preset then
            return {
              id = preset.id,
              name = preset.name,
              specialization = preset.specialization,
              majorSkills = preset.majorSkills,
              minorSkills = preset.minorSkills,
              attributes = preset.favoredAttributes,
            }
          end
          return spec.classRecord
        end,
      },
      stats = { skills = skillsApi, attributes = attributesApi },
    },
    Player = {},
    Item = {},
  }

  local world = {
    players = { actor },
    activeActors = { actor },
    createObject = function(recordId, count)
      local object = makeActorObject({ recordId = recordId, count = count }, {})
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

  local nearby = {
    actors = nearbyActors,
    containers = nearbyContainers,
    doors = {},
    activators = {},
    items = {},
    FIND_PATH_STATUS = { Success = 1, Failed = 0, InProgress = 2 },
  }

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
      sendGlobalEvent = function() end,
    },
    storage = {
      playerSection = function() return { get = function() end, set = function() end } end,
      globalSection = function() return { get = function() end, set = function() end } end,
    },
    async = {
      registerTimerCallback = function() return function() end end,
      newSimulationTimer = function() return { cancel = function() end } end,
      newGameTimer = function() return { cancel = function() end } end,
      newRealTimeTimer = function() return { cancel = function() end } end,
      callback = function(fn) return fn end,
    },
    interfaces = {
      AI = { startPackage = function() end },
      Controls = { overrideMovementControls = function() end, overrideCombatControls = function() end },
      UI = { MODE = {}, setMode = function() end, getMode = function() end },
      -- Morrowind-themed UI templates, as provided by the built-in MWUI interface
      MWUI = {
        templates = {
          boxTransparentThick = { name = 'boxTransparentThick' },
          boxTransparent = { name = 'boxTransparent' },
          textNormal = { name = 'textNormal' },
          textHeader = { name = 'textHeader' },
        },
      },
    },
    input = {},
    ui = uiMock,
    -- pluggable hooks
    servicesOf = spec.servicesOf or function(candidate) return candidate.services end,
    isHostile = spec.isHostile or function(candidate) return candidate.hostile == true end,
    _createdObjects = createdObjects,
    _createdElements = createdElements,
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
  }  for name, value in pairs(modules) do
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
--- @param step distance between waypoints
--- @param failAt when true, findPath always fails
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
