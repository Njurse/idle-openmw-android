describe('idle.classPriorities', function()
  local cp = require('scripts.idle.classPriorities')
  local classes = require('tests.fixtures.classes')

  local function weights(classDef) return cp.buildWeights(classDef) end

  it('makes a warrior combat-dominant', function()
    local w = weights(classes.warrior)
    assert.is_true(w.combat > w.magic)
    assert.is_true(w.combat > w.stealth)
    assert.equals(cp.dominantCategory(w), 'combat')
  end)

  it('makes a mage magic-dominant', function()
    local w = weights(classes.mage)
    assert.is_true(w.magic > w.combat)
    assert.is_true(w.magic > w.stealth)
    assert.equals(cp.dominantCategory(w), 'magic')
  end)

  it('gives a thief a higher economy weight than a warrior', function()
    assert.is_true(weights(classes.thief).economy > weights(classes.warrior).economy)
  end)

  it('gives a thief more stealth than a mage', function()
    assert.is_true(weights(classes.thief).stealth > weights(classes.mage).stealth)
  end)

  it('gives a healer more social weight than a warrior', function()
    assert.is_true(weights(classes.healer).social > weights(classes.warrior).social)
  end)

  it('derives trade affinity for a merchant-ish hybrid', function()
    local peddler = weights(classes.peddler)
    assert.is_true(peddler.economy > weights(classes.warrior).economy)
    assert.is_true(peddler.social > weights(classes.warrior).social)
  end)

  it('keeps every weight positive and the mean near 1', function()
    for _, classDef in pairs(classes) do
      local w = weights(classDef)
      local total = 0
      for _, cat in ipairs(cp.CATEGORIES) do
        assert.is_true(w[cat] > 0)
        total = total + w[cat]
      end
      local mean = total / #cp.CATEGORIES
      assert.is_true(mean > 0.6 and mean < 1.6)
    end
  end)

  it('degrades gracefully for a class with no skills', function()
    local w = weights(classes.blank)
    for _, cat in ipairs(cp.CATEGORIES) do assert.is_true(w[cat] > 0) end
  end)

  it('ignores unknown skill ids without error', function()
    local w = weights({ specialization = 'combat', majorSkills = { 'notaskill', 'longblade' } })
    assert.is_true(w.combat > 0)
    assert.is_not_nil(w.magic)
  end)

  it('applies overrides multiplicatively and clamps them', function()
    local base = weights(classes.warrior)
    local boosted = cp.applyOverrides(base, { economy = 3.0 })
    expect(boosted.economy):toBeCloseTo(base.economy * 3.0, 1e-9)
    assert.equals(boosted.combat, base.combat)

    local negative = cp.applyOverrides(base, { combat = -5 })
    assert.equals(negative.combat, base.combat) -- invalid override ignored
  end)

  it('normalizes skill ids from display names', function()
    assert.equals(cp.normalizeSkillId('Long Blade'), 'longblade')
    assert.equals(cp.normalizeSkillId('Hand-to-hand'), 'handtohand')
    assert.equals(cp.normalizeSkillId('Blunt Weapon'), 'bluntweapon')
    assert.equals(cp.categoryOf('Sneak'), 'stealth')
    assert.equals(cp.categoryOf('Mysticism'), 'magic')
    assert.is_nil(cp.categoryOf('nonsense'))
  end)

  it('lists the skills in a category in sorted order', function()
    local combat = cp.skillsInCategory('combat')
    assert.is_true(#combat >= 10)
    assert.equals(combat[1], 'armorer')
  end)
end)
