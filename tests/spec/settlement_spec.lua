-- tests/spec/settlement_spec.lua
-- "Are we in a town, and have we just arrived?" -- the basis of the
-- "tell me when they reach a settlement" loop.
describe('idle.settlement', function()
  local settlement = require('scripts.idle.settlement')
  local configMod = require('scripts.idle.config')

  local cfg = configMod.new()

  local function cell(name, isExterior)
    return { name = name, isExterior = isExterior ~= false }
  end

  describe('names', function()
    it('recognises region-style wilderness names', function()
      assert.is_true(settlement.isRegion('Ascadian Isles Region'))
      assert.is_true(settlement.isRegion('Bitter Coast Region'))
      assert.is_false(settlement.isRegion('Balmora'))
      assert.is_false(settlement.isRegion(nil))
    end)

    it('trims cell names and treats blanks as unnamed', function()
      assert.equals(settlement.name(cell('  Balmora  ')), 'Balmora')
      assert.is_nil(settlement.name(cell('   ')))
      assert.is_nil(settlement.name({}))
      assert.is_nil(settlement.name(nil))
    end)
  end)

  describe('classify', function()
    it('calls a named non-region exterior a settlement', function()
      assert.equals(settlement.classify(cell('Balmora'), { cfg = cfg }), 'settlement')
      assert.equals(settlement.classify(cell('Seyda Neen'), { cfg = cfg }), 'settlement')
    end)

    it('calls a region-named exterior wilderness', function()
      assert.equals(settlement.classify(cell('Ascadian Isles Region'), { cfg = cfg }), 'wilderness')
    end)

    it('calls an unnamed exterior wilderness unless there is a crowd', function()
      assert.equals(settlement.classify(cell(nil), { cfg = cfg }), 'wilderness')
      assert.equals(settlement.classify(cell(nil), { cfg = cfg, friendlyNearby = 5 }), 'settlement')
    end)

    it('calls a cell with isExterior=false an interior', function()
      assert.equals(settlement.classify({ isExterior = false, name = 'Arrille Tradehouse' },
        { cfg = cfg }), 'interior')
    end)

    it('honours an explicit wilderness override', function()
      -- the escape hatch for a named cell that is not really a town
      local corrected = configMod.new({ settlement = { wildernessNames = { 'Ald Daedroth' } } })
      assert.equals(settlement.classify(cell('Ald Daedroth'), { cfg = corrected }), 'wilderness')
      -- and the default config does not know about it
      assert.equals(settlement.classify(cell('Ald Daedroth'), { cfg = cfg }), 'settlement')
    end)

    it('can be told what counts as a crowd', function()
      local quiet = configMod.new({ settlement = { crowdThreshold = 10 } })
      assert.equals(settlement.classify(cell(nil), { cfg = quiet, friendlyNearby = 5 }), 'wilderness')
      assert.equals(settlement.classify(cell(nil), { cfg = quiet, friendlyNearby = 10 }), 'settlement')
    end)

    it('survives a missing cell or context', function()
      assert.equals(settlement.classify(nil, nil), 'wilderness')
      assert.equals(settlement.classify({}, nil), 'wilderness')
    end)
  end)

  describe('arrived', function()
    it('fires when walking from wilderness into a town', function()
      local arrived, name = settlement.arrived(cell('Ascadian Isles Region'), cell('Balmora'),
        { cfg = cfg })
      assert.is_true(arrived)
      assert.equals(name, 'Balmora')
    end)

    it('fires on the first tick, with no previous cell', function()
      local arrived, name = settlement.arrived(nil, cell('Balmora'), { cfg = cfg })
      assert.is_true(arrived)
      assert.equals(name, 'Balmora')
    end)

    it('does not fire twice for the same town', function()
      local arrived = settlement.arrived(cell('Balmora'), cell('Balmora'), { cfg = cfg })
      assert.is_false(arrived)
    end)

    it('does not fire when moving between interiors', function()
      -- shop to shop in the same town is not an arrival
      local arrived = settlement.arrived(
        { isExterior = false, name = 'Arrille Tradehouse' },
        { isExterior = false, name = 'Balmora, Guild of Mages' },
        { cfg = cfg })
      assert.is_false(arrived)
    end)

    it('fires when leaving an interior back out into the town', function()
      local arrived, name = settlement.arrived(
        { isExterior = false, name = 'Arrille Tradehouse' },
        cell('Balmora'),
        { cfg = cfg })
      assert.is_true(arrived)
      assert.equals(name, 'Balmora')
    end)

    it('fires when travelling between two different towns', function()
      local arrived, name = settlement.arrived(cell('Balmora'), cell('Vivec'), { cfg = cfg })
      assert.is_true(arrived)
      assert.equals(name, 'Vivec')
    end)

    it('does not fire out in the wilderness', function()
      local arrived = settlement.arrived(cell('Bitter Coast Region'), cell(nil), { cfg = cfg })
      assert.is_false(arrived)
    end)
  end)

  describe('current', function()
    it('names the settlement we are in, or nil', function()
      assert.equals(settlement.current(cell('Balmora'), { cfg = cfg }), 'Balmora')
      assert.is_nil(settlement.current(cell(nil), { cfg = cfg }))
    end)
  end)
end)
