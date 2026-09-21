describe('idle.config', function()
  local config = require('scripts.idle.config')

  it('provides a fresh copy of the defaults each time', function()
    local a = config.new()
    a.tick.interval = 99
    assert.equals(config.defaults.tick.interval, 2.0)
    assert.equals(config.new().tick.interval, 2.0)
  end)

  it('deep-merges overrides without dropping sibling defaults', function()
    local cfg = config.new({ tick = { interval = 3.5 } })
    assert.equals(cfg.tick.interval, 3.5)
    assert.equals(cfg.tick.logLimit, config.defaults.tick.logLimit)
    assert.is_not_nil(cfg.offline)
    assert.equals(cfg.offline.maxRealHours, config.defaults.offline.maxRealHours)
  end)

  it('passes a clean default config with no problems', function()
    local _, problems = config.validate(config.new())
    assert.equals(#problems, 0)
  end)

  it('clamps out-of-range values and reports them', function()
    local cfg = config.new({ tick = { interval = 1e9 }, offline = { maxRealHours = 9999 } })
    cfg.thresholds.criticalHealth = 5
    local _, problems = config.validate(cfg)
    assert.equals(cfg.tick.interval, 60)
    assert.equals(cfg.offline.maxRealHours, 24 * 7)
    assert.equals(cfg.thresholds.criticalHealth, 1)
    assert.is_true(#problems >= 3)
  end)

  describe('sensing', function()
    it('ships a safe default: creatures are enemies, NPCs are not', function()
      local cfg = config.new()
      assert.is_true(cfg.sensing.creaturesAreHostile)
      assert.is_false(cfg.sensing.npcFightHostility)
      assert.is_false(cfg.behaviour.autoTravel)
      assert.equals(#cfg.sensing.ignoreRecords, 0)
      local _, problems = config.validate(cfg)
      assert.equals(#problems, 0)
    end)

    it('clamps sensing ranges into sane bounds', function()
      local cfg = config.new({
        sensing = { scanRadius = 10, hostileFightThreshold = 900, questingWeight = 9 },
      })
      local _, problems = config.validate(cfg)
      assert.equals(cfg.sensing.scanRadius, 128)
      assert.equals(cfg.sensing.hostileFightThreshold, 100)
      assert.equals(cfg.sensing.questingWeight, 1)
      assert.is_true(#problems >= 3)
    end)
  end)

  describe('overridesOf', function()
    it('is empty for an untouched config', function()
      assert.equals(next(config.overridesOf(config.new())), nil)
    end)

    it('captures only what changed', function()
      local cfg = config.new()
      cfg.sensing.npcFightHostility = true
      cfg.ui.refresh = 2.0
      local overrides = config.overridesOf(cfg)
      expect(overrides):toEqualDeep({ sensing = { npcFightHostility = true },
                                      ui = { refresh = 2.0 } })
    end)

    it('round-trips: new(overridesOf(cfg)) reproduces the changed values', function()
      local cfg = config.new()
      cfg.sensing.creaturesAreHostile = false
      cfg.behaviour.autoTravel = true
      cfg.behaviour.barterRatio = 0.5
      cfg.tick.interval = 4

      local restored = config.new(config.overridesOf(cfg))
      assert.is_false(restored.sensing.creaturesAreHostile)
      assert.is_true(restored.behaviour.autoTravel)
      assert.equals(restored.behaviour.barterRatio, 0.5)
      assert.equals(restored.tick.interval, 4)
      -- and the untouched defaults are still the defaults
      assert.equals(restored.behaviour.simulateActions, config.defaults.behaviour.simulateActions)
    end)

    it('survives a nil or junk config', function()
      assert.equals(next(config.overridesOf(nil)), nil)
      assert.equals(next(config.overridesOf(42)), nil)
    end)
  end)

  it('rejects non-numeric weight overrides', function()    local cfg = config.new({ weightOverrides = { combat = 'lots' } })
    local _, problems = config.validate(cfg)
    assert.is_true(#problems >= 1)
    assert.equals(cfg.weightOverrides.combat, 1.0)
  end)

  it('survives a non-table config', function()
    local cfg, problems = config.validate('nonsense')
    assert.is_table(cfg)
    assert.equals(#problems, 1)
    assert.equals(cfg.tick.interval, 2.0)
  end)
end)
