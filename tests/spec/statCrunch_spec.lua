describe('idle.statCrunch', function()
  local sc = require('scripts.idle.statCrunch')
  local classes = require('tests.fixtures.classes')
  local states = require('tests.fixtures.states')

  it('makes a warrior combat-capable', function()
    local s = sc.compute(states.warrior(), classes.warrior)
    assert.is_true(s.capability.combat > s.capability.magic)
    assert.is_true(s.capability.combat > s.capability.stealth)
  end)

  it('makes a mage magic-capable', function()
    local s = sc.compute(states.mage(), classes.mage)
    assert.equals((sc.topSkills(states.mage(), 1))[1].id, 'destruction')
    assert.is_true(s.capability.magic > s.capability.combat)
  end)

  it('reports resource fractions', function()
    local state = states.warrior({ health = { current = 30, base = 120, max = 120 } })
    local s = sc.compute(state, classes.warrior)
    expect(s.healthFraction):toBeCloseTo(0.25, 1e-9)
    expect(s.magickaFraction):toBeCloseTo(1.0, 1e-9)
  end)

  it('assumes full pools when a resource is missing', function()
    local s = sc.compute({ skills = {} }, classes.blank)
    expect(s.healthFraction):toBeCloseTo(1.0, 1e-9)
    expect(s.fatigueFraction):toBeCloseTo(1.0, 1e-9)
  end)

  it('clamps over-capacity encumbrance to 1', function()
    local state = states.warrior({ encumbrance = { current = 400, max = 250 } })
    expect(sc.encumbranceFraction(state)):toBeCloseTo(1.0, 1e-9)
    local light = states.warrior({ encumbrance = { current = 125, max = 250 } })
    expect(sc.encumbranceFraction(light)):toBeCloseTo(0.5, 1e-9)
  end)

  it('treats a number as a stat entry too', function()
    assert.equals(sc.readStat(42, 0), 42)
    assert.equals(sc.readStat({ modified = 10, base = 5 }, 0), 10)
    assert.equals(sc.readStat({ base = 7 }, 0), 7)
    assert.equals(sc.readStat(nil, 3), 3)
  end)

  it('sorts the top skills descending, breaking ties by id', function()
    local state = states.state({ skills = states.skills({ block = 40, longblade = 70, axe = 40 }) })
    local top = sc.topSkills(state, 3)
    assert.equals(top[1].id, 'longblade')
    assert.equals(top[1].value, 70)
    assert.equals(top[2].id, 'axe')  -- tie on 40, alphabetical
    assert.equals(top[3].id, 'block')
  end)

  it('blends health and magic into survivability', function()
    local healthy = sc.compute(states.mage(), classes.mage)
    local dying = sc.compute(states.mage({ health = { current = 1, base = 70, max = 70 } }), classes.mage)
    assert.is_true(dying.survivability < healthy.survivability)
  end)

  it('reports level and average skill', function()
    local s = sc.compute(states.warrior(), classes.warrior)
    assert.equals(s.level, 5)
    assert.is_true(s.averageSkill > 0)
    assert.is_true(s.skillTotal > 0)
  end)

  it('never returns NaN for an empty snapshot', function()
    local s = sc.compute({}, classes.blank)
    for _, cat in ipairs(require('scripts.idle.classPriorities').CATEGORIES) do
      local v = s.capability[cat]
      assert.is_true(v == v and v >= 0 and v <= 1)
    end
  end)
end)
