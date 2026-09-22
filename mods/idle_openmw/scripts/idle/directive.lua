-- scripts/idle/directive.lua
-- User directives: the "Directive Auto" mode from the design.
--
-- The director normally chooses its own goal. A directive is a user's explicit
-- request ("go shop", "rest", "train") that overrides that choice until it either
-- times out or is cancelled. Entries are transient -- they are not persisted,
-- because a directive is about *now*.
--
-- Pure: no engine, no I/O. The clock is passed in.

local util = require('scripts.idle.util')

local M = {}

--- Directive id -> the goal it forces. Anything not listed is rejected.
M.GOAL_FOR = {
  shop = 'shop',
  sell_junk = 'sell_junk',
  sell = 'sell_junk',
  rest = 'rest',
  train = 'train',
  heal = 'heal',
  talk = 'talk',
  quest = 'quest',
  travel = 'travel',
  explore = 'explore',
  -- Force a "world action" from the console's Order tab.
  wait = 'idle',        -- stand still until the TTL lapses
  stop = 'idle',
  roam = 'explore',     -- wander the area (same thing explore already does)
  go_town = 'go_town',  -- travel service if there is one, else walk to town
  -- Tap-to-move: the payload carries the destination (and target) the tap chose.
  walk_to = 'walk_to',
}

M.DEFAULT_TTL = 120 -- simulated seconds a directive stays in force

local Queue = {}
Queue.__index = Queue

function M.new(ttl)
  return setmetatable({ items = {}, ttl = ttl or M.DEFAULT_TTL, seq = 0 }, Queue)
end

function M.isKnown(id) return M.GOAL_FOR[id] ~= nil end

--- Every directive id a UI can offer, sorted.
function M.ids() return util.sortedKeys(M.GOAL_FOR) end

--- Queue a directive. Returns the entry, or nil for an unknown id.
function Queue:push(id, payload, now)
  local goal = M.GOAL_FOR[id]
  if not goal then return nil end
  now = now or 0
  self.seq = self.seq + 1
  local entry = {
    id = id,
    goal = goal,
    payload = payload,
    pushedAt = now,
    expiresAt = now + self.ttl,
    seq = self.seq,
  }
  self.items[#self.items + 1] = entry
  return entry
end

--- Drop expired entries.
function Queue:expire(now)
  now = now or 0
  local kept = {}
  for _, entry in ipairs(self.items) do
    if now < entry.expiresAt then kept[#kept + 1] = entry end
  end
  self.items = kept
  return self
end

--- The directive currently in force (after expiring stale ones), or nil.
function Queue:peek(now)
  self:expire(now)
  return self.items[1]
end

function Queue:pop()
  return table.remove(self.items, 1)
end

function Queue:clear()
  self.items = {}
  return self
end

function Queue:size() return #self.items end

--- Describe for the activity log / HUD.
function Queue:describe(now)
  local entry = self:peek(now)
  if not entry then return nil end
  return ('%s (%.0fs left)'):format(entry.id, math.max(0, entry.expiresAt - (now or 0)))
end

M.Queue = Queue

return M
