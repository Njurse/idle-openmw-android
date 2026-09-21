-- tests/fixtures/worlds.lua
-- World snapshots (what the observer sees around the player).
local util = require('scripts.idle.util')

local M = {}

local function world(over)
  local base = {
    opportunities = {
      shop = 0, trainer = 0, healing = 0, rest = 0,
      talk = 0, quest = 0, loot = 0, unexplored = 0,
    },
    enemies = 0,
    danger = 0,
    junkValue = 0,
    freeCapacity = 100,
    nearest = {},
  }
  return util.merge(base, over or {})
end

--- Nothing interesting at all.
function M.empty() return world() end

--- A settlement: shops, a trainer, people, somewhere to sleep.
function M.town()
  return world({
    opportunities = { shop = 1, trainer = 1, healing = 1, rest = 1, talk = 1, quest = 0.2, unexplored = 0.2 },
    nearest = {
      shop = { name = 'Arrille', position = { x = 10, y = 0, z = 0 }, distance = 10 },
      trainer = { name = 'Trainer', position = { x = 20, y = 0, z = 0 }, distance = 20 },
      rest = { name = 'Bed', position = { x = 30, y = 0, z = 0 }, distance = 30 },
    },
  })
end

--- Wilds: mostly unexplored, a lone weak creature.
function M.wilderness()
  return world({
    opportunities = { unexplored = 0.9, rest = 0.5, loot = 0.6 },
    enemies = 1,
    danger = 0.15,
    nearest = { enemy = { name = 'Rat', position = { x = 60, y = 0, z = 0 }, distance = 60 } },
  })
end

--- A serious fight you should not pick.
function M.dangerous()
  return world({
    opportunities = { rest = 0.2, unexplored = 0.3 },
    enemies = 4,
    danger = 0.85,
    nearest = { enemy = { name = 'Dremora', position = { x = 40, y = 0, z = 0 }, distance = 40 } },
  })
end

--- At a merchant with a bag full of junk.
function M.merchantTrip()
  return world({
    opportunities = { shop = 1, talk = 0.5 },
    junkValue = 400,
    freeCapacity = 5,
    nearest = { shop = { name = 'Pawnbroker', position = { x = 5, y = 0, z = 0 }, distance = 5 } },
  })
end

--- Only one thing is available -- handy for isolating a single goal.
function M.withOnly(key, extra)
  local opps = { shop = 0, trainer = 0, healing = 0, rest = 0, talk = 0, quest = 0, loot = 0, unexplored = 0 }
  opps[key] = 1
  local over = { opportunities = opps }
  for k, v in pairs(extra or {}) do over[k] = v end
  return world(over)
end

return M
