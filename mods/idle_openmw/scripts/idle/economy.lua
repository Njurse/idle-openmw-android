-- scripts/idle/economy.lua
-- Valuation and buy/sell planning. Pure: no engine, no I/O.
--
-- An "item" here is a plain table:
--   { id = 'iron dagger', count = 3, value = 8, weight = 6, equipped = false, quest = false }
-- where `value` and `weight` are PER UNIT.

local util = require('scripts.idle.util')

local M = {}

--- Gold per unit of weight. Weightless items are treated as infinitely good
--- value-per-weight (they cost nothing to carry).
function M.valuePerWeight(item)
  local weight = item.weight or 0
  if weight <= 0 then return math.huge end
  return (item.value or 0) / weight
end

function M.totalValue(item) return (item.value or 0) * (item.count or 1) end
function M.totalWeight(item) return (item.weight or 0) * (item.count or 1) end

--- Should this item be sold as junk?
--- Never equipped or quest items; otherwise driven by value-per-weight, plus a
--- bulk rule for big stacks of merely-mediocre loot.
function M.isJunk(item, cfg)
  if item.quest or item.equipped then return false end
  local ratio = M.valuePerWeight(item)
  local threshold = cfg.thresholds.junkValuePerWeight
  if ratio < threshold then return true end
  -- a large stack of mediocre items is also worth shedding
  if (item.count or 1) > (cfg.thresholds.keepItemCount or 1) * 5 and ratio < threshold * 2 then
    return true
  end
  return false
end

--- Total gross value of everything that is junk.
function M.junkValue(inventory, cfg)
  local total = 0
  for _, item in ipairs(inventory or {}) do
    if M.isJunk(item, cfg) then total = total + M.totalValue(item) end
  end
  return total
end

--- Junk items, richest first.
function M.junkItems(inventory, cfg)
  local junk = {}
  for _, item in ipairs(inventory or {}) do
    if M.isJunk(item, cfg) then junk[#junk + 1] = item end
  end
  table.sort(junk, function(a, b)
    local av, bv = M.totalValue(a), M.totalValue(b)
    if av == bv then return tostring(a.id) < tostring(b.id) end
    return av > bv
  end)
  return junk
end

--- An ordered sell plan: { { id, count, unitValue, totalValue }, ... }.
function M.planSales(inventory, cfg)
  local plan = {}
  for _, item in ipairs(M.junkItems(inventory, cfg)) do
    plan[#plan + 1] = {
      id = item.id,
      count = item.count or 1,
      unitValue = item.value or 0,
      totalValue = M.totalValue(item),
    }
  end
  return plan
end

--- Gold the sell plan is expected to raise, honouring a barter discount.
--- `barterRatio` (0..1) models the merchant paying less than book value.
function M.expectedGold(plan, barterRatio)
  barterRatio = util.clamp(barterRatio or 0.8, 0, 1)
  local total = 0
  for _, entry in ipairs(plan or {}) do total = total + entry.totalValue * barterRatio end
  return math.floor(total)
end

--- A shopping plan.
--- @param desired list of { id, count, priority } the character wants
--- @param stock   map id -> { value = <unit price>, count = <available> }
--- @param gold    gold currently held
--- @return list of { id, count, unitValue, totalValue }, goldLeft
function M.planPurchases(desired, stock, gold, cfg)
  stock = stock or {}
  local budget = math.max(0, (gold or 0) - cfg.thresholds.minGoldReserve)
  local sorted = util.copy(desired or {})
  table.sort(sorted, function(a, b)
    local ap, bp = a.priority or 0, b.priority or 0
    if ap == bp then return tostring(a.id) < tostring(b.id) end
    return ap > bp
  end)

  local plan = {}
  for _, want in ipairs(sorted) do
    local entry = stock[want.id]
    if entry and entry.value and entry.value > 0 then
      local affordable = math.floor(budget / entry.value)
      local available = entry.count or 0
      local count = math.min(want.count or 1, available, affordable)
      if count > 0 then
        local cost = count * entry.value
        budget = budget - cost
        plan[#plan + 1] = { id = want.id, count = count, unitValue = entry.value, totalValue = cost }
      end
    end
  end
  return plan, budget + cfg.thresholds.minGoldReserve
end

--- A one-shot summary the director/HUD can use.
function M.summarize(inventory, cfg)
  local sales = M.planSales(inventory, cfg)
  local totalValue, totalWeight, itemCount = 0, 0, 0
  for _, item in ipairs(inventory or {}) do
    totalValue = totalValue + M.totalValue(item)
    totalWeight = totalWeight + M.totalWeight(item)
    itemCount = itemCount + (item.count or 1)
  end
  return {
    itemCount = itemCount,
    totalValue = totalValue,
    totalWeight = totalWeight,
    junkValue = M.junkValue(inventory, cfg),
    junkCount = #sales,
    sales = sales,
  }
end

return M
