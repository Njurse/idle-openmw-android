describe('idle.offlineProgress', function()
  local offline = require('scripts.idle.offlineProgress')
  local configMod = require('scripts.idle.config')

  local cfg = configMod.new()

  it('does not apply for a trivial absence', function()
    assert.is_false(offline.shouldApply(30, cfg))
    local award = offline.compute(30, cfg)
    assert.is_false(award.applied)
    assert.equals(award.gold, 0)
  end)

  it('does not apply when disabled', function()
    local disabled = configMod.new({ offline = { enabled = false } })
    assert.is_false(offline.shouldApply(3600, disabled))
    assert.is_false(offline.compute(3600, disabled).applied)
  end)

  it('awards gold for elapsed real time', function()
    local award = offline.compute(2 * 3600, cfg)
    assert.is_true(award.applied)
    -- 2 real hours -> 120 real minutes -> 120 game hours * 10 gold * 0.85 occupancy
    local expectedGameHours = 120 * cfg.offline.gameHoursPerRealMinute * cfg.offline.riskOccupancy
    expect(award.gameHours):toBeCloseTo(expectedGameHours, 1e-6)
    assert.equals(award.gold, math.floor(expectedGameHours * cfg.offline.goldPerGameHour))
    assert.is_true(award.skillProgress > 0)
  end)

  it('caps the catch-up window', function()
    local award = offline.compute(100 * 3600, cfg)
    assert.is_true(award.capped)
    assert.equals(award.effectiveSeconds, cfg.offline.maxRealHours * 3600)
    local capped = offline.compute(cfg.offline.maxRealHours * 3600, cfg)
    assert.equals(award.gold, capped.gold)
    assert.is_false(capped.capped)
  end)

  it('applies to a stored state without mutating the input', function()
    local stored = { gold = 100, totalOfflineGold = 0 }
    local updated, award = offline.apply(stored, 2 * 3600, cfg)
    assert.equals(stored.gold, 100)
    assert.is_true(updated.gold > stored.gold)
    assert.equals(updated.gold, stored.gold + award.gold)
    assert.equals(updated.totalOfflineGold, award.gold)
  end)

  it('derives elapsed seconds from lastSeen', function()
    local stored = { lastSeen = 1000 }
    assert.equals(offline.elapsedFromLastSeen(stored, 8200), 7200)
    assert.equals(offline.elapsedFromLastSeen(stored, 500), 0)
    assert.equals(offline.elapsedFromLastSeen({}, 8200), 0)
    local updated = offline.applySince({ gold = 0, lastSeen = 1000 }, 8200, cfg)
    assert.is_true(updated.gold > 0)
  end)

  it('describes the award in human terms', function()
    local award = offline.compute(2 * 3600, cfg)
    assert.is_true(offline.describe(award):find('2h 00m', 1, true) ~= nil)
    assert.is_true(offline.describe(award):find('gold', 1, true) ~= nil)
    local capped = offline.compute(100 * 3600, cfg)
    assert.is_true(offline.describe(capped):find('capped', 1, true) ~= nil)
  end)
end)
