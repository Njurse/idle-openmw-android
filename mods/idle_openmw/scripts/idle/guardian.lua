-- scripts/idle/guardian.lua
-- "Don't let them die at work."
--
-- For set-and-forget idling, dying is the worst outcome: the engine drops to the
-- load menu and the run is over until someone notices. So this module decides
-- when to intervene, and it is deliberately a pure function of a few numbers, so
-- the *policy* is testable even though the *actions* need the engine.
--
-- Verified API facts behind the action set (docs/openmw-lua-api.md §10):
--   * `Actor.isDead(actor)` / `isDeathFinished(actor)` -- death is observable
--   * `GameObject:teleport(cellOrName, position, options)` -- **global scripts
--     only**, so respawning cannot be done from our PLAYER scripts
--   * `menu.loadGame(dir, slot)` -- global only; the "reload the save" option
--   * `world.players[1]` -- how a global script reaches the player
--
-- Two defences, in order:
--   1. PREVENT -- top the player's health up before it can reach zero. Crude, but
--      it is the only thing that reliably keeps an unattended run alive.
--   2. RECOVER -- if death happens anyway (a one-shot), respawn them at the last
--      settlement we were safe in, or reload a save, or do nothing. Player's call.

local M = {}

M.ACTION = {
  none = 'none',
  heal = 'heal',        -- top up health now
  retreat = 'retreat',  -- not hurt enough to intervene, but get them out
  respawn = 'respawn',  -- teleport to a remembered safe spot and revive
  reload = 'reload',    -- load a save slot
}

M.ON_DEATH = { respawn = 'respawn', reload = 'reload', none = 'none' }

local function number(value, fallback)
  if type(value) == 'number' then return value end
  return fallback
end

--- The player's health as a 0..1 fraction, or nil when it cannot be known.
function M.healthFraction(state)
  local max = number(state and state.healthMax, nil)
  local current = number(state and state.health, nil)
  if not max or max <= 0 or not current then return nil end
  return current / max
end

--- What should we do about this player, right now?
---
--- @param state {
---   dead?, health?, healthMax?, danger?,
---   hasSafeSpot?,   -- do we know a settlement to respawn in?
---   hasSave?,       -- is a save slot configured for reloading?
---   sinceIntervention? -- sim seconds since we last acted
--- }
--- @return action, reason
function M.assess(state, cfg)
  state = state or {}
  local settings = (cfg and cfg.guardian) or {}

  if settings.enabled == false then
    return M.ACTION.none, 'guardian disabled'
  end

  -- Death first, and deliberately BEFORE the cooldown: a cooldown that can
  -- strand a dead player would be a bug, not a feature (the spec caught this).
  if state.dead then
    local onDeath = M.ON_DEATH[settings.onDeath] or M.ON_DEATH.none
    if onDeath == M.ON_DEATH.reload then
      if state.hasSave then return M.ACTION.reload, 'died; reloading the save' end
      -- fall through: a configured reload we cannot perform should still recover
      if state.hasSafeSpot then
        return M.ACTION.respawn, 'died; no save slot, respawning instead'
      end
      return M.ACTION.none, 'died; no save slot and nowhere known to respawn'
    end
    if onDeath == M.ON_DEATH.respawn then
      if state.hasSafeSpot then return M.ACTION.respawn, 'died; respawning at the last settlement' end
      return M.ACTION.none, 'died; no settlement to respawn in yet'
    end
    return M.ACTION.none, 'died; recovery disabled'
  end

  -- Don't thrash: one alive-side intervention per cooldown window.
  local cooldown = number(settings.cooldown, 30)
  if number(state.sinceIntervention, math.huge) < cooldown then
    return M.ACTION.none, 'cooling down'
  end

  local fraction = M.healthFraction(state)
  if not fraction then return M.ACTION.none, 'health unknown' end

  if settings.preventDeath ~= false
     and fraction <= number(settings.criticalHealthFraction, 0.15) then
    return M.ACTION.heal, ('health at %.0f%%'):format(fraction * 100)
  end

  if fraction <= number(settings.retreatHealthFraction, 0.35)
     and number(state.danger, 0) > 0 then
    return M.ACTION.retreat, ('health at %.0f%% and in danger'):format(fraction * 100)
  end

  return M.ACTION.none, 'fine'
end

--- How much health to restore, given the target fraction.
--- Returns an absolute value to write to the pool, or nil if nothing to do.
function M.healTarget(state, cfg)
  local settings = (cfg and cfg.guardian) or {}
  local max = number(state and state.healthMax, nil)
  if not max or max <= 0 then return nil end
  local target = math.floor(max * number(settings.healTo, 0.75))
  local current = number(state and state.health, 0)
  if target <= current then return nil end
  return target
end

--- Should we remember this spot as somewhere safe to come back to?
--- A settlement, while healthy. Called as we walk around, so the memory is
--- "the last place we were fine", which is a fair stand-in for "nearest town"
--- (we cannot route to a town we have never seen).
--- @param isSettlement boolean -- already decided by scripts/idle/settlement.lua
function M.worthRemembering(isSettlement, state, cfg)
  local settings = (cfg and cfg.guardian) or {}
  if settings.enabled == false then return false end
  if not isSettlement then return false end
  local fraction = M.healthFraction(state)
  if not fraction then return false end
  return fraction >= number(settings.safeHealthFraction, 0.6)
end

--- Is this failure worth telling the player about?
function M.notificationFor(action, name)
  if action == M.ACTION.respawn then
    return 'death', 'Recovered', ('died; respawned in %s'):format(name or 'the last settlement')
  end
  if action == M.ACTION.reload then
    return 'death', 'Recovered', 'died; reloaded the last save'
  end
  if action == M.ACTION.heal then
    return 'danger', 'Badly hurt', 'topped up health to avoid dying'
  end
  return nil
end

return M
