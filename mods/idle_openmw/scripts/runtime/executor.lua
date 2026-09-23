-- scripts/runtime/executor.lua
-- Turns the director's command batch into engine calls and keeps movement going.
--
-- The engine surface is injected as `env`, so this module is unit-tested against
-- tests/mocks/openmw.lua.
--
-- WHAT THE ENGINE LETS US DO (verified, docs/openmw-lua-api.md §§2,4,5)
--   * move the player            -> self.controls (movement/yawChange/run)
--   * interact with an object    -> GameObject:activateBy(actor)
--   * move items/gold around     -> inventory:find(id):remove(n) and
--                                   world.createObject(id, n):moveInto(inv)
--   * change pools / skill stats -> types.Actor.stats.* / types.NPC.stats.*
-- It does NOT let us drive the barter/rest/training/dialogue UI. So barter and
-- rest are performed directly, gated behind `behaviour.simulateActions`; with
-- that off the mod only navigates and opens the relevant UI.

local util = require('scripts.idle.util')
local rngMod = require('scripts.idle.rng')
local pathfinder = require('scripts.idle.pathfinder')
local equipment = require('scripts.idle.equipment')

local M = {}

local function num(value, fallback)
  if type(value) == 'number' then return value end
  return fallback
end

local function safe(fn, ...)
  if type(fn) ~= 'function' then return nil end
  local ok, a = pcall(fn, ...)
  if ok then return a end
  return nil
end

local BLOCKING = { move = true, flee = true }

local Executor = {}
Executor.__index = Executor

--- @param env engine facade (scripts/runtime/engine.lua:env)
--- @param cfg validated config
--- @param opts { nav?, rng?, onLog? }
function M.new(env, cfg, opts)
  opts = opts or {}
  local executor = setmetatable({
    env = env,
    cfg = cfg,
    rng = opts.rng or rngMod.new(cfg.debug.seed),
    onLog = opts.onLog,
    queue = {},
    actions = {},
    applied = { sales = 0, purchases = 0, goldEarned = 0, goldSpent = 0, rests = 0, trains = 0,
                equips = 0, drops = 0 },
    route = nil,
  }, Executor)
  if opts.nav then executor.route = pathfinder.newRoute(opts.nav, cfg) end
  return executor
end

function Executor:log(message, level)
  local entry = { message = message, level = level or 'info' }
  self.actions[#self.actions + 1] = entry
  if self.onLog then self.onLog(message, level) end
  return entry
end

function Executor:pending() return #self.queue end
function Executor:peek() return self.queue[1] end
function Executor:isMoving() return self.route ~= nil and self.route:isActive() end

--- Replace the pending queue with a fresh batch.
function Executor:submit(commands)
  self.queue = {}
  for _, command in ipairs(commands or {}) do self.queue[#self.queue + 1] = command end
  return self
end

function Executor:pop() table.remove(self.queue, 1) end

function Executor:clear()
  self.queue = {}
  if self.route then self.route:clear() end
  self:_releaseControls()
end

-- ---------------------------------------------------------------------------
-- engine primitives
-- ---------------------------------------------------------------------------

function Executor:_player() return self.env.self and self.env.self.object end
function Executor:_controls() return self.env.self and self.env.self.controls end

function Executor:_inventory(actor)
  return safe(self.env.types and self.env.types.Actor and self.env.types.Actor.inventory, actor or self:_player())
end

function Executor:_releaseControls()
  local controls = self:_controls()
  if not controls then return end
  controls.movement = 0
  controls.sideMovement = 0
  controls.yawChange = 0
  controls.pitchChange = 0
  controls.run = false
  controls.jump = false
end

function Executor:_steer(position, waypoint, yaw)
  local controls = self:_controls()
  if not controls then return end
  local solution = pathfinder.steering(position, waypoint, yaw, {
    arriveTolerance = self.cfg.behaviour.arriveTolerance,
  })
  controls.yawChange = solution.yawChange
  controls.movement = solution.shouldMove and 1 or 0
  controls.run = solution.shouldMove
end

function Executor:_removeItems(recordId, count)
  local inventory = self:_inventory()
  if type(inventory) ~= 'table' then return 0 end
  local object = safe(function() return inventory.find and inventory:find(recordId) end)
  if type(object) ~= 'table' or type(object.remove) ~= 'function' then return 0 end
  local ok = pcall(function() object:remove(count) end)
  return ok and count or 0
end

function Executor:_addGold(amount)
  if amount <= 0 then return 0 end
  local world = self.env.world
  local money = safe(world and world.createObject, 'gold_001', amount)
  if type(money) ~= 'table' then return 0 end
  local inventory = self:_inventory()
  if type(inventory) ~= 'table' then return 0 end
  pcall(function() money:moveInto(inventory) end)
  return amount
end

function Executor:_spendGold(amount)
  return self:_removeItems('gold_001', amount)
end

function Executor:_giveItem(recordId, count)
  local world = self.env.world
  local object = safe(world and world.createObject, recordId, count)
  local inventory = self:_inventory()
  if type(object) ~= 'table' or type(inventory) ~= 'table' then return 0 end
  pcall(function() object:moveInto(inventory) end)
  return count
end

function Executor:_restorePool(kind)
  local actor = self:_player()
  local dynamic = self.env.types and self.env.types.Actor and self.env.types.Actor.stats
    and self.env.types.Actor.stats.dynamic
  local stat = safe(dynamic and dynamic[kind], actor)
  if util.isObject(stat) and type(stat.base) == 'number' then
    stat.current = stat.base
    return true
  end
  return false
end

-- ---------------------------------------------------------------------------
-- command execution
-- ---------------------------------------------------------------------------

--- Equip an item in the right slot, using the pure type->slot mapping.
--- Returns ok, message. Falls back to "use the inventory window" for tools and
--- anything whose slot cannot be determined (see scripts/idle/equipment.lua).
function Executor:equip(recordId)
  local types = self.env.types
  local actor = self:_player()
  local inventory = self:_inventory()
  local object = inventory and inventory.find and safe(function() return inventory:find(recordId) end)
  if type(object) ~= 'table' then return false, ('%s is not carried'):format(tostring(recordId)) end

  local record = safe(object.type and object.type.record, object) or {}
  local resolved = equipment.resolve(object.type, record, types)
  if not resolved.slot then
    return false, ('%s is not something we can equip — use the inventory window'):format(tostring(recordId))
  end

  local slots = types and types.Actor and types.Actor.EQUIPMENT_SLOT
  local slotValue = slots and slots[resolved.slot]
  if type(slotValue) ~= 'number' then
    return false, ('unknown equipment slot %s'):format(tostring(resolved.slot))
  end

  -- setEquipment may only be used on self, which is exactly what a PLAYER script has
  local ok = pcall(function() types.Actor.setEquipment(actor, { [slotValue] = object }) end)
  if not ok then return false, ('the engine refused to equip %s'):format(tostring(recordId)) end

  self.applied.equips = (self.applied.equips or 0) + 1
  self:log(('Equipped %s (%s)'):format(tostring(recordId), resolved.slot), 'good')
  return true
end

--- Sell a single stack at the simulated barter price.
function Executor:sellOne(recordId, count)
  if self.cfg.behaviour.simulateActions == false then
    self:log('Barter UI needed to sell', 'warn')
    return 0
  end
  local inventory = self:_inventory()
  local object = inventory and inventory.find and safe(function() return inventory:find(recordId) end)
  if type(object) ~= 'table' then return 0 end

  local record = safe(object.type and object.type.record, object) or {}
  local available = num(object.count, 1)
  count = math.min(count or available, available)
  if count <= 0 then return 0 end

  local removed = self:_removeItems(recordId, count)
  if removed == 0 then return 0 end

  local gold = math.floor(count * num(record.value, 0) * (self.cfg.behaviour.barterRatio or 0.8))
  self:_addGold(gold)
  self.applied.sales = self.applied.sales + 1
  self.applied.goldEarned = self.applied.goldEarned + gold
  self:log(('Sold %s x%d for %s gold'):format(tostring(recordId), count, util.formatNumber(gold)), 'good')
  return gold
end

--- Drop a stack of items into the world.
function Executor:dropOne(recordId, count)
  local inventory = self:_inventory()
  local object = inventory and inventory.find and safe(function() return inventory:find(recordId) end)
  if type(object) ~= 'table' or type(object.remove) ~= 'function' then return false end
  local ok = pcall(function() object:remove(count or 1) end)
  if ok then
    self.applied.drops = (self.applied.drops or 0) + 1
    self:log(('Dropped %s x%d'):format(tostring(recordId), count or 1), 'info')
  end
  return ok
end

--- Execute a one-shot command. May return a replacement command (wander).
function Executor:_execute(command, now)
  local simulating = self.cfg.behaviour.simulateActions ~= false

  if command.type == 'stop' then
    self:_releaseControls()
    self:log('Idling')

  elseif command.type == 'activate' then
    local target = command.target
    local object = util.isObject(target) and target.object or nil
    local actor = self:_player()
    if util.isObject(object) and type(object.activateBy) == 'function' and actor then
      pcall(function() object:activateBy(actor) end)
      self:log(('Approaching %s'):format(command.kind or 'target'), 'info')
    else
      self:log(('Nothing to %s here'):format(command.kind or 'interact with'), 'warn')
    end

  elseif command.type == 'sell' then
    self:_sell(command)

  elseif command.type == 'buy' then
    self:_buy(command)

  elseif command.type == 'rest' then
    if simulating and self:_restorePool('fatigue') then
      self:_restorePool('health')
      self:_restorePool('magicka')
      self.applied.rests = self.applied.rests + 1
      self:log(('Rested %d hours'):format(command.hours or 0), 'good')
    else
      self:log('Need to rest (open the rest menu)', 'warn')
    end

  elseif command.type == 'useItem' then
    if simulating and self:_restorePool(command.tag == 'magicka' and 'magicka'
        or command.tag == 'fatigue' and 'fatigue' or 'health') then
      self:log('Used a restorative', 'good')
    else
      self:log(('No %s item available'):format(command.tag or 'usable'), 'warn')
    end

  elseif command.type == 'train' then
    if simulating and command.skill then
      local actor = self:_player()
      local stats = self.env.types and self.env.types.NPC and self.env.types.NPC.stats
        and self.env.types.NPC.stats.skills
      local stat = safe(stats and stats[command.skill], actor)
      if util.isObject(stat) then
        stat.progress = math.min(1, (stat.progress or 0) + 0.2)
        local cost = (self.cfg.behaviour.trainGoldPerLevel or 0) * (self.applied.level or 1)
        if cost > 0 then self:_spendGold(cost) end
        self.applied.trains = self.applied.trains + 1
        self:log(('Trained %s'):format(command.skill), 'good')
      else
        self:log(('Cannot train %s'):format(command.skill), 'warn')
      end
    else
      self:log(('Training %s needs a trainer (open the training menu)'):format(tostring(command.skill)), 'warn')
    end

  elseif command.type == 'wander' then
    local position = self.env.self and self.env.self.position
    if position then
      local radius = command.radius or 1500
      local angle = self.rng:float01() * util.TAU
      local distance = self.rng:uniform(radius * 0.5, radius)
      return {
        type = 'move',
        dest = {
          x = (position.x or 0) + math.cos(angle) * distance,
          y = (position.y or 0) + math.sin(angle) * distance,
          z = position.z or 0,
        },
        run = false,
        wander = true,
      }
    end
  end

  return nil
end

function Executor:_sell(command)
  local plan = command.plan or {}
  if self.cfg.behaviour.simulateActions == false then
    self:log('Barter UI needed to sell', 'warn')
    return
  end
  local ratio = self.cfg.behaviour.barterRatio or 0.8
  local gold = 0
  for _, entry in ipairs(plan) do
    local removed = self:_removeItems(entry.id, entry.count or 1)
    if removed > 0 then
      gold = gold + math.floor(removed * (entry.unitValue or 0) * ratio)
    end
  end
  if gold > 0 then
    self:_addGold(gold)
    self.applied.sales = self.applied.sales + 1
    self.applied.goldEarned = self.applied.goldEarned + gold
    self:log(('Sold junk for %s gold'):format(util.formatNumber(gold)), 'good')
  else
    self:log('Nothing worth selling', 'info')
  end
end

function Executor:_buy(command)
  local plan = command.plan or {}
  if self.cfg.behaviour.simulateActions == false then
    self:log('Barter UI needed to buy', 'warn')
    return
  end
  local bought = 0
  local spent = 0
  for _, entry in ipairs(plan) do
    local cost = (entry.unitValue or 0) * (entry.count or 1)
    if cost > 0 and self:_spendGold(cost) > 0 then
      self:_giveItem(entry.id, entry.count or 1)
      bought = bought + 1
      spent = spent + cost
    end
  end
  if bought > 0 then
    self.applied.purchases = self.applied.purchases + 1
    self.applied.goldSpent = self.applied.goldSpent + spent
    self:log(('Bought %d kinds of supplies for %s gold'):format(bought, util.formatNumber(spent)), 'good')
  end
end

-- ---------------------------------------------------------------------------
-- the update loop
-- ---------------------------------------------------------------------------

function Executor:_startMove(command, now)
  if not self.route or not command.dest then return false end
  local self_ = self.env.self
  if not self_ then return false end
  self.route:setTarget(command.dest, { arriveTolerance = command.arrive })
  local status = self.route:update(self_.position or { x = 0, y = 0, z = 0 }, now)
  if status.status == 'moving' then return true end
  -- do not leave a dead route lingering, or isMoving() would lie
  self.route:clear()
  return false
end

--- Open a door we are about to walk into.
---
--- `nearby.findPath` ROUTES THROUGH doors -- `includeFlags` already defaults to
--- `Walk + Swim + OpenDoor + UsePathgrid` (files/lua_api/openmw/nearby.lua:180-182) -- but the
--- actor still has to OPEN them. Without this the actor walks into a closed door and only the
--- stuck timer eventually gives up, which is why "leave the shop" could never work. The
--- decision (which door, in front, near enough) is pure (scripts/idle/pathfinder.lua:doorAhead);
--- this is the engine half, and it is bounded to one door per call.
function Executor:_openDoorsAhead()
  local nearby = self.env.nearby
  local doors = nearby and nearby.doors
  local self_ = self.env.self
  if not doors or not self_ then return nil end

  local list = {}
  pcall(function()
    for _, door in ipairs(doors) do
      list[#list + 1] = { position = door.position, object = door, id = door.id }
    end
  end)
  if #list == 0 then return nil end

  local door = pathfinder.doorAhead(
    self_.position or { x = 0, y = 0, z = 0 },
    self_.rotation or 0,
    list,
    { radius = self.cfg.behaviour.doorOpenRadius or 128 })
  if not door then return nil end

  local object = door.object
  local actor = self:_player()
  if util.isObject(object) and type(object.activateBy) == 'function' and actor then
    pcall(function() object:activateBy(actor) end)
    self:log('Opened a door in the way', 'info')
    return door.id
  end
  return nil
end

--- Advance movement for this frame (keeps the player walking between decisions).
function Executor:step(dt, now)
  if not self.route or not self.route:isActive() then return end
  local self_ = self.env.self
  if not self_ then return end
  local status = self.route:update(self_.position or { x = 0, y = 0, z = 0 }, now or 0)

  if status.status == 'moving' then
    self:_steer(self_.position or { x = 0, y = 0, z = 0 }, status.waypoint, self_.rotation or 0)
    self:_openDoorsAhead()
  elseif status.status == 'arrived' then
    self:_releaseControls()
    self:pop()
  elseif status.status == 'short' then
    -- the path ran out while still away from the target: the target is unreachable from here.
    -- Report the gap instead of pretending we arrived.
    self:_releaseControls()
    self:log(('Could not reach the destination (stopped %d short)')
      :format(math.floor(status.distance or 0)), 'warn')
    self:pop()
  elseif status.status == 'failed' or status.status == 'stuck' then
    self:_releaseControls()
    self:log(('Could not reach the destination (%s)'):format(status.status), 'warn')
    self:pop()
  end
end

--- Run the queue, then steer along whatever route is now active.
function Executor:update(dt, now)
  now = now or 0

  -- 1. drain the queue while nothing is blocking on movement
  if not (self.route and self.route:isActive()) then
    local guard = 0
    while #self.queue > 0 and guard < 32 do
      guard = guard + 1
      local command = self.queue[1]

      if BLOCKING[command.type] then
        self:pop()
        if self:_startMove(command, now) then break end
        self:log(('No route to %s'):format(command.type), 'warn')
      else
        local replacement = self:_execute(command, now)
        self:pop()
        if replacement then table.insert(self.queue, 1, replacement) end
      end
    end
  end

  -- 2. keep the player walking (and detect arrival) every frame
  self:step(dt, now)
  return self
end

M.Executor = Executor

return M
