-- scripts/idle/notify.lua
-- A tiny queue of things worth telling the player about.
--
-- The point is the separation: the director *decides* something is worth saying
-- ("we reached Balmora"), this module holds it, and the runtime decides *how* to
-- say it (an in-game message box now, an Android notification later). So the
-- interesting logic is pure and testable, and the plumbing is one hook.
--
-- Bounded, because an unattended run overnight must not grow without limit.

local util = require('scripts.idle.util')

local M = {}

M.PRIORITY = { info = 1, notable = 2, urgent = 3 }

--- Kinds the director emits. The runtime may route these differently.
M.KIND = {
  arrival = 'arrival',      -- reached a settlement
  departure = 'departure',  -- left one / heading out
  danger = 'danger',        -- badly hurt, fleeing
  milestone = 'milestone',  -- level, gold, a goal completed
  session = 'session',      -- offline progress summary
}

local function normalisePriority(value)
  if type(value) == 'number' then
    return util.clamp(math.floor(value), 1, 3)
  end
  return M.PRIORITY[value] or M.PRIORITY.info
end

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    limit = math.max(1, math.floor(opts.limit or 50)),
    entries = {},   -- bounded history, oldest first
    pending = {},   -- not yet surfaced to the player
    dropped = 0,    -- how many fell off the end of the history
  }, { __index = M })
end

--- Record something worth telling the player.
--- @param kind  one of M.KIND (free-form is fine)
--- @param title short line, e.g. "Arrived in Balmora"
--- @param detail optional extra context
--- @param priority number 1..3 or a key of M.PRIORITY
--- @param time simulation time
function M:push(kind, title, detail, priority, time)
  local entry = {
    kind = kind or 'info',
    title = title or '',
    detail = detail,
    priority = normalisePriority(priority),
    time = time or 0,
  }
  self.entries[#self.entries + 1] = entry
  while #self.entries > self.limit do
    table.remove(self.entries, 1)
    self.dropped = self.dropped + 1
  end
  self.pending[#self.pending + 1] = entry
  return entry
end

--- Take everything not yet surfaced, clearing the pending list.
--- The runtime calls this once per refresh and does something with the result.
function M:drain()
  local out = self.pending
  self.pending = {}
  return out
end

--- Peek without consuming.
function M:peek()
  return self.pending
end

function M:pendingCount()
  return #self.pending
end

--- Drop pending entries at or below a priority. Used to avoid nagging.
function M:dropBelow(priority)
  local floor = normalisePriority(priority)
  local kept = {}
  for _, entry in ipairs(self.pending) do
    if entry.priority > floor then kept[#kept + 1] = entry end
  end
  self.pending = kept
  return #kept
end

--- The most recent n entries, newest first.
function M:recent(count)
  count = math.max(0, math.floor(count or #self.entries))
  local out = {}
  for index = #self.entries, 1, -1 do
    if #out >= count then break end
    out[#out + 1] = self.entries[index]
  end
  return out
end

--- The single most important pending entry, or nil. Handy for a HUD line.
function M:mostImportant()
  local best
  for _, entry in ipairs(self.pending) do
    if not best or entry.priority > best.priority then best = entry end
  end
  return best
end

function M:clear()
  self.entries = {}
  self.pending = {}
  self.dropped = 0
end

return M
