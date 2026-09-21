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
