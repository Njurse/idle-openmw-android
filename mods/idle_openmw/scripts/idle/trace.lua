-- scripts/idle/trace.lua
-- A structured decision recorder, for *development*.
--
-- WHY THIS EXISTS
-- ---------------
-- The activity log (scripts/idle/activityLog.lua) is for the player: short,
-- friendly, deduplicated. Watching an idle bot go wrong needs the opposite --
-- every decision, with its numbers, in order, so you can see *why* it chose what
-- it chose and where the streak began. That is what this is, and it is the
-- difference between "the sim is green" and "I can see the bot looping".
--
-- It is PURE: no clock, no engine, no IO. Events are appended with the caller's
-- time and rendered on demand, so `tests/sim/headless_sim.lua` can print a
-- timeline of a 1000-hour run and a spec can assert on the exact sequence.

local M = {}

--- @param limit number ring-buffer size (default 500)
function M.new(limit)
  return setmetatable({
    limit = limit or 500,
    items = {},
    dropped = 0,
    counts = {},
  }, { __index = M })
end

--- Record one event. `fields` is optional and only affects the rendering.
--- A nil kind is tolerated (defaulted) so a caller bug cannot break the loop.
function M:add(kind, message, time, fields)
  if type(kind) ~= 'string' or kind == '' then kind = 'note' end
  self.items[#self.items + 1] = {
    kind = kind,
    message = message or '',
    time = time or 0,
    fields = fields,
  }
  self.counts[kind] = (self.counts[kind] or 0) + 1
  while #self.items > self.limit do
    table.remove(self.items, 1)
    self.dropped = self.dropped + 1
  end
  return self
end

function M:count() return #self.items end
function M:countOf(kind) return self.counts[kind] or 0 end
function M:droppedCount() return self.dropped end
function M:clear() self.items = {} self.dropped = 0 self.counts = {} return self end

--- The last `n` events (all of them when `n` is nil).
function M:tail(n)
  if not n or n >= #self.items then
    local copy = {}
    for i, item in ipairs(self.items) do copy[i] = item end
    return copy
  end
  local out = {}
  for i = #self.items - n + 1, #self.items do out[#out + 1] = self.items[i] end
  return out
end

--- One event as a fixed-width line: "  121.4  goal     fight (2 hostiles)".
function M.formatEvent(event)
  if type(event) ~= 'table' then return '' end
  local fields = ''
  if type(event.fields) == 'table' and #event.fields > 0 then
    fields = '  [' .. table.concat(event.fields, ' ') .. ']'
  end
  return ('%8.1f  %-9s %s%s'):format(event.time or 0, tostring(event.kind or ''),
    tostring(event.message or ''), fields)
end

--- The whole trace (or the last `n`), one line per event, oldest first.
function M:lines(n)
  local out = {}
  for _, event in ipairs(self:tail(n)) do out[#out + 1] = M.formatEvent(event) end
  return out
end

--- A summary line per kind: "goal=120 directive=3".
function M:summary()
  local names = {}
  for kind in pairs(self.counts) do names[#names + 1] = kind end
  table.sort(names)
  local parts = {}
  for _, kind in ipairs(names) do
    parts[#parts + 1] = ('%s=%d'):format(kind, self.counts[kind])
  end
  return table.concat(parts, '  ')
end

--- The rendered trace as one string (newline-joined), for print/log.
function M:format(n)
  return table.concat(self:lines(n), '\n')
end

return M
