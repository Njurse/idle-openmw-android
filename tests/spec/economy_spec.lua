describe('idle.economy', function()
  local economy = require('scripts.idle.economy')
  local configMod = require('scripts.idle.config')

  local cfg = configMod.new()

  local inventory = {
    { id = 'longsword', count = 1, value = 100, weight = 15, equipped = true },
    { id = 'chitin dagger', count = 5, value = 8, weight = 4 },
    { id = 'heavy cuirass', count = 1, value = 300, weight = 40 },
    { id = 'silver staff', count = 1, value = 200, weight = 10 },
    { id = 'potion of healing', count = 3, value = 25, weight = 0.5 },
    { id = 'propylon index', count = 1, value = 0, weight = 1, quest = true },
  }

  it('computes value per weight, treating weightless items as precious', function()
    expect(economy.valuePerWeight({ value = 20, weight = 4 })):toBeCloseTo(5, 1e-9)
    assert.equals(economy.valuePerWeight({ value = 20, weight = 0 }), math.huge)
  end)

  it('never treats equipped or quest items as junk', function()
    assert.is_false(economy.isJunk(inventory[1], cfg))
    assert.is_false(economy.isJunk(inventory[6], cfg))
  end)

  it('classifies by value-per-weight and duplicates', function()
    assert.is_true(economy.isJunk(inventory[2], cfg))  -- 2.0 gold/weight
    assert.is_true(economy.isJunk(inventory[3], cfg))  -- 7.5 gold/weight
    assert.is_false(economy.isJunk(inventory[4], cfg)) -- 20 gold/weight, at threshold
    assert.is_false(economy.isJunk(inventory[5], cfg)) -- 50 gold/weight potions
    -- a large stack of mediocre items is junk even above the ratio threshold
    assert.is_true(economy.isJunk({ id = 'iron arrow', count = 30, value = 30, weight = 1 }, cfg))
  end)

  it('totals the gross value of junk', function()
    assert.equals(economy.junkValue(inventory, cfg), 8 * 5 + 300)
  end)

  it('orders the sell plan richest-first', function()
    local plan = economy.planSales(inventory, cfg)
    assert.equals(#plan, 2)
    assert.equals(plan[1].id, 'heavy cuirass')
    assert.equals(plan[1].totalValue, 300)
    assert.equals(plan[2].id, 'chitin dagger')
    assert.equals(plan[2].totalValue, 40)
  end)

  it('discounts expected gold by the barter ratio', function()
    local plan = economy.planSales(inventory, cfg)
    assert.equals(economy.expectedGold(plan, 0.8), math.floor(340 * 0.8))
    assert.equals(economy.expectedGold(plan, 1.0), 340)
  end)

  it('buys in priority order within budget and reserve', function()
    local desired = {
      { id = 'cure potion', count = 3, priority = 2 },
      { id = 'lockpick', count = 10, priority = 1 },
    }
    local stock = {
      ['cure potion'] = { value = 50, count = 5 },
      lockpick = { value = 5, count = 20 },
    }
    local plan, goldLeft = economy.planPurchases(desired, stock, 1000, cfg)
    assert.equals(#plan, 2)
    assert.equals(plan[1].id, 'cure potion')
    assert.equals(plan[1].count, 3)
    assert.equals(plan[2].count, 10)
    assert.equals(goldLeft, 1000 - (3 * 50) - (10 * 5))
  end)

  it('respects the gold reserve and stock limits', function()
    local desired = {
      { id = 'cure potion', count = 3, priority = 2 },
      { id = 'lockpick', count = 10, priority = 1 },
    }
    local stock = {
      ['cure potion'] = { value = 50, count = 5 },
      lockpick = { value = 5, count = 20 },
    }
    -- only 20 gold of spendable budget (120 - 100 reserve)
    local plan = economy.planPurchases(desired, stock, 120, cfg)
    assert.equals(#plan, 1)
    assert.equals(plan[1].id, 'lockpick')
    assert.equals(plan[1].count, 4)
  end)

  it('summarizes an inventory', function()
    local summary = economy.summarize(inventory, cfg)
    assert.equals(summary.junkValue, 340)
    assert.equals(summary.junkCount, 2)
    assert.equals(summary.itemCount, 1 + 5 + 1 + 1 + 3 + 1)
    assert.is_true(summary.totalValue > 0)
  end)
end)
