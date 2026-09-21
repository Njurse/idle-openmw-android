-- scripts/idle/dialogue.lua
-- Interpreting dialogue. Pure: no engine, no I/O.
--
-- IMPORTANT SCOPE LIMIT (docs/openmw-lua-api.md §4): OpenMW's Lua API is
-- observe-only for dialogue. There is no `onInfoGetText` handler and no way to
-- trigger or select a topic programmatically. `DialogueResponse` is a
-- notification-only Lua event delivered to the PLAYER script:
--
--   { actor = <GameObject>, type = 'greeting'|'journal'|'persuasion'|'topic'|'voice',
--     recordId = <string>, infoId = <string> }
--
-- So this module does not "drive" conversations; it turns the event stream into
-- world knowledge (who talks to us, which topics exist, who refuses us) that the
-- director can act on with engine-level moves only.

local util = require('scripts.idle.util')

local M = {}

M.TYPES = { 'greeting', 'journal', 'persuasion', 'topic', 'voice' }

M.INTENTS = {
  greet = 'greet',
  note_topic = 'note_topic',
  log_journal = 'log_journal',
  note_refusal = 'note_refusal',
  ignore = 'ignore',
}

--- Normalize a raw DialogueResponse payload. Returns nil for non-tables.
--- Unknown `type` values are preserved as 'unknown' rather than dropped.
function M.parse(event)
  if type(event) ~= 'table' then return nil end
  local kind = event.type
  local known = false
  for _, candidate in ipairs(M.TYPES) do
    if candidate == kind then known = true break end
  end
  return {
    actor = event.actor,
    kind = known and kind or 'unknown',
    recordId = event.recordId,
    infoId = event.infoId,
    knownType = known,
  }
end

--- Decide the director's intent for a parsed response.
--- @return { intent, topic?, note? }
function M.interpret(parsed)
  if not parsed then return { intent = 'ignore' } end
  if parsed.kind == 'greeting' then
    return { intent = 'greet' }
  elseif parsed.kind == 'topic' then
    return { intent = 'note_topic', topic = parsed.recordId }
  elseif parsed.kind == 'journal' then
    return { intent = 'log_journal', note = parsed.recordId }
  elseif parsed.kind == 'persuasion' then
    return { intent = 'note_refusal' }
  end
  return { intent = 'ignore' }
end

--- A stable identifier for whatever actor a payload refers to.
function M.actorId(actor)
  if type(actor) ~= 'table' then return nil end
  return actor.recordId or actor.id or actor.uniqueId or tostring(actor)
end

--- One-line description for the activity log.
function M.describe(parsed)
  if not parsed then return 'dialogue event' end
  local who = M.actorId(parsed.actor) or 'someone'
  if parsed.kind == 'greeting' then return who .. ' greeted you'
  elseif parsed.kind == 'topic' then return ('%s spoke about "%s"'):format(who, tostring(parsed.recordId))
  elseif parsed.kind == 'journal' then return 'journal updated: ' .. tostring(parsed.recordId)
  elseif parsed.kind == 'persuasion' then return who .. ' refused'
  elseif parsed.kind == 'voice' then return who .. ' spoke'
  end
  return who .. ' said something'
end

-- ---------------------------------------------------------------------------
-- Conversation memory (persists across the session; serialized by the runtime)
-- ---------------------------------------------------------------------------

local Memory = {}
Memory.__index = Memory

function M.newMemory()
  return setmetatable({ actors = {}, topics = {}, refusals = {}, events = 0 }, Memory)
end

--- Record an observation.
function Memory:observe(parsed, time)
  if not parsed then return self end
  self.events = self.events + 1
  time = time or 0

  local id = M.actorId(parsed.actor)
  if id then
    local record = self.actors[id] or { id = id, greetings = 0, topics = 0, refusals = 0, lastSeen = time }
    if parsed.kind == 'greeting' then record.greetings = record.greetings + 1
    elseif parsed.kind == 'topic' then record.topics = record.topics + 1
    elseif parsed.kind == 'persuasion' then record.refusals = record.refusals + 1
    end
    record.lastSeen = time
    self.actors[id] = record
  end

  if parsed.kind == 'topic' and parsed.recordId then
    self.topics[parsed.recordId] = (self.topics[parsed.recordId] or 0) + 1
  end
  if parsed.kind == 'persuasion' and id then
    self.refusals[id] = (self.refusals[id] or 0) + 1
  end
  return self
end

function Memory:refusalsFor(id) return self.refusals[id] or 0 end

function Memory:knownTopics()
  local out = {}
  for topic, count in pairs(self.topics) do out[#out + 1] = { topic = topic, count = count } end
  table.sort(out, function(a, b)
    if a.count == b.count then return a.topic < b.topic end
    return a.count > b.count
  end)
  return out
end

function Memory:actorIds() return util.sortedKeys(self.actors) end

function Memory:reset()
  self.actors, self.topics, self.refusals, self.events = {}, {}, {}, 0
end

--- Plain-data snapshot for storage.
function Memory:serialize()
  return { actors = self.actors, topics = self.topics, refusals = self.refusals, events = self.events }
end

function Memory:load(data)
  if type(data) ~= 'table' then return self end
  self.actors = data.actors or {}
  self.topics = data.topics or {}
  self.refusals = data.refusals or {}
  self.events = data.events or 0
  return self
end

return M
