-- scripts/idle/appPayload.lua
-- What the native Android app is told, and what it may ask for.
--
-- WHY THIS IS PURE AND SEPARATE
-- The app draws; the mod judges (docs/app-ui.md: "the app should never re-derive judgement from raw
-- numbers"). So the schema is decided HERE, in a module with no engine access and a spec, rather
-- than in Java or in a renderer: a field the app reads but the mod never sends is a blank line on a
-- phone, and Java is the worst place in this project to discover one.
--
-- Two directions, both in this file because they are two halves of one contract:
--   M.project(panel)  -> the table the app is sent, serialised by scripts/idle/json.lua
--   M.command(text)   -> the verb a tapped button means, or nil plus a reason
--
-- Anything the app cannot express is refused loudly (nil, reason) rather than quietly ignored.
--
-- Pure: no engine, no I/O. The panel table is the same one the console renders (director panel()),
-- so the two surfaces can never disagree about what the game is doing.

local M = {}

--- Bumped when the shape changes in a way the app must notice. The app is not required to check it,
--- but the number is in every payload so a debugging session can say which side is stale.
M.VERSION = 1

--- The app's buttons -> the mod's own verbs.
---
--- `attack` and `flee` are new directives (scripts/idle/directive.lua); everything else already
--- existed. The value is a directive id, not an engine call -- the app never gets to name an engine
--- action, only an intent.
---
--- 'sneak' is ABSENT ON PURPOSE, and this was found by checking rather than assuming: app-ui.md lists
--- a Sneak button, but this mod has no sneak goal or action -- the word appears in the code only as a
--- SKILL name -- and a directive id whose goal does not exist is a silent no-op. So the button stays
--- (the design asks for it) and the command is REFUSED with a reason the app logs, which is the
--- difference between "not built yet" and "broken".
M.COMMANDS = {
  wait = 'wait',
  go_town = 'go_town',
  roam = 'roam',
  talk = 'talk',
  attack = 'attack',
  flee = 'flee',
  rest = 'rest',
  inventory = 'launch',
  journal = 'launch',
  magic = 'launch',
  map = 'launch',
}

--- The engine window a launcher button opens. `mode` is what ACTIONS.launch needs and `window` is
--- the tab inside that mode (see M.LAUNCHERS in uiModel.lua, whose names these must match).
M.WINDOWS = {
  inventory = { mode = 'Interface' },
  journal = { mode = 'Journal' },
  magic = { mode = 'SpellBuying' },
  map = { mode = 'Interface', window = 'Map' },
}

local function number(value, places)
  if type(value) ~= 'number' then return nil end
  if value ~= value or value == math.huge or value == -math.huge then return nil end
  local factor = 10 ^ (places or 0)
  return math.floor(value * factor + 0.5) / factor
end

--- A 0..1 pool fraction. Anything unusable becomes 0 rather than nil: an absent bar reads as
--- "empty", which is honest, while a nil would serialise as a missing key and leave the app's last
--- value on screen -- a stale bar that looks live.
local function fraction(value)
  local n = number(value, 3)
  if not n then return 0 end
  if n < 0 then return 0 end
  if n > 1 then return 1 end
  return n
end

local function text(value)
  if value == nil then return '' end
  return tostring(value)
end

--- The panel table -> the app's schema. Tolerant of a partial panel: every field is optional, so a
--- half-built report still produces something honest instead of throwing on a phone.
function M.project(panel)
  if type(panel) ~= 'table' then panel = {} end
  local status = type(panel.status) == 'table' and panel.status or {}
  local player = type(panel.player) == 'table' and panel.player or {}

  local payload = {
    version = M.VERSION,
    goal = text(panel.goal ~= nil and panel.goal or 'idle'),
    goalReason = text(panel.goalReason ~= nil and panel.goalReason or panel.reason),
    mode = text(panel.mode or 'auto'),
    phase = text(panel.phase or 'world'),
    cell = text(panel.cell),
    player = {
      gold = number(player.gold),
      level = number(player.level),
    },
    status = {
      healthFraction = fraction(status.healthFraction),
      magickaFraction = fraction(status.magickaFraction),
      fatigueFraction = fraction(status.fatigueFraction),
    },
  }

  local load = type(player.encumbrance) == 'table' and player.encumbrance or nil
  if load then
    payload.player.encumbrance = { current = number(load.current), max = number(load.max) }
  end

  -- The last log line, so the app has something to say about what just happened. Only the newest:
  -- the app's panel is a status surface, not the Log screen (docs/app-ui.md).
  local log = panel.log
  if type(log) == 'table' and #log > 0 then
    local last = log[#log]
    if type(last) == 'table' then
      payload.lastLog = { time = number(last.time, 1), message = text(last.message) }
    end
  end

  return payload
end

--- A line from the app -> a verb the director understands, or nil and why not.
--- @return table|nil entry with .action (+ .payload), or nil
--- @return string|nil reason when it was refused
function M.command(text_)
  if type(text_) ~= 'string' or text_ == '' then
    return nil, 'empty command'
  end

  local json = require('scripts.idle.json')
  local ok, decoded = pcall(json.decode, text_)
  if not ok or type(decoded) ~= 'table' then
    return nil, 'unreadable command: ' .. tostring(text_)
  end

  local id = decoded.command
  if type(id) ~= 'string' or id == '' then
    return nil, 'command has no name'
  end

  local verb = M.COMMANDS[id]
  if not verb then
    return nil, 'unknown command: ' .. id
  end

  local window = M.WINDOWS[id]
  if window then
    return {
      id = id,
      action = 'launch',
      payload = { mode = window.mode, window = window.window, id = 'open_' .. id },
    }
  end

  -- A payload the app attached (a favourite spell, a destination) is passed through untouched: the
  -- director is what validates it, not this module.
  return { id = id, action = verb, payload = decoded.payload }
end

return M
