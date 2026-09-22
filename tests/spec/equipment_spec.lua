describe('idle.equipment', function()
  local equipment = require('scripts.idle.equipment')

  -- Mirrors the engine's real tables (numeric values deliberately NOT in slot
  -- order, which is exactly the trap this module exists to avoid).
  local types = {
    Armor = { TYPE = { Helmet = 0, Cuirass = 1, LPauldron = 2, RPauldron = 3, Greaves = 4,
                       Boots = 5, LGauntlet = 6, RGauntlet = 7, Shield = 8, LBracer = 9, RBracer = 10 } },
    Clothing = { TYPE = { Amulet = 0, Belt = 1, LGlove = 2, Pants = 3, RGlove = 4,
                          Ring = 5, Robe = 6, Shirt = 7, Shoes = 8, Skirt = 9 } },
    Weapon = { TYPE = { ShortBladeOneHand = 0, LongBladeOneHand = 1, LongBladeTwoHand = 2,
                        BluntOneHand = 3, MarksmanBow = 9, MarksmanCrossbow = 10,
                        Arrow = 12, Bolt = 13 } },
    Light = { TYPE = { Default = 0 } },
    Lockpick = {}, Probe = {}, Repair = {}, Apparatus = {},
    Potion = {}, Ingredient = {}, Book = {}, Miscellaneous = {},
  }

  it('inverts an engine TYPE table', function()
    local names = equipment.invertTypeTable({ Helmet = 0, Cuirass = 1 })
    assert.equals(names[0], 'Helmet')
    assert.equals(names[1], 'Cuirass')
    expect(equipment.invertTypeTable(nil)):toEqualDeep({})
  end)

  it('identifies an item kind from its type class', function()
    assert.equals(equipment.kindOf(types.Armor, types), 'armor')
    assert.equals(equipment.kindOf(types.Weapon, types), 'weapon')
    assert.equals(equipment.kindOf(types.Lockpick, types), 'lockpick')
    assert.equals(equipment.kindOf({}, types), 'other')
    assert.equals(equipment.kindOf(types.Armor, nil), 'other')
  end)

  it('maps armor type names to the right slots (not the numeric order)', function()
    -- armor type 2 is LPauldron but equipment slot 2 is Greaves
    assert.equals(equipment.slotFor('armor', 'LPauldron'), 'LeftPauldron')
    assert.equals(equipment.slotFor('armor', 'Greaves'), 'Greaves')
    assert.equals(equipment.slotFor('armor', 'Shield'), 'CarriedLeft')
    assert.equals(equipment.slotFor('armor', 'LBracer'), 'LeftGauntlet')
  end)

  it('maps clothing type names to the right slots', function()
    assert.equals(equipment.slotFor('clothing', 'Ring'), 'LeftRing')
    assert.equals(equipment.slotFor('clothing', 'Shoes'), 'Boots')
    assert.equals(equipment.slotFor('clothing', 'RGlove'), 'RightGauntlet')
    assert.equals(equipment.slotFor('clothing', 'Amulet'), 'Amulet')
  end)

  it('sends ordinary weapons to the right hand and ammo to the ammo slot', function()
    assert.equals(equipment.slotFor('weapon', 'LongBladeOneHand'), 'CarriedRight')
    assert.equals(equipment.slotFor('weapon', 'MarksmanBow'), 'CarriedRight')
    assert.equals(equipment.slotFor('weapon', 'Arrow'), 'Ammunition')
    assert.equals(equipment.slotFor('weapon', 'Bolt'), 'Ammunition')
  end)

  it('never claims tools, potions or books are equippable', function()
    for _, kind in ipairs({ 'lockpick', 'probe', 'repair', 'apparatus', 'potion', 'ingredient', 'book', 'misc' }) do
      assert.is_false(equipment.isEquippableKind(kind))
      assert.is_nil(equipment.slotFor(kind, 'Anything'))
    end
    for _, kind in ipairs({ 'armor', 'clothing', 'weapon', 'light' }) do
      assert.is_true(equipment.isEquippableKind(kind))
    end
  end)

  it('resolves a full item end to end', function()
    local cuirass = equipment.resolve(types.Armor, { type = 1 }, types)
    assert.equals(cuirass.kind, 'armor')
    assert.equals(cuirass.typeName, 'Cuirass')
    assert.equals(cuirass.slot, 'Cuirass')
    assert.is_true(cuirass.equippable)

    local bow = equipment.resolve(types.Weapon, { type = 9 }, types)
    assert.equals(bow.typeName, 'MarksmanBow')
    assert.equals(bow.slot, 'CarriedRight')

    local lockpick = equipment.resolve(types.Lockpick, { type = 0 }, types)
    assert.is_false(lockpick.equippable)
    assert.is_nil(lockpick.slot)
  end)

  it('degrades gracefully on missing data', function()
    local unknown = equipment.resolve(types.Armor, { type = 99 }, types)
    assert.is_nil(unknown.typeName)
    assert.is_nil(unknown.slot) -- unknown armor type must NOT be guessed
    assert.is_false(unknown.equippable)

    assert.is_nil(equipment.resolve(nil, nil, nil).slot)
    assert.is_nil(equipment.resolve(types.Armor, nil, types).slot)
  end)

  describe('paperDoll', function()
    local items = {
      { id = 'steel cuirass', count = 1, equipped = true, equipSlot = 'Cuirass' },
      { id = 'longsword', count = 1, equipped = true, equipSlot = 'CarriedRight' },
      { id = 'chitin dagger', count = 3, equipped = false, equipSlot = 'CarriedRight' },
      { id = 'lockpick', count = 12, equipped = false },
    }

    it('returns every slot in paper-doll order', function()
      local doll = equipment.paperDoll(items)
      assert.equals(#doll, #equipment.SLOT_ORDER)
      assert.equals(doll[1].slot, equipment.SLOT_ORDER[1])
    end)

    it('fills the slots something is worn in, and leaves the rest empty', function()
      local bySlot = {}
      for _, entry in ipairs(equipment.paperDoll(items)) do bySlot[entry.slot] = entry end
      assert.equals(bySlot.Cuirass.item.id, 'steel cuirass')
      assert.equals(bySlot.CarriedRight.item.id, 'longsword')
      assert.is_nil(bySlot.Helmet.item)
    end)

    it('carries the inventory index so a worn piece can be acted on', function()
      local bySlot = {}
      for _, entry in ipairs(equipment.paperDoll(items)) do bySlot[entry.slot] = entry end
      assert.equals(bySlot.Cuirass.index, 1)
      assert.equals(bySlot.CarriedRight.index, 2)
    end)

    it('gives a human label to the awkward slots', function()
      assert.equals(equipment.slotLabel('LeftPauldron'), 'L pauldron')
      assert.equals(equipment.slotLabel('CarriedRight'), 'Right hand')
      assert.equals(equipment.slotLabel('Helmet'), 'Helmet')
    end)

    it('survives an empty or nil inventory', function()
      assert.equals(#equipment.paperDoll({}), #equipment.SLOT_ORDER)
      assert.equals(#equipment.paperDoll(nil), #equipment.SLOT_ORDER)
    end)
  end)
end)
