-- tests/spec/guardian_spec.lua
-- "Don't let them die at work." The policy is pure, so it is testable even
-- though the actions (teleport, loadGame) need a global script.
describe('idle.guardian', function()
  local guardian = require('scripts.idle.guardian')
  local configMod = require('scripts.idle.config')

  local cfg = configMod.new()

  local function state(over)
    local s = { health = 100, healthMax = 100, danger = 0, sinceIntervention = 9999 }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
  end

  describe('healthFraction', function()
    it('computes a 0..1 fraction', function()
      assert.equals(guardian.healthFraction(state({ health = 50, healthMax = 100 })), 0.5)
      assert.equals(guardian.healthFraction(state({ health = 0 })), 0)
      assert.equals(guardian.healthFraction(state({ health = 100 })), 1)
    end)

    it('returns nil when it cannot be known', function()
      assert.is_nil(guardian.healthFraction(nil))
      assert.is_nil(guardian.healthFraction({}))
      assert.is_nil(guardian.healthFraction({ health = 10, healthMax = 0 }))
      assert.is_nil(guardian.healthFraction({ health = 10, healthMax = nil }))
    end)
  end)

  describe('assess while alive', function()
    it('does nothing when healthy', function()
      local action, reason = guardian.assess(state(), cfg)
      assert.equals(action, 'none')
      assert.equals(reason, 'fine')
    end)

    it('tops up health before it can reach zero', function()
      local action = guardian.assess(state({ health = 10 }), cfg)   -- 10% < 15%
      assert.equals(action, 'heal')
    end)

    it('retreats when hurt and in danger, without cheating', function()
      local action = guardian.assess(state({ health = 30, danger = 0.8 }), cfg)
      assert.equals(action, 'retreat')
    end)

    it('does not retreat when hurt but nothing is threatening', function()
      local action = guardian.assess(state({ health = 30, danger = 0 }), cfg)
      assert.equals(action, 'none')
    end)

    it('can be told not to cheat death', function()
      local honest = configMod.new({ guardian = { preventDeath = false } })
      assert.equals(guardian.assess(state({ health = 1 }), honest), 'none')
      -- but it will still get them out of trouble
      assert.equals(guardian.assess(state({ health = 20, danger = 1 }), honest), 'retreat')
    end)

    it('respects the cooldown so it cannot thrash', function()
      local action, reason = guardian.assess(state({ health = 1, sinceIntervention = 0 }), cfg)
      assert.equals(action, 'none')
      assert.equals(reason, 'cooling down')
    end)

    it('does nothing at all when disabled', function()
      local off = configMod.new({ guardian = { enabled = false } })
      assert.equals(guardian.assess(state({ health = 1 }), off), 'none')
      assert.equals(guardian.assess(state({ dead = true, hasSafeSpot = true }), off), 'none')
    end)
  end)

  describe('assess after death', function()
    it('respawns at the last settlement by default', function()
      local action, reason = guardian.assess(state({ dead = true, hasSafeSpot = true }), cfg)
      assert.equals(action, 'respawn')
      assert.is_true(reason:find('respawning') ~= nil)
    end)

    it('will not respawn with nowhere to go', function()
      local action = guardian.assess(state({ dead = true, hasSafeSpot = false }), cfg)
      assert.equals(action, 'none')
    end)

    it('reloads a save when configured to, and a slot exists', function()
      local reloader = configMod.new({ guardian = { onDeath = 'reload' } })
      local action = guardian.assess(state({ dead = true, hasSave = true, hasSafeSpot = true }), reloader)
      assert.equals(action, 'reload')
    end)

    it('falls back to respawning when a reload was asked for but impossible', function()
      -- honest degradation: a configured action we cannot perform must not leave
      -- the player dead
      local reloader = configMod.new({ guardian = { onDeath = 'reload' } })
      local action = guardian.assess(state({ dead = true, hasSave = false, hasSafeSpot = true }), reloader)
      assert.equals(action, 'respawn')
    end)

    it('reports when it can do nothing at all', function()
      local none = configMod.new({ guardian = { onDeath = 'none' } })
      assert.equals(guardian.assess(state({ dead = true, hasSafeSpot = true }), none), 'none')
      local reloader = configMod.new({ guardian = { onDeath = 'reload' } })
      assert.equals(guardian.assess(state({ dead = true }), reloader), 'none')
    end)

    it('ignores the cooldown when dead', function()
      -- a cooldown must never strand a dead player
      local action = guardian.assess(state({ dead = true, hasSafeSpot = true, sinceIntervention = 0 }), cfg)
      assert.equals(action, 'respawn')
    end)
  end)

  describe('healTarget', function()
    it('aims for the configured fraction', function()
      assert.equals(guardian.healTarget(state({ health = 10 }), cfg), 75)   -- healTo 0.75
    end)

    it('returns nil when already above the target', function()
      assert.is_nil(guardian.healTarget(state({ health = 90 }), cfg))
    end)

    it('returns nil without a usable maximum', function()
      assert.is_nil(guardian.healTarget({ health = 1, healthMax = 0 }, cfg))
      assert.is_nil(guardian.healTarget(nil, cfg))
    end)
  end)

  describe('worthRemembering', function()
    it('remembers a settlement only while healthy', function()
      assert.is_true(guardian.worthRemembering(true, state({ health = 100 }), cfg))
      assert.is_false(guardian.worthRemembering(true, state({ health = 20 }), cfg))
    end)

    it('never remembers wilderness', function()
      assert.is_false(guardian.worthRemembering(false, state({ health = 100 }), cfg))
      assert.is_false(guardian.worthRemembering(nil, state({ health = 100 }), cfg))
    end)
  end)

  describe('notificationFor', function()
    it('describes a respawn and a reload', function()
      local kind, title, detail = guardian.notificationFor('respawn', 'Balmora')
      assert.equals(kind, 'death')
      assert.is_true(detail:find('Balmora', 1, true) ~= nil)

      local reloadKind = guardian.notificationFor('reload')
      assert.equals(reloadKind, 'death')
    end)

    it('says nothing for actions not worth interrupting for', function()
      assert.is_nil(guardian.notificationFor('none'))
      assert.is_nil(guardian.notificationFor('retreat'))
    end)
  end)
end)
