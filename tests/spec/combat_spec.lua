describe('idle.combat', function()
  local combat = require('scripts.idle.combat')
  local configMod = require('scripts.idle.config')
  local cp = require('scripts.idle.classPriorities')
  local sc = require('scripts.idle.statCrunch')
  local classes = require('tests.fixtures.classes')
  local states = require('tests.fixtures.states')

  local cfg = configMod.new()

  it('rates one enemy by level', function()
    assert.equals(combat.threatOf({ level = 5 }), 0.5)
    assert.equals(combat.threatOf({ level = 20 }), 2.0)
    assert.equals(combat.threatOf({ threat = 1, count = 3 }), 3.0)  -- clamped
    assert.equals(combat.threatOf({ level = 1 }), 0.1)
  end)

  it('derives fighting power from capability', function()
    local warrior = sc.compute(states.warrior(), classes.warrior).capability
    local mage = sc.compute(states.mage(), classes.mage).capability
    assert.is_true(combat.power(warrior) > 0)
    assert.is_true(combat.power(warrior) > combat.power(mage) - 0.001)
    assert.is_true(combat.power({}) > 0) -- baseline floor
  end)

  it('calls an empty field safe', function()
    local a = combat.assess({}, sc.compute(states.warrior(), classes.warrior).capability, cfg)
    assert.equals(a.danger, 0)
    assert.equals(a.verdict, 'safe')
    assert.equals(a.count, 0)
  end)

  it('scales danger with numbers and enemy level', function()
    local cap = sc.compute(states.warrior(), classes.warrior).capability
    local one = combat.assess({ { level = 2 } }, cap, cfg)
    local mob = combat.assess({ { level = 20 }, { level = 20 }, { level = 20 } }, cap, cfg)
    assert.is_true(one.danger < mob.danger)
    assert.equals(one.count, 1)
    assert.equals(mob.count, 3)
  end)

  it('weighs danger by PROXIMITY, not mere presence in the scan radius', function()
    -- Measured live: 25 slaughterfish across the bay produced `danger 1.00` and a permanent
    -- `flee` in a quiet Seyda Neen. A threat you cannot reach is not a threat you are in.
    local cap = sc.compute(states.warrior(), classes.warrior).capability
    local fish = {}
    for index = 1, 25 do fish[index] = { level = 1, distance = 3000 } end

    local far = combat.assess(fish, cap, cfg)
    assert.equals(far.danger, 0)
    assert.equals(far.verdict, 'safe')
    assert.equals(far.threats, 0)
    assert.equals(far.count, 25) -- still REPORTED, just not feared

    -- the same creep at your feet is a real threat
    local near = combat.assess({ { level = 1, distance = 100 } }, cap, cfg)
    assert.is_true(near.danger > 0)
    assert.equals(near.threats, 1)

    -- and an unknown distance keeps full weight, so this cannot silently make danger vanish
    local unknown = combat.assess({ { level = 1 } }, cap, cfg)
    assert.is_true(unknown.danger > 0)
    assert.equals(unknown.threats, 1)
  end)

  it('tapers threat to nothing at the configured radius', function()
    assert.equals(combat.proximityWeight(0, cfg), 1)
    assert.equals(combat.proximityWeight(cfg.sensing.dangerRadius, cfg), 0)
    assert.is_true(combat.proximityWeight(cfg.sensing.dangerRadius / 2, cfg) > 0)
    assert.is_true(combat.proximityWeight(cfg.sensing.dangerRadius / 2, cfg) < 1)
    assert.equals(combat.proximityWeight(99999, cfg), 0)
    assert.equals(combat.proximityWeight(nil, cfg), 1)
  end)

  it('verdicts follow the configured thresholds', function()
    local weak = sc.compute(states.warrior(), classes.warrior).capability
    local easy = combat.assess({ { level = 1 } }, weak, cfg)
    assert.equals(easy.verdict, 'engage')

    local doomed = combat.assess({ { level = 40 }, { level = 40 }, { level = 40 }, { level = 40 } }, weak, cfg)
    assert.equals(doomed.verdict, 'flee')
  end)

  it('gives warriors a more aggressive stance than mages', function()
    local warriorStance = combat.stanceFor(cp.buildWeights(classes.warrior))
    local mageStance = combat.stanceFor(cp.buildWeights(classes.mage))
    assert.is_true(warriorStance.aggression > mageStance.aggression)
    assert.is_true(warriorStance.engageUpTo > mageStance.engageUpTo)
  end)
end)
