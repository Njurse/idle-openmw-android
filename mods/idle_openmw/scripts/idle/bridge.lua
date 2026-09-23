-- scripts/idle/bridge.lua
-- The engine <-> host bridge: a query API over a file, answered into the log.
--
-- WHY A FILE AND A LOG (docs/bridge-api.md)
-- ----------------------------------------
-- OpenMW's Lua is sandboxed: no sockets, no file writing, no process spawning. What it
-- CAN do is read a file from the data folder (`openmw.vfs`) and print. So the bridge is
-- one line in, one line out:
--
--     in   (data/idle_api.txt)   {"id":4,"method":"cell.current"}
--     out  (engine log/stdout)   IDLEAPI {"id":4,"ok":true,"result":{...}}
--
-- A host process -- the Android layer, a desktop tool, a monitor -- writes requests and
-- tails the log. The same `print` stream reaches stdout, so a parent process that launched
-- the engine can read it directly instead of watching a log file.
--
-- The API is SELF-DESCRIBING: `{"method":"schema"}` returns every method with its
-- parameters, so the host does not hard-code this mod's internals.
--
-- PURE: the data sources are injected, so the whole protocol is testable without an engine.

local json = require('scripts.idle.json')

local M = {}

--- Prefix on every response line, so a host can filter the stream cheaply. Chosen to be
--- greppable in a log full of engine chatter.
M.PREFIX = 'IDLEAPI '

--- Protocol version. Bump when a response shape changes, not when a method is added.
M.VERSION = 1

--- Every method the bridge answers. This table IS the documentation: `schema` serves it,
--- and docs/bridge-api.md is generated from the same list by hand.
M.METHODS = {
  { name = 'ping', description = 'Liveness and identity.',
    params = {} },
  { name = 'schema', description = 'This list, so a host need not hard-code it.',
    params = {} },
  { name = 'capabilities', description = 'What this engine supports (scripts/runtime/capabilities.lua).',
    params = {} },
  { name = 'player', description = 'The player: name, position, cell, level, gold, health.',
    params = {} },
  { name = 'cell.current', description = 'The cell the player is in: name, region, grid, exterior flag.',
    params = {} },
  { name = 'entities.nearby', description = 'Actors and objects near the player.',
    params = { 'radius (number, optional; default 2048)' } },
  { name = 'quests.active', description = 'Started, unfinished quests with their current stage.',
    params = {} },
  { name = 'journal.topics', description = 'Journal topics the player has heard of.',
    params = {} },
  { name = 'ui', description = 'The UI report: open window, pause, phase, geometry (scripts/idle/uiReport.lua).',
    params = {} },
  { name = 'ui.target', description = 'What the crosshair is on, and what can be done with it.',
    params = {} },
  { name = 'ui.interactables', description = 'Doors, activators, containers and actors near the player, nearest first.',
    params = { 'radius (number, optional; default 1024)' } },
  { name = 'ui.hints', description = 'The same advice the game gives on screen, derived instead of read.',
    params = {} },
  { name = 'action', description = 'Ask the mod to do something (routed through the director).',
    params = { 'goal (string)', 'ttl (number, optional)' } },
}

--- Methods whose answers come from the runtime. A source may be missing; the bridge then
--- answers `unavailable` for that method rather than failing the whole request.
local SOURCE_METHODS = {
  capabilities = 'capabilities',
  player = 'player',
  ['cell.current'] = 'cell',
  ['entities.nearby'] = 'entities',
  ['quests.active'] = 'quests',
  ['journal.topics'] = 'topics',
  ui = 'ui',
  ['ui.target'] = 'uiTarget',
  ['ui.interactables'] = 'uiInteractables',
  ['ui.hints'] = 'uiHints',
}

--- @param sources table name -> function(params) -> value
--- @param options table|nil { onAction = function(goal, ttl) }
function M.new(sources, options)
  local self = { sources = sources or {}, options = options or {} }

  local function describe()
    local out = {}
    for _, method in ipairs(M.METHODS) do
      out[#out + 1] = { name = method.name, description = method.description,
                        params = method.params }
    end
    return out
  end

  --- Run one request. Returns the envelope (never throws): every failure becomes
  --- `{ok=false, error=...}`, because a bridge that dies on a bad line is a bridge a host
  --- cannot trust to stay up.
  function self:dispatch(request)
    if type(request) ~= 'table' then
      return { ok = false, error = 'request must be a JSON object' }
    end
    local envelope = {}
    if request.id ~= nil then envelope.id = request.id end

    local method = request.method
    if type(method) ~= 'string' or method == '' then
      envelope.ok = false
      envelope.error = 'missing "method"'
      return envelope
    end

    if method == 'ping' then
      envelope.ok = true
      envelope.result = {
        mod = 'idle-openmw', api = M.VERSION, methods = #M.METHODS,
        -- saying whether this is real time or a fallback counter keeps a host from
        -- measuring intervals with a clock that only counts ticks
        realClock = self.sources.hasRealClock and self.sources.hasRealClock() or nil,
      }
      return envelope
    end

    if method == 'schema' then
      envelope.ok = true
      envelope.result = { version = M.VERSION, methods = describe() }
      return envelope
    end

    if method == 'action' then
      local goal = type(request.params) == 'table' and request.params.goal or nil
      if type(goal) ~= 'string' or goal == '' then
        envelope.ok = false
        envelope.error = 'action needs params.goal'
        return envelope
      end
      if type(self.options.onAction) ~= 'function' then
        envelope.ok = false
        envelope.error = 'this build accepts no actions'
        return envelope
      end
      local ok, result = pcall(self.options.onAction, goal,
        type(request.params) == 'table' and request.params.ttl or nil)
      if not ok then
        envelope.ok = false
        envelope.error = 'action failed: ' .. tostring(result)
        return envelope
      end
      envelope.ok = true
      envelope.result = result or { accepted = true, goal = goal }
      return envelope
    end

    local sourceName = SOURCE_METHODS[method]
    if not sourceName then
      envelope.ok = false
      envelope.error = 'unknown method: ' .. method
      envelope.hint = 'ask for "schema"'
      return envelope
    end

    local source = self.sources[sourceName]
    if type(source) ~= 'function' then
      envelope.ok = false
      envelope.error = 'unavailable in this build: ' .. sourceName
      return envelope
    end

    local ok, value = pcall(source, request.params or {})
    if not ok then
      envelope.ok = false
      envelope.error = 'source failed: ' .. tostring(value)
      return envelope
    end
    envelope.ok = true
    envelope.result = value
    return envelope
  end

  --- Handle one line of the request file.
  --- @return string|nil response line (already prefixed), or nil for a blank/comment line
  function self:handleLine(line)
    if type(line) ~= 'string' then return nil end
    local trimmed = line:gsub('^%s+', ''):gsub('%s+$', '')
    if trimmed == '' or trimmed:sub(1, 1) == '#' then return nil end

    local request, err = json.decode(trimmed)
    if not request then
      return M.PREFIX .. json.encode({ ok = false, error = 'bad JSON: ' .. tostring(err),
                                       echo = trimmed })
    end
    return M.PREFIX .. json.encode(self:dispatch(request))
  end

  --- The periodic push, so a host can also just watch rather than poll.
  function self:telemetry()
    local result = {}
    for _, method in ipairs(M.METHODS) do
      local sourceName = SOURCE_METHODS[method.name]
      if sourceName and type(self.sources[sourceName]) == 'function' then
        local ok, value = pcall(self.sources[sourceName], {})
        if ok then result[sourceName] = value end
      end
    end
    return M.PREFIX .. json.encode({ ok = true, telemetry = true, result = result })
  end

  return self
end

return M
