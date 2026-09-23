-- scripts/idle/hud.lua
-- Turning what the engine knows into what a player sees.
--
-- WHY THIS EXISTS
-- ---------------
-- The engine will NOT hand over its own on-screen text: Morrowind's messages ("look up at
-- the hatch and press space to open it") live in native widgets, and Lua cannot read them
-- (docs/ui-inventory.md). But it does not have to. Everything that message is really
-- telling the player is derivable:
--
--   * what the crosshair is on      -> camera.viewportToWorldVector + nearby.castRay
--   * what can be interacted with   -> nearby.doors / activators / containers / actors
--   * which key does it             -> input.ACTION + input.getKeyName
--
-- So the HUD API answers the question behind the prompt ("there is a door in front of you
-- that can be opened, and the key is Space") rather than scraping a string.
--
-- PURE: the runtime passes in plain descriptions, so the classification and the wording are
-- testable without an engine.

local util = require('scripts.idle.util')

local M = {}

--- Fallback action word per kind, used when the hint does not name the thing.
M.VERB = {
  door = 'open',
  actor = 'talk to',
  container = 'search',
  item = 'take',
  activator = 'use',
}

--- Order matters: an actor that is also a container should be talked to, a door that is
--- also an activator should be opened.
M.ORDER = { 'actor', 'door', 'container', 'item', 'activator' }

--- Which kind of thing is this? `target` carries whatever the runtime could determine.
--- @param target table { isActor, isDoor, isContainer, isItem, isActivator, ... }
--- @return string kind
function M.kindOf(target)
  if type(target) ~= 'table' then return 'unknown' end
  for _, kind in ipairs(M.ORDER) do
    local flag = 'is' .. kind:sub(1, 1):upper() .. kind:sub(2)
    if target[flag] == true then return kind end
  end
  return 'unknown'
end

--- Describe what can be done with the thing in front of the player.
--- @return table { kind, action, label, name, distance, vertical }
function M.describe(target)
  local kind = M.kindOf(target)
  local name = (type(target) == 'table' and target.name) or nil
  local out = {
    kind = kind,
    action = M.VERB[kind] or nil,
    name = name,
    recordId = type(target) == 'table' and target.recordId or nil,
    distance = type(target) == 'table' and target.distance or nil,
    vertical = type(target) == 'table' and target.vertical or nil,
  }
  if out.action then
    out.label = out.action .. ' the ' .. (name or kind)
    if not name then out.label = out.action .. ' it' end
  end
  return out
end

--- Where is the target relative to the player's eye level? Morrowind hides things above and
--- below you, and "look up" is real advice -- the hatch on the prison ship is overhead.
--- @param targetHeight number|nil
--- @param eyeHeight number|nil
--- @return string|nil 'above'|'below'|'level'
function M.relativeHeight(targetHeight, eyeHeight)
  if type(targetHeight) ~= 'number' or type(eyeHeight) ~= 'number' then return nil end
  local delta = targetHeight - eyeHeight
  if delta > 60 then return 'above' end
  if delta < -60 then return 'below' end
  return 'level'
end

--- The hint lines for the HUD and the bridge's `ui.hints`.
---
--- Written in the imperative, because that is what the game's own prompt does, and ordered
--- most-actionable first so a caller that shows only one line shows the useful one.
--- @param context table { target, activateKey, paused, phase, interactables }
--- @return table list of strings
function M.hints(context)
  context = context or {}
  local hints = {}

  if context.paused == true then
    -- A paused world takes no input and runs no simulation: saying so is the difference
    -- between "the mod is broken" and "the game is waiting for you".
    hints[#hints + 1] = 'The game is paused.'
  end

  local described = M.describe(context.target)
  if described.action then
    local key = context.activateKey
    local what = described.name and (described.kind .. ' (' .. described.name .. ')')
      or described.kind
    local direction = described.vertical == 'above' and ' above you'
      or (described.vertical == 'below' and ' below you' or '')
    local where = direction ~= '' and ('Look' .. direction .. ': there is a ' .. what)
      or ('There is a ' .. what .. ' in front of you')
    if key and key ~= '' then
      hints[#hints + 1] = where .. ' -- press ' .. key .. ' to ' .. described.action .. ' it.'
    else
      hints[#hints + 1] = where .. ' -- it can be ' .. described.action .. 'ed.'
    end
  end

  -- If nothing is in front of the player, the most useful thing we can say is what is
  -- nearby, so they do not have to hunt for it.
  if not described.action then
    local nearest = context.interactables and context.interactables[1]
    if nearest then
      local distance = nearest.distance and (' (' .. nearest.distance .. ' away)') or ''
      -- Say WHY the crosshair is empty. A bare "nothing in front of you" reads the same whether
      -- the ray genuinely hit nothing or the pick is broken -- and the pick was broken for a
      -- long time (Vector3/RayCastingResult results guarded as tables).
      local why = context.targetReason and (' (' .. tostring(context.targetReason) .. ')') or ''
      hints[#hints + 1] = 'Nothing in front of you. Nearest: ' ..
        (nearest.name or nearest.kind or 'something') .. distance .. '.' .. why
    elseif context.interactables then
      hints[#hints + 1] = 'Nothing to interact with nearby.'
    end
  end

  if #hints == 0 then hints[1] = 'Nothing to report.' end
  return hints
end

--- Sort interactables nearest-first, dropping anything without a distance. Pure, so the
--- runtime can hand us whatever the engine gave it and get a stable order back.
---
--- "Whatever the engine gave it" means a USERDATA list is allowed, so the guard is a shape test
--- (`util.isObject`) and the walk is by index: `ipairs` rejects a userdata in LuaJIT.
function M.sortByDistance(list)
  local out = {}
  if not util.isObject(list) then return out end
  local count = 0
  pcall(function() count = #list end)
  for index = 1, count do
    local entry = nil
    pcall(function() entry = list[index] end)
    if util.isObject(entry) then out[#out + 1] = entry end
  end
  table.sort(out, function(a, b)
    local da, db = a.distance or math.huge, b.distance or math.huge
    if da ~= db then return da < db end
    return tostring(a.name or a.recordId or '') < tostring(b.name or b.recordId or '')
  end)
  return out
end

return M
