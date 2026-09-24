-- scripts/idle/entity.lua
-- Normalising engine readings into schema entities.
--
-- WHY
-- ---
-- Every read path used to hand-build its own table: `bridgeSources()` had one shape for
-- `player`, another for `entities.nearby`, and `ui.target` a third. Anything a host consumed
-- therefore depended on which method it called. This module is the single place where a raw
-- reading becomes a schema entity, so all of them agree by construction.
--
-- It also enforces the two rules that matter for a wire format:
--   * a field the schema does not declare is DROPPED (and can be reported), because shipping
--     it would either be invisible drift or break the app's parser;
--   * `nil` is dropped rather than defaulted, so "unknown" stays distinguishable from "zero".
--
-- PURE. The runtime (scripts/runtime/entities.lua) does the engine calls and passes plain
-- readings in.

local schema = require('scripts.idle.schema')
local util = require('scripts.idle.util')

local M = {}

--- Build one entity of `kind`.
---
--- `:set` is the whole point: it refuses fields the schema does not declare, so a typo like
--- `postition` produces a recorded problem instead of a field that silently reaches the app.
function M.new(kind)
  local definition = schema.KINDS[kind]
  local entity = { kind = kind }
  local dropped = {}
  local lookup = {}
  for _, entry in ipairs(definition and definition.fields or {}) do lookup[entry.name] = true end

  local builder = {}

  --- @return boolean accepted
  function builder:set(name, value)
    if name == 'kind' then
      -- the builder owns the kind: it decided it from the engine type, and a reading that
      -- claims otherwise would let a caller reinterpret the entity silently
      if value ~= nil and value ~= kind then dropped[#dropped + 1] = 'kind' end
      return false
    end
    if not lookup[name] then
      dropped[#dropped + 1] = name
      return false
    end
    entity[name] = value
    return true
  end

  --- Set from a table of readings, ignoring anything nil.
  function builder:fill(readings)
    if type(readings) ~= 'table' then return builder end
    for name, value in pairs(readings) do
      if value ~= nil then builder:set(name, value) end
    end
    return builder
  end

  function builder:get() return entity end

  --- Fields that were refused because the schema does not declare them. The runtime logs
  --- these: a dropped field is either a typo or a schema gap, and both are worth knowing.
  function builder:dropped() return dropped end

  return builder
end

--- Remove nil values in place (and return the entity). Keys are left in place otherwise:
--- an empty list stays an empty list, because "there are none" is a fact we can state, while
--- a missing field means "not known".
function M.compact(entity)
  for name, value in pairs(entity) do
    if value == nil then entity[name] = nil end
  end
  return entity
end

--- Distance and height relationship from one position to another, in engine units.
--- Both results stay nil when either side is unknown -- guessing zero would claim the player
--- is standing on it.
--- Read x/y/z off a position, or nil when it is not a usable position.
--- ALL THREE components are required, on both sides: a partial position used to yield NaN, and
--- sqrt of NaN is not nil -- it is a number that means nothing, which is worse than absent.
--- pcall because a userdata without __index THROWS on field access, and a frame update is not
--- allowed to die because something handed us a position-shaped object it could not read.
--- Positions are Vector3 USERDATA on the engine; a table-only guard here made every entity's
--- placement silently unset. See AGENTS.md #7.
local function components(position)
  if not util.isObject(position) then return nil end
  local ok, x, y, z = pcall(function() return position.x, position.y, position.z end)
  if not ok then return nil end
  if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
  return x, y, z
end

function M.derivePlacement(entity, fromPosition)
  local tx, ty, tz = components(entity.position)
  local fx, fy, fz = components(fromPosition)
  if not tx or not fx then return entity end
  local dx, dy, dz = tx - fx, ty - fy, tz - fz
  entity.distance = math.floor(math.sqrt(dx * dx + dy * dy + dz * dz) + 0.5)
  entity.vertical = M.vertical(tz, fz)
  return entity
end

--- 'above' | 'below' | 'level' relative to a reference height.
---
--- Mordor: Morrowind hides things above and below you, and "look up" is real advice -- the
--- hatch on the prison ship is overhead. Anything within 60 units counts as level.
function M.vertical(z, referenceZ)
  if type(z) ~= 'number' or type(referenceZ) ~= 'number' then return nil end
  local delta = z - referenceZ
  if delta > 60 then return 'above' end
  if delta < -60 then return 'below' end
  return 'level'
end

--- A deterministic inventory order: by name, then recordId, then the engine id. Two identical
--- inventories must serialise identically, or a host cannot diff a response to see change.
function M.sortStacks(stacks)
  local out = {}
  if type(stacks) ~= 'table' then return out end
  for _, stack in ipairs(stacks) do out[#out + 1] = stack end
  table.sort(out, function(a, b)
    local an, bn = tostring(a.name or ''), tostring(b.name or '')
    if an ~= bn then return an < bn end
    local ar, br = tostring(a.recordId or ''), tostring(b.recordId or '')
    if ar ~= br then return ar < br end
    return tostring(a.id or '') < tostring(b.id or '')
  end)
  return out
end

--- Total item count in a list of stacks, for a quick "how much is in there" answer.
function M.totalCount(stacks)
  local total = 0
  if type(stacks) ~= 'table' then return total end
  for _, stack in ipairs(stacks) do
    if type(stack.count) == 'number' then total = total + stack.count end
  end
  return total
end

--- Finish an entity: drop nils and report schema problems.
--- @return table entity, table|nil problems
function M.finish(entity)
  M.compact(entity)
  local ok, problems = schema.validate(entity.kind, entity)
  if ok then return entity, nil end
  return entity, problems
end

--- Which kind is this engine object? The runtime passes the flags it could read; the order is
--- the schema's precedence, so a talking container is an actor and a door-activator is a door.
M.KIND_ORDER = { 'actors', 'doors', 'containers', 'items', 'activators' }
M.KIND_FOR_LIST = {
  actors = 'npc',       -- refined to player/creature by the runtime when it can tell
  doors = 'door',
  containers = 'container',
  items = 'item',
  activators = 'activator',
}

--- Pick the kind for a list name, honouring the precedence in M.KIND_ORDER.
--- @param flags table e.g. { actors = true, containers = true }
function M.kindFor(flags)
  if type(flags) ~= 'table' then return nil end
  for _, listName in ipairs(M.KIND_ORDER) do
    if flags[listName] == true then return M.KIND_FOR_LIST[listName] end
  end
  return nil
end

return M
