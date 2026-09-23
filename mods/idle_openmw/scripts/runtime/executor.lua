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

--- The player's facing, in radians.
---
--- 0.52 hands `self.rotation` back as a Transform USERDATA, not the angle the older docs
--- describe. Feeding that userdata to the steering maths produced a nonsense yaw that never
--- converged, so `shouldMove` was never true and the character turned on the spot forever while
--- every log said it was moving. `rotation.z` is the yaw; fall back to the camera, then to 0.
--- @return number
--- The player's facing, in radians, from whichever source the engine actually provides.
---
--- 0.52 hands `self.rotation` back as a Transform USERDATA, not the angle the older docs
--- describe, and a Transform's angles live one level deeper. Feeding a non-number to the steering
--- maths produced a yaw that never converged: `shouldMove` stayed false, the character turned on
--- the spot forever through forty seconds of logs claiming `moving = true`, and each candidate
--- source had to be probed rather than assumed. Returns the value AND where it came from, so a
--- host can tell a real reading from a fallback.
--- @return number, string
local function yawOf(selfObject)
  local rotation = nil
  pcall(function() rotation = selfObject and selfObject.rotation end)
  if type(rotation) == 'number' then return rotation, 'self.rotation(number)' end

  -- a Vector3-like: `.z` is the yaw
  local yaw = nil
  pcall(function() yaw = rotation and rotation.z end)
  if type(yaw) == 'number' then return yaw, 'self.rotation.z' end

  -- a Transform: its `rotation` field holds the angles (core.lua:169)
  pcall(function() yaw = rotation and rotation.rotation and rotation.rotation.z end)
  if type(yaw) == 'number' then return yaw, 'self.rotation.rotation.z' end

  -- the camera faces where the character faces in third person, and is always readable
  local camera = nil
  pcall(function() camera = require('openmw.camera') end)
  pcall(function() yaw = camera and camera.getYaw and camera.getYaw() end)
  if type(yaw) == 'number' then return yaw, 'camera.getYaw' end

  return 0, 'nothing readable'
end

function Executor:_steer(position, waypoint, yaw)
  local controls = self:_controls()
  if not controls then return end
  local solution = pathfinder.steering(position, waypoint, yaw, {
    arriveTolerance = self.cfg.behaviour.arriveTolerance,
  })
  -- Remembered so a host can ask WHY nothing is happening: `moving = true` with a zero distance
  -- travelled is either a steering refusal or an override the engine never honoured, and the
  -- two look identical from outside.
  self.lastSteer = {
    yaw = yaw,
    yawSource = self.lastYawSource,
    yawDelta = solution.yawDelta,
    distance = solution.distance,
    shouldMove = solution.shouldMove,
    arrived = solution.arrived,
  }
  controls.yawChange = solution.yawChange
  controls.movement = solution.shouldMove and 1 or 0
  controls.run = solution.shouldMove
end

--- Ask the warden (a GLOBAL script) to move items or gold.
---
--- A PLAYER script CANNOT do this itself, and the reason is structural rather than a bug we can
--- code around: `openmw.world` is declared "for global scripts" (world.lua:3-4), so
--- `world.createObject` is unavailable here, and `GameObject:remove` / `moveInto` are registered
--- ONLY for `GObject` -- "Only for global scripts" (objectbindings.cpp:399-400). An earlier
--- revision called them directly from this player script, so buying, selling, dropping and
--- banking gold SILENTLY DID NOTHING on a real engine while the mock (plain tables) kept the
--- specs green. docs/openmw-lua-api.md 10.1 had already recorded the limitation this code
--- ignored -- the warden exists for exactly this.
---
--- The return value is the REQUESTED count, not a confirmed one: the engine applies global events
--- on the next tick and the warden replies with `IdleOpenMW_EconomyApplied`, which is logged.
function Executor:_requestEconomy(payload)
  local core = self.env.core
  if not (core and type(core.sendGlobalEvent) == 'function') then
    self:log('No global event channel: cannot move items', 'warn')
    return false
  end
  local ok = pcall(core.sendGlobalEvent, 'IdleOpenMW_Economy', payload)
  if not ok then
    self:log('The warden channel refused the economy request', 'warn')
    return false
  end
  self.applied.economyRequests = (self.applied.economyRequests or 0) + 1
  return true
end

function Executor:_removeItems(recordId, count)
  if count <= 0 then return 0 end
  if not self:_requestEconomy({ op = 'take', recordId = tostring(recordId), count = count }) then
    return 0
  end
  return count
end

function Executor:_addGold(amount)
  amount = math.floor(amount or 0)
  if amount <= 0 then return 0 end
  if not self:_requestEconomy({ op = 'gold', amount = amount }) then return 0 end
  return amount
end

function Executor:_spendGold(amount)
  return self:_removeItems('gold_001', amount)
end

function Executor:_giveItem(recordId, count)
  count = math.floor(count or 0)
  if count <= 0 then return 0 end
  if not self:_requestEconomy({ op = 'give', recordId = tostring(recordId), count = count }) then
    return 0
  end
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
  if not util.isObject(object) then return false, ('%s is not carried'):format(tostring(recordId)) end

  local record = safe(object.type and object.type.record, object) or {}
  local resolved = equipment.resolve(object.type, record, types)
  if not resolved.slot then
    return false, ('%s is not something we can equip - use the inventory window'):format(tostring(recordId))
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
  if not util.isObject(object) then return 0 end

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
---
--- The item is LOCATED here (Inventory:find is available to a player script) but REMOVED through
--- the warden: `GameObject:remove` is global-only (objectbindings.cpp:399-400).
function Executor:dropOne(recordId, count)
  local inventory = self:_inventory()
  local object = inventory and inventory.find and safe(function() return inventory:find(recordId) end)
  if not util.isObject(object) then return false end
  local available = num(object.count, 1)
  count = math.min(count or available, available)
  if count <= 0 then return false end
  if self:_removeItems(recordId, count) == 0 then return false end
  self.applied.drops = (self.applied.drops or 0) + 1
  self:log(('Dropped %s x%d'):format(tostring(recordId), count), 'info')
  return true
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

--- Start walking. Returns `true`, or `false` AND WHY.
---
--- The reason matters: "No route to move" is the same text for a missing destination, a missing
--- self object and a path the navmesh could not build, and those need three different fixes.
--- @return boolean, string|nil
function Executor:_startMove(command, now)
  if not self.route then return false, 'no route object' end
  if not command.dest then return false, 'the command has no destination' end
  local self_ = self.env.self
  if not self_ then return false, 'no openmw.self in the environment' end
  self.route:setTarget(command.dest, { arriveTolerance = command.arrive })
  local here = self_.position or { x = 0, y = 0, z = 0 }
  local status = self.route:update(here, now)
  if status.status == 'moving' then return true end
  -- do not leave a dead route lingering, or isMoving() would lie
  self.route:clear()
  -- Carry the NUMBERS. "arrived" while standing thousands of units away is only possible if the
  -- destination we were handed is not where we think it is, and that is invisible otherwise.
  local function at(point)
    if not point then return 'nil' end
    return ('%.0f,%.0f,%.0f'):format(point.x or 0, point.y or 0, point.z or 0)
  end
  return false, ('%s (dest %s, here %s, gap %s)'):format(
    tostring(status.status), at(command.dest), at(here),
    tostring(util.distance(here, command.dest)))
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
    local yaw, yawSource = yawOf(self_)
    self.lastYawSource = yawSource
    self:_steer(self_.position or { x = 0, y = 0, z = 0 }, status.waypoint, yaw)
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
        local started, why = self:_startMove(command, now)
        if started then break end
        self:log(('No route to %s (%s)'):format(command.type, why or 'unknown'), 'warn')
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
