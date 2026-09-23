-- scripts/idle/uiReport.lua
-- A readable report of everything we can know about the UI and the mod's own drawing.
--
-- WHY THIS EXISTS
-- ---------------
-- Driving a real game meant guessing what was on screen from pixels, badly, for a long
-- time. The engine will tell us a lot if we ask: the UI mode stack names the open window,
-- `ui.getElements()` enumerates every element the LUA layer created (not the engine's own
-- widgets -- see docs/ui-inventory.md), and the screen size plus the layout give the
-- geometry. This module turns all of that into one report that goes to the engine log,
-- where a monitor can read it.
--
-- Two jobs, both pure so they are testable:
--   1. M.format(data) -> a multi-line report (no engine access here).
--   2. M.parseCommand(text) -> {verb, arg} for the dev command channel.

local M = {}

--- The report. `data` is gathered by the runtime; every field is optional so a partial
--- gather still produces something honest rather than throwing.
function M.format(data)
  data = data or {}
  local lines = {}
  local function add(label, value)
    lines[#lines + 1] = ('%-14s %s'):format(label, tostring(value))
  end

  lines[#lines + 1] = '== idle-openmw ui report =='

  -- What the engine has open. This is the single most useful line: it names the window
  -- (ChargenName, Dialogue, Interface, Loading, ...).
  local modes = data.uiModes
  if type(modes) ~= 'table' then
    add('screen', 'unavailable (' .. tostring(modes) .. ')')
  elseif #modes == 0 then
    add('screen', 'empty (no modal window open)')
  else
    add('screen', table.concat(modes, ' > '))
  end
  if data.uiKind then add('screen kind', data.uiKind) end
  if data.uiLabel and data.uiLabel ~= '' then add('screen label', data.uiLabel) end

  -- Game state that changes what we are allowed to do.
  add('phase', tostring(data.phase) .. (data.phaseLabel and (' (' .. data.phaseLabel .. ')') or ''))
  add('acting', tostring(data.acting))
  add('paused', tostring(data.paused))
  add('charGenDone', tostring(data.charGenDone))
  add('mode', tostring(data.mode))

  -- Where we are, so "stuck" can be told from "walking somewhere".
  add('cell', tostring(data.cell))
  if data.position then
    add('position', ('%.0f, %.0f, %.0f'):format(data.position.x or 0, data.position.y or 0,
      data.position.z or 0))
  end

  -- Geometry: what we assume the screen looks like, and what we actually drew.
  if data.screen then
    -- Vector2 is userdata in 0.51: read x/y, or it prints as "<userdata>"
    add('screen size', ('%dx%d'):format(tonumber(data.screen.x) or 0,
      tonumber(data.screen.y) or 0))
  end
  if data.ticking ~= nil then add('sim ticking', tostring(data.ticking)) end
  if data.scale then add('gui scale', tostring(data.scale)) end
  if data.textScale then add('text scale', tostring(data.textScale)) end
  if data.narrationRect then
    local r = data.narrationRect
    add('narration box', ('%d,%d %dx%d'):format(r.x, r.y, r.width, r.height))
  end

  -- Our own elements. ui.getElements() returns ONLY what the Lua layer created, so this is
  -- the mod's drawing, not the game's UI -- worth saying out loud in the report.
  local elements = data.elements
  if type(elements) == 'table' then
    add('lua elements', tostring(#elements) .. ' (ours only, not the game widgets)')
    local byName = {}
    for _, element in ipairs(elements) do
      local props = element and element.layout and element.layout.props
      local name = (props and props.name) or '(unnamed)'
      byName[name] = (byName[name] or 0) + 1
    end
    local names = {}
    for name, count in pairs(byName) do
      names[#names + 1] = ('%s x%d'):format(name, count)
    end
    table.sort(names)
    if #names > 0 then add('', table.concat(names, ', ')) end
  else
    -- Print the reason. Swallowing it cost a trip down the wrong path: "unavailable" with
    -- no cause looks like a missing API when it may be an error in the call.
    add('lua elements', tostring(elements or 'unavailable'))
  end

  if data.blocked ~= nil then add('blocked', tostring(data.blocked)) end
  if data.blockedCause then add('blocked by', tostring(data.blockedCause)
    .. (data.blockedMode and (' (' .. tostring(data.blockedMode) .. ')') or '')) end
  if data.hint then add('hint', tostring(data.hint)) end
  if data.snapshot then add('snapshot', tostring(data.snapshot)) end
  if data.lifecycle then add('lifecycle', tostring(data.lifecycle)) end
  if data.capabilities then add('capabilities', tostring(data.capabilities)) end
  if data.note then add('note', tostring(data.note)) end
  return table.concat(lines, '\n')
end

--- Parse a line from the dev command channel (`dev_command.txt` in the data folder).
---
--- This exists because injecting input into the running game is unreliable, while READING
--- a file is not: the mod polls the file through openmw.vfs, so writing a line is a
--- dependable way to ask the running game for something. Verbs:
---
---   ui | dump        report the UI and state to the engine log
---   heartbeat <sec>  report repeatedly every <sec> seconds (0 to stop)
---   telemetry <sec>  push machine-readable telemetry every <sec> seconds
---   note <text>      show <text> as the narration line
---   stop             clear the heartbeat (leaves the narration alone)
function M.parseCommand(text)
  if type(text) ~= 'string' then return nil end
  local command = text:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
  if command == '' then return nil end

  local verb, rest = command:match('^(%S+)%s*(.*)$')
  verb = (verb or ''):lower()
  if verb == 'ui' or verb == 'dump' then return { verb = 'dump' } end
  if verb == 'telemetry' then
    return { verb = 'telemetry', seconds = tonumber(rest) }
  end
  if verb == 'heartbeat' then
    local seconds = tonumber(rest)
    return { verb = 'heartbeat', seconds = seconds }
  end
  if verb == 'note' then return { verb = 'note', text = rest } end
  if verb == 'camera' then return { verb = 'camera', text = rest } end
  if verb == 'economy' then return { verb = 'economy', text = rest } end
  if verb == 'stop' then return { verb = 'stop' } end
  return { verb = 'unknown', text = command }
end

return M
