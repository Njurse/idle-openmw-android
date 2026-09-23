-- scripts/idleWarden.lua
-- GLOBAL script. The acting half of the guardian (scripts/idle/guardian.lua).
--
-- Why this is a separate GLOBAL script instead of more code in idleDirector.lua:
-- the only two actions that can rescue an unattended run are both global-only --
--   * GameObject:teleport -- "Can be called only from a global script", core.lua:255
--   * menu.loadGame      -- menu.lua:34
-- A PLAYER script cannot call either. So *detection* stays in idleDirector.lua
-- (where `self` is the player) and the decision arrives here as a global event:
-- core.sendGlobalEvent -> eventHandlers, the contract in overview.rst:264.
--
-- Verified shapes (docs/openmw-lua-api.md §10):
--   GameObject:teleport(cellOrName, position, options)          core.lua:258-273
--     cellOrName: a Cell, a cell NAME, or '' for the default exterior worldspace.
--                 For an exterior the engine derives the cell from `position`.
--     options:    { rotation = Transform, onGround = boolean }
--     Caveat:     deferred -- "the effect is not immediate; the position will be
--                 updated only in the next frame".
--   menu.loadGame(directory, slotName)                          menu.lua:34
--   menu.getCurrentSaveDir()                                    menu.lua:44
--   world.players -- always exactly one element in single-player, world.lua:15
--   PLAYER.setTeleportingEnabled(player, state)                 types.lua:1334

local core = require('openmw.core')
local world = require('openmw.world')
local types = require('openmw.types')
local util = require('openmw.util')
-- `openmw.menu` is declared `@context menu` (menu.lua:3), so a GLOBAL script cannot
-- require it at load time: doing so killed this entire script with
-- "Can't start Global[scripts/idlewarden.lua]; Lua error: module not found: openmw.menu".
-- Resolve it lazily, and treat its absence as "the reload rescue is unavailable"
-- rather than a crash that would take the teleport rescue down with it.
local function menuModule()
  local ok, module = pcall(require, 'openmw.menu')
  if ok then return module end
  return nil
end

local function player()
  return (world.players and world.players[1]) or nil
end

local function log(message)
  print('[idle-openmw/warden] ' .. tostring(message))
end

--- Bring the player back to full in every pool.
--- A respawn that restores only health would drop them straight back into a
--- fight with no fatigue to run on, which is how a "rescue" becomes a loop.
--- Writes are pcall-guarded: a pool we cannot touch must not abort the rescue.
local function restorePools(actor)
  for _, pool in ipairs({ 'health', 'magicka', 'fatigue' }) do
    pcall(function()
      local stat = types.Actor.stats.dynamic[pool](actor)
      if stat and type(stat.base) == 'number' and type(stat.current) == 'number' then
        stat.current = stat.base
      end
    end)
  end
end

--- Teleport the player back into the last settlement we were safe in, alive.
local function respawn(data)
  local actor = player()
  if not actor then return false, 'no player object' end
  local spot = data and data.safeSpot
  if not spot or not spot.position then return false, 'no safe spot remembered yet' end

  -- If teleporting is disabled for this player the call would silently do
  -- nothing, so permit it first.
  pcall(function() types.PLAYER.setTeleportingEnabled(actor, true) end)

  local position = util.vector3(
    spot.position.x or 0, spot.position.y or 0, spot.position.z or 0)

  -- '' means the default exterior worldspace. Deliberately NOT a stored Cell
  -- reference: Cell handles go stale across save/load, and a settlement is an
  -- exterior, so the engine picking the cell from `position` is both simpler and
  -- more robust. See §10 for why this is the right call.
  local cellOrName = spot.cellName or ''
  actor:teleport(cellOrName, position, { onGround = true })

  restorePools(actor)
  return true, spot.name
end

--- Load a save slot. Used only when guardian.onDeath == 'reload'.
local function reload(data)
  local menu = menuModule()
  if not menu then
    return false, 'openmw.menu is not available in this script context'
  end
  local dir = data and data.saveDir
  if not dir then
    local ok, current = pcall(function() return menu.getCurrentSaveDir() end)
    if ok then dir = current end
  end
  local slot = data and data.saveSlot
  if not dir then return false, 'no save directory known' end
  if not slot then return false, 'guardian.saveSlot is not configured' end
  menu.loadGame(dir, slot)
  return true, slot
end

local eventHandlers = {}

-- Sent by idleDirector.lua when guardian.assess() returns a global-only action.
eventHandlers['IdleOpenMW_Guardian'] = function(data)
  local action = data and data.action
  local ok, detail

  if action == 'respawn' then
    ok, detail = respawn(data)
  elseif action == 'reload' then
    ok, detail = reload(data)
  else
    -- 'heal' and 'retreat' are handled in the player script, which can write its
    -- own stats. Anything else is a bug, and silence would hide it.
    log('ignoring unsupported action: ' .. tostring(action))
    return
  end

  if ok then
    log(('%s applied %s'):format(action, detail and ('(' .. tostring(detail) .. ')') or ''))
  else
    log(('%s failed: %s'):format(tostring(action), tostring(detail)))
  end

  -- Tell the player script, so it can drop its fight/flee state and start
  -- planning again from the new position rather than from a stale one.
  core.sendGlobalEvent('IdleOpenMW_GuardianApplied', {
    action = action,
    ok = ok and true or false,
    detail = detail,
  })
end

return { eventHandlers = eventHandlers }
