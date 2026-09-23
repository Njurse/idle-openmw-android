-- scripts/idle/settlement.lua
-- "Are we in a town?" -- and "have we just arrived?"
--
-- This is what makes "notify me when they reach a settlement" possible, and what
-- lets the director switch into a settled stance and roam locally instead of
-- wandering off across the map.
--
-- PURE: it takes a plain cell description, so every rule is unit-testable.
--
-- THE HEURISTIC, and its limits
-- ----------------------------
-- OpenMW does not expose a "this cell is a town" flag, so this is inferred:
--
--   1. an interior cell is 'interior' (shops and homes live here, so the settled
--      stance still allows them -- it only stops *long-range* wandering)
--   2. an exterior cell whose name looks like a region is wilderness
--      ("Ascadian Isles Region", "Bitter Coast Region")
--   3. **any other named exterior cell is a settlement** -- Morrowind names town
--      cells plainly ("Balmora", "Seyda Neen") and leaves wilderness unnamed or
--      region-named. This is the load-bearing assumption.
--   4. failing all that, a crowd of friendly people nearby means a settlement
--
-- (3) is the part most likely to be wrong on some obscure cell, which is why
-- `settlement.wildernessNames` exists to correct it by hand without code changes.

local util = require('scripts.idle.util')

local M = {}

M.KIND = {
  settlement = 'settlement',
  wilderness = 'wilderness',
  interior = 'interior',
}

--- Region-style names: Morrowind's outdoor wilderness regions are all "* Region".
M.REGION_SUFFIX = 'Region'

--- Names that should never count as a settlement, whatever else says so.
M.DEFAULT_WILDERNESS_NAMES = {}

--- Is this the name of a wilderness region rather than a place?
function M.isRegion(name)
  if type(name) ~= 'string' then return false end
  return name:find(M.REGION_SUFFIX, 1, true) ~= nil
end

--- Trim and normalise a cell name.
function M.name(cell)
  local name = util.isObject(cell) and cell.name or nil
  if type(name) ~= 'string' then return nil end
  name = name:gsub('^%s+', ''):gsub('%s+$', '')
  if name == '' then return nil end
  return name
end

local function inList(list, value)
  if type(list) ~= 'table' or value == nil then return false end
  for _, item in ipairs(list) do
    if item == value then return true end
  end
  return false
end

--- Classify one cell.
--- @param cell { name?, isExterior? }
--- @param ctx  { cfg?, friendlyNearby? }
--- @return 'settlement' | 'wilderness' | 'interior'
function M.classify(cell, ctx)
  cell = cell or {}
  local cfg = (ctx and ctx.cfg) or {}
  local settings = cfg.settlement or {}

  if cell.isExterior == false then return M.KIND.interior end

  local name = M.name(cell)
  if name then
    if inList(settings.wildernessNames or M.DEFAULT_WILDERNESS_NAMES, name) then
      return M.KIND.wilderness
    end
    if not M.isRegion(name) then
      return M.KIND.settlement
    end
  end

  -- unnamed or region-named: a crowd of friendly people still means a town
  local crowd = (ctx and ctx.friendlyNearby) or 0
  if crowd >= (settings.crowdThreshold or 3) then
    return M.KIND.settlement
  end
  return M.KIND.wilderness
end

function M.isSettlement(cell, ctx)
  return M.classify(cell, ctx) == M.KIND.settlement
end

--- The display name for a settlement, for notifications.
function M.displayName(cell)
  return M.name(cell) or 'a settlement'
end

--- Have we just *arrived* somewhere we should tell the player about?
---
--- Arrival means: now in a settlement, and we were not already in that settlement.
--- Walking from a Balmora street into a Balmora shop is not an arrival.
---
--- @return boolean arrived, string|nil name
function M.arrived(previous, current, ctx)
  if not M.isSettlement(current, ctx) then return false, nil end
  local name = M.displayName(current)

  if util.isObject(previous) then
    local previousName = M.name(previous)
    local previousKind = M.classify(previous, ctx)
    -- same town, or moving between interiors inside it
    if previousKind == M.KIND.settlement and previousName == M.name(current) then
      return false, nil
    end
    if previousKind == M.KIND.interior
       and (current.isExterior == false or previousName == M.name(current)) then
      return false, nil
    end
  end

  return true, name
end

--- In which settlement are we? nil when not in one (used to scope roaming).
function M.current(cell, ctx)
  if not M.isSettlement(cell, ctx) then return nil end
  return M.displayName(cell)
end

return M
