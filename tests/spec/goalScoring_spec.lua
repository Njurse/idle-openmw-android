describe('idle.goalScoring', function()
  local gs = require('scripts.idle.goalScoring')
  local sc = require('scripts.idle.statCrunch')
  local cp = require('scripts.idle.classPriorities')
  local configMod = require('scripts.idle.config')
  local classes = require('tests.fixtures.classes')
  local states = require('tests.fixtures.states')
  local worlds = require('tests.fixtures.worlds')

  local cfg = configMod.new()

  local function choose(state, classDef, world)
    local view = sc.compute(state, classDef)
    local weights = cp.buildWeights(classDef)
    return gs.select(view, weights, world, cfg)
  end

  it('chooses survive when health is critical', function()
    local state = states.warrior({ health = { current = 5, base = 120, max = 120 } })
    assert.equals(choose(state, classes.warrior, worlds.town()), 'survive')
  end)

  it('does not choose survive while healthy', function()
    local state = states.warrior()
    local chosen = choose(state, classes.warrior, worlds.town())
    assert.not_equals(chosen, 'survive')
  end)

  it('flees a fight it cannot win', function()
    assert.equals(choose(states.warrior(), classes.warrior, worlds.dangerous()), 'flee')
  end)

  it('engages a fight it can win', function()
    assert.equals(choose(states.warrior(), classes.warrior, worlds.wilderness()), 'fight')
  end)

  it('rests when exhausted', function()
    local state = states.warrior({ fatigue = { current = 8, base = 140, max = 140 } })
    assert.equals(choose(state, classes.warrior, worlds.withOnly('rest')), 'rest')
  end)

  it('trains when wealthy and a trainer is near', function()
    local state = states.warrior({ gold = 800 })
    -- withOnly('trainer') also means shop/healing are absent
    local world = worlds.withOnly('trainer')
    assert.equals(choose(state, classes.warrior, world), 'train')
  end)

  it('does not train without enough gold', function()
    local state = states.warrior({ gold = 10 })
    local chosen = choose(state, classes.warrior, worlds.withOnly('trainer'))
    assert.not_equals(chosen, 'train')
  end)

  it('sells junk before shopping when the bag is full of loot', function()
    assert.equals(choose(states.warrior(), classes.warrior, worlds.merchantTrip()), 'sell_junk')
  end)

  it('shops when encumbered but holding nothing valuable', function()
    local state = states.warrior({ encumbrance = { current = 240, max = 250 } })
    assert.equals(choose(state, classes.warrior, worlds.withOnly('shop')), 'shop')
  end)

  it('falls back to idle when there is nothing to do', function()
    assert.equals(choose(states.warrior(), classes.warrior, worlds.empty()), 'idle')
  end)

  it('ranks everything in descending score order', function()
    local view = sc.compute(states.warrior(), classes.warrior)
    local weights = cp.buildWeights(classes.warrior)
    local ranked = gs.rank(view, weights, worlds.town(), cfg)
    assert.equals(#ranked, #gs.GOALS)
    for i = 2, #ranked do
      assert.is_true(ranked[i - 1].score >= ranked[i].score)
    end
  end)

  it('returns a full score row for the chosen goal', function()
    local _, _, row = choose(states.warrior(), classes.warrior, worlds.town())
    assert.is_not_nil(row.id)
    assert.is_true(row.score >= 0)
    assert.is_true(row.need >= 0 and row.need <= 1)
    assert.is_true(row.opportunity >= 0 and row.opportunity <= 1)
  end)

  it('penalises risky goals through the risk term', function()
    local view = sc.compute(states.warrior(), classes.warrior)
    local weights = cp.buildWeights(classes.warrior)
    local safe = gs.rank(view, weights, worlds.withOnly('unexplored', { enemies = 1, danger = 0.05 }), cfg)
    local unsafe = gs.rank(view, weights, worlds.withOnly('unexplored', { enemies = 1, danger = 0.95 }), cfg)
    local function fightScore(rows)
      for _, r in ipairs(rows) do if r.id == 'fight' then return r.score end end
    end
    assert.is_true(fightScore(unsafe) < fightScore(safe))
    assert.is_true(fightScore(unsafe) < 0)
  end)

  it('couples preference and capability in aptitude', function()
    local warriorGoal = gs.get('fight')
    local shopGoal = gs.get('shop')
    local wWeights = cp.buildWeights(classes.warrior)
    local wCap = sc.compute(states.warrior(), classes.warrior).capability
    assert.is_true(gs.aptitude(warriorGoal, wWeights, wCap) > gs.aptitude(shopGoal, wWeights, wCap))

    local mWeights = cp.buildWeights(classes.mage)
    local mCap = sc.compute(states.mage(), classes.mage).capability
    local mageMagic = gs.aptitude(gs.get('heal'), mWeights, mCap)
    local warriorMagic = gs.aptitude(gs.get('heal'), wWeights, wCap)
    assert.is_true(mageMagic > warriorMagic)
  end)

  it('treats a category-less goal as neutral aptitude', function()
    assert.equals(gs.aptitude(gs.get('idle'), { combat = 5 }, { combat = 0.1 }), 1.0)
  end)

  it('lets a caller register a custom goal', function()
    local before = #gs.ids()
    gs.register({ id = 'test_goal', categories = {}, need = function() return 1 end,
                  opportunity = function() return 1 end })
    assert.is_not_nil(gs.get('test_goal'))
    assert.equals(#gs.ids(), before + 1)
    -- remove it again so it cannot leak into other specs
    for i, g in ipairs(gs.GOALS) do
      if g.id == 'test_goal' then table.remove(gs.GOALS, i) break end
    end
    assert.is_nil(gs.get('test_goal'))
    assert.equals(#gs.ids(), before)
  end)

  it('is deterministic across repeated calls', function()
    local view = sc.compute(states.warrior(), classes.warrior)
    local weights = cp.buildWeights(classes.warrior)
    local a = gs.rank(view, weights, worlds.town(), cfg)
    local b = gs.rank(view, weights, worlds.town(), cfg)
    for i = 1, #a do assert.equals(a[i].id, b[i].id) end
  end)
end)
