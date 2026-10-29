-- scripts/idle/places.lua
-- "What is around me" -> the Android strip's go-to buttons, and the town wander leash.
--
-- PURE: plain tables in, plain tables out. The runtime (scripts/idleDirector.lua) reads the
-- engine's nearby doors and actors with scripts/runtime/entities.lua and hands them in as
--   { entity = <entities.read table>, object = <engine object> }
-- pairs. This module never looks at `object`; it only carries it so the director can activate it.
--
-- FIRST SLICE: Seyda Neen only (exterior + its interiors). Elsewhere `collect` still works, but
-- the director only wanders inside a town this module knows (M.TOWNS).

local M = {}

--- Towns the idle wander is allowed in. Matched as a prefix of the cell name, so
--- "Seyda Neen, Arrille's Tradehouse" counts as Seyda Neen.
M.TOWNS = { 'Seyda Neen' }

M.MAX_DOORS = 5
M.MAX_TALK = 2
--- Ignore anything further than this (game units, ~70 per metre): keeps paths short.
M.RANGE = 4000
--- How far from the anchor a wander point may be.
M.LEASH = 1400

local function dist(a, b)
  if not (a and b) then return math.huge end
  local dx, dy = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0)
  return math.sqrt(dx * dx + dy * dy)
end
M.dist = dist

--- The town a cell belongs to, or nil.
function M.townOf(cellName)
  if type(cellName) ~= 'string' then return nil end
  for _, town in ipairs(M.TOWNS) do
    if cellName:sub(1, #town) == town then return town end
  end
  return nil
end

--- Short label for a door's destination: "Seyda Neen, Arrille's Tradehouse" -> "Arrille's Tradehouse".
function M.shortName(destCell, town)
  if type(destCell) ~= 'string' or destCell == '' then return nil end
  if town and destCell:sub(1, #town + 2) == town .. ', ' then return destCell:sub(#town + 3) end
  return destCell
end

local function slug(text)
  return (tostring(text):lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', ''))
end

--- Build the place list.
--- @param input { cell = {name,isExterior}, from = {x,y,z}, doors = {...}, actors = {...} }
--- @return table list of { id, label, kind = 'door'|'talk', dest, distance, ref } sorted by distance
function M.collect(input)
  input = input or {}
  local cell = input.cell or {}
  local town = M.townOf(cell.name)
  local from = input.from
  local out, seen = {}, {}

  local doors = {}
  for _, pair in ipairs(input.doors or {}) do
    local e = pair.entity or {}
    local d = dist(e.position, from)
    local label = M.shortName(e.destCell, town)
    if e.position and label and d <= M.RANGE then
      local key = 'door:' .. slug(label)
      if not seen[key] or d < seen[key].distance then
        local place = { id = key, label = label, kind = 'door', dest = e.position, distance = d, ref = pair }
        if not seen[key] then doors[#doors + 1] = place else
          for i, p in ipairs(doors) do if p.id == key then doors[i] = place end end
        end
        seen[key] = place
      end
    end
  end
  table.sort(doors, function(a, b) return a.distance < b.distance end)
  for i = 1, math.min(#doors, M.MAX_DOORS) do out[#out + 1] = doors[i] end

  local talk = {}
  for _, pair in ipairs(input.actors or {}) do
    local e = pair.entity or {}
    local d = dist(e.position, from)
    if e.kind == 'npc' and e.position and e.dead ~= true and type(e.name) == 'string' and e.name ~= ''
      and d <= M.RANGE then
      talk[#talk + 1] = { id = 'talk:' .. slug(e.id or e.name), label = e.name, kind = 'talk',
        dest = e.position, distance = d, ref = pair }
    end
  end
  table.sort(talk, function(a, b) return a.distance < b.distance end)
  for i = 1, math.min(#talk, M.MAX_TALK) do out[#out + 1] = talk[i] end
  return out
end

--- The places without engine references, for the panel / app payload.
function M.public(list)
  local out = {}
  for i, p in ipairs(list or {}) do
    out[i] = { id = p.id, label = p.label, kind = p.kind, distance = math.floor(p.distance + 0.5) }
  end
  return out
end

function M.find(list, id)
  for _, p in ipairs(list or {}) do if p.id == id then return p end end
  return nil
end

--- A wander point: usually a random spot within the leash of `anchor`, sometimes a nearby place
--- (a door or an NPC), so the character visibly mills about town instead of drifting.
--- @param rng function() -> [0,1)
function M.wanderPoint(anchor, places, rng, leash)
  rng = rng or math.random
  leash = leash or M.LEASH
  if not anchor then return nil end
  local near = {}
  for _, p in ipairs(places or {}) do
    if dist(p.dest, anchor) <= leash then near[#near + 1] = p end
  end
  if #near > 0 and rng() < 0.4 then
    local p = near[math.floor(rng() * #near) + 1]
    -- stop short of the door/NPC rather than walking into it
    local a = rng() * 2 * math.pi
    return { x = p.dest.x + math.cos(a) * 180, y = p.dest.y + math.sin(a) * 180, z = p.dest.z or anchor.z },
      p.label
  end
  local a = rng() * 2 * math.pi
  local r = leash * (0.3 + 0.7 * rng())
  return { x = anchor.x + math.cos(a) * r, y = anchor.y + math.sin(a) * r, z = anchor.z }, nil
end

return M
