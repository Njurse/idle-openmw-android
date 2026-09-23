-- scripts/idle/registry.lua
-- A bounded memory of the entities the mod has read, so a host can name one in one request and
-- act on it in the next.
--
-- WHY THIS EXISTS
-- Every bridge response is a snapshot: the id in it refers to a game object that the host
-- cannot otherwise reach, because a host speaks text and the engine speaks userdata. So the
-- mod keeps the little it needs to answer "the entity you asked about a moment ago" -- and
-- nothing more. Two rules follow from that, and both matter:
--
--   1. **Identity, not state.** We remember enough to *find* the entity again (its `id`, its
--      `formId`, its `recordId`, its name), plus the position and cell we last saw it in. We
--      do not pretend to know its health or its inventory: those must be read live. A
--      remembered position is a labellable fact (`lastSeen`), not a current one.
--   2. **Bounded.** The registry is capped and evicts least-recently-seen first, because a
--      mod that grows a table per object it has ever seen is a memory leak with extra steps.
--      The cap is small on purpose: a host that wants a named entity it forgot to act on can
--      always re-read `entities.nearby`.
--
-- PURE -- no engine, no clock. The caller supplies the tick count, so specs can drive it.

local M = {}

--- How many entities to remember. Morrowind cells are crowded; a few hundred is plenty for
--- "name the thing you just looked at" and small enough to be free.
M.DEFAULT_CAP = 200

--- The fields we keep from a read entity. Deliberately a short list: this is a name badge,
--- not a copy of the entity.
local KEEP = {
  'id', 'kind', 'formId', 'recordId', 'name', 'list',
  -- last seen here, so a later request has somewhere to start without a full re-read
  'position', 'cell',
}

--- @param cap number|nil how many entities to keep (defaults to M.DEFAULT_CAP)
function M.new(cap)
  if type(cap) ~= 'number' or cap < 1 then cap = M.DEFAULT_CAP end
  local self = {
    cap = math.floor(cap),
    tick = 0,
    entries = {},
    -- recency order, least recently seen FIRST: appending is cheap and eviction pops [1]
    order = {},
    evicted = 0,
    stored = 0,
  }
  return setmetatable(self, { __index = M })
end

--- Drop an id from the recency list. Linear, and that is fine: the list is bounded by `cap`.
function M:_unlink(id)
  for index = 1, #self.order do
    if self.order[index] == id then
      table.remove(self.order, index)
      return true
    end
  end
  return false
end

--- Remember (or refresh) one entity read from the world.
---
--- @param entity table a schema entity from scripts/idle/entity.lua
--- @param time number|nil the caller's tick/second count, for `lastSeen`
--- @return table|nil the stored entry, nil when the entity is unusable
function M:remember(entity, time)
  if type(entity) ~= 'table' then return nil end
  local id = entity.id
  -- an entity with no id cannot be named later, which is the whole point of the registry
  if type(id) ~= 'string' or id == '' then return nil end

  self.tick = self.tick + 1
  local now = time or self.tick

  local entry = self.entries[id]
  if entry then
    entry.lastSeen = now
    entry.seen = entry.seen + 1
    entry.tick = self.tick
    -- refresh the remembered facts: an entity that moved should not stay stale here
    for _, field in ipairs(KEEP) do
      if entity[field] ~= nil then entry[field] = entity[field] end
    end
  else
    entry = { firstSeen = now, lastSeen = now, seen = 1, tick = self.tick }
    for _, field in ipairs(KEEP) do
      if entity[field] ~= nil then entry[field] = entity[field] end
    end
    self.entries[id] = entry
    self.stored = self.stored + 1
  end

  self:_unlink(id)
  self.order[#self.order + 1] = id
  self:_trim()
  return entry
end

--- Evict least-recently-seen entries until we are back inside the cap.
function M:_trim()
  while #self.order > self.cap do
    local oldest = table.remove(self.order, 1)
    if oldest and self.entries[oldest] then
      self.entries[oldest] = nil
      self.evicted = self.evicted + 1
    end
  end
end

--- The remembered entry for an id, or nil. Returns a copy, so a caller cannot mutate our
--- memory by accident -- the registry is the only thing that writes to it.
function M:get(id)
  if type(id) ~= 'string' then return nil end
  local entry = self.entries[id]
  if not entry then return nil end
  local copy = {}
  for key, value in pairs(entry) do copy[key] = value end
  copy.remembered = true
  return copy
end

function M:has(id)
  return type(id) == 'string' and self.entries[id] ~= nil
end

function M:forget(id)
  if not self:has(id) then return false end
  self.entries[id] = nil
  self:_unlink(id)
  return true
end

function M:clear()
  local had = #self.order
  self.entries = {}
  self.order = {}
  return had
end

function M:count() return #self.order end

function M:evictedCount() return self.evicted end

--- Everything remembered, most recently seen first.
---
--- Sorted explicitly (recency, then id) rather than in hash order, so two identical runs
--- produce identical output -- the same rule the JSON codec follows.
function M:list(kind)
  local out = {}
  for _, id in ipairs(self.order) do
    local entry = self.entries[id]
    if entry and (kind == nil or entry.kind == kind) then
      local copy = {}
      for key, value in pairs(entry) do copy[key] = value end
      copy.remembered = true
      out[#out + 1] = copy
    end
  end
  table.sort(out, function(a, b)
    if a.lastSeen ~= b.lastSeen then return a.lastSeen > b.lastSeen end
    return tostring(a.id) < tostring(b.id)
  end)
  return out
end

--- Remember several entities at once (a nearby list). Returns how many were stored.
function M:rememberAll(entities, time)
  if type(entities) ~= 'table' then return 0 end
  local stored = 0
  for _, entity in ipairs(entities) do
    if self:remember(entity, time) then stored = stored + 1 end
  end
  return stored
end

-- `position` and `cell` are still the SNAPSHOT we took, so name them honestly: a caller that
-- needs the entity's real position must read it again.
function M.describe(entry)
  if type(entry) ~= 'table' then return 'unknown entity' end
  return string.format('%s (%s)%s', tostring(entry.name or entry.recordId or entry.id),
    tostring(entry.kind or '?'),
    entry.lastSeen and (' last seen at t=' .. tostring(entry.lastSeen)) or '')
end

return M
