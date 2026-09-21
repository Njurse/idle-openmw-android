-- scripts/idle/activityLog.lua
-- A bounded, ordered activity log -- the "Walking to Arrille's Tradehouse…
-- Sold 5 chitin weapons for 120 gold." feed the HUD shows.
--
-- Pure: takes an explicit `time` rather than reading a clock, so tests are
-- deterministic and there is no engine dependency.

local util = require('scripts.idle.util')

local M = {}

M.LEVELS = { 'info', 'good', 'warn', 'bad' }

local Log = {}
Log.__index = Log

--- @param limit maximum entries retained (oldest are dropped)
function M.new(limit)
  return setmetatable({
    limit = limit or 200,
    entries = {},
    seq = 0,
    lastKeys = {},
  }, Log)
end

function Log:count() return #self.entries end
function Log:clear()
  self.entries = {}
  self.lastKeys = {}
end

--- Append an entry. `key` (optional) enables throttling via :addOnce.
function Log:add(message, level, time, key)
  self.seq = self.seq + 1
  local entry = {
    seq = self.seq,
    message = message,
    level = level or 'info',
    time = time or 0,
    key = key,
  }
  self.entries[#self.entries + 1] = entry
  while #self.entries > self.limit do table.remove(self.entries, 1) end
  return entry
end

--- Append only if `key` has not been logged within `cooldown` seconds.
--- Returns the entry, or nil when throttled.
function Log:addOnce(key, message, level, time, cooldown)
  cooldown = cooldown or 30
  local lastTime = self.lastKeys[key]
  if lastTime ~= nil and (time or 0) - lastTime < cooldown then return nil end
  self.lastKeys[key] = time or 0
  return self:add(message, level, time, key)
end

--- The newest `n` entries, oldest-first.
function Log:recent(n)
  n = n or 10
  local out = {}
  local start = math.max(1, #self.entries - n + 1)
  for i = start, #self.entries do out[#out + 1] = self.entries[i] end
  return out
end

function Log:all() return util.copy(self.entries) end
function Log:last() return self.entries[#self.entries] end
function Log:lastMessage()
  local entry = self:last()
  return entry and entry.message
end

--- Find entries whose message contains `needle` (plain substring).
function Log:find(needle)
  local out = {}
  for _, entry in ipairs(self.entries) do
    if entry.message:find(needle, 1, true) then out[#out + 1] = entry end
  end
  return out
end

--- Compact "0m", "12m", "5h 03m" rendering of a simulated second count.
function M.formatTime(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  if hours > 0 then
    return ('%dh %02dm'):format(hours, minutes)
  end
  return ('%dm'):format(minutes)
end

--- Render the newest `n` entries as lines, e.g. "5h 03m  Sold 5 chitin weapons".
function Log:toLines(n)
  local out = {}
  for _, entry in ipairs(self:recent(n)) do
    out[#out + 1] = ('%s  %s'):format(M.formatTime(entry.time), entry.message)
  end
  return out
end

return M
