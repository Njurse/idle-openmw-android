-- tests/fixtures/panel.lua
-- Console panel snapshots (see scripts/idle/uiModel.lua for the contract).
local util = require('scripts.idle.util')
local configMod = require('scripts.idle.config')

local M = {}

local BASE = {
  status = {
    goal = 'fight',
    reason = '2 hostiles, danger 0.20',
    mode = 'auto',
    level = 5,
    gold = 1240,
    healthFraction = 0.84,
    magickaFraction = 0.60,
    fatigueFraction = 0.71,
    encumbranceFraction = 0.12,
    topGoals = { { id = 'fight', score = 1.204 }, { id = 'rest', score = 0.41 } },
    counters = { ticks = 120, goalChanges = 9, commands = 240 },
    log = {},
  },
  player = {
    gold = 1240,
    level = 5,
    encumbrance = { current = 35, max = 400 },
    position = { x = 0, y = 0, z = 0 },
    cell = { name = 'Balmora', isExterior = true },
  },
  inventory = {
    { id = 'heavy cuirass', count = 1, value = 300, weight = 40, equipped = false,
      junk = true, valuePerWeight = 7.5, equipSlot = 'Cuirass' },
    { id = 'chitin dagger', count = 5, value = 8, weight = 4, equipped = false,
      junk = true, valuePerWeight = 2.0 },
    { id = 'longsword', count = 1, value = 90, weight = 15, equipped = true,
      junk = false, valuePerWeight = 6.0, equipSlot = 'CarriedRight' },
    { id = 'lockpick', count = 12, value = 5, weight = 0.1, equipped = false,
      junk = false, valuePerWeight = 50.0 },
  },
  dialogue = {
    { actor = 'arrille', kind = 'greeting', recordId = 'greet1', time = 100 },
    { actor = 'arrille', kind = 'topic', recordId = 'little secret', time = 130 },
  },
  topics = { { topic = 'little secret', count = 2 }, { topic = 'balmora', count = 1 } },
  journal = { { text = 'You arrived in Balmora.', questId = nil, day = 3 } },
  quests = { { id = 'ms_fargothring', stage = 10, started = true, finished = false } },
  log = {
    { message = 'Walked to the shop', level = 'info', time = 200 },
    { message = 'Sold junk for 32 gold', level = 'good', time = 300 },
  },
  mode = 'auto',
  directive = nil,
  config = configMod.new(),
}

--- Fresh panel snapshot (optionally overridden).
function M.panel(over) return util.merge(BASE, over or {}) end

--- An empty panel: no items, no dialogue, no log.
function M.empty()
  return util.merge(BASE, {
    inventory = {}, dialogue = {}, topics = {}, journal = {}, quests = {}, log = {},
  })
end

return M
