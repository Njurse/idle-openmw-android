-- tests/spec/worldsense_spec.lua
-- The rules that decide "what is that actor?" -- the difference between the mod
-- walking to a shop and the mod walking into a guard's sword.
local worldsense = require('scripts.idle.worldsense')
local configMod = require('scripts.idle.config')

local cfg = configMod.new()

--- A descriptor the way runtime/observer.lua would build it.
local function actor(overrides)
  local spec = {
    record = overrides.record or {},
    isCreature = overrides.isCreature,
    fight = overrides.fight,
    level = overrides.level or 1,
    id = overrides.id,
    name = overrides.name or 'someone',
    position = overrides.position or { x = 0, y = 0, z = 0 },
  }
  return worldsense.describe(spec, overrides.cfg or cfg)
end

-- NPC hostility is opt-in (see worldsense.hostile); most NPC tests need it on.
local npcCfg = configMod.new({ sensing = { npcFightHostility = true } })

describe('worldsense.readServices', function()
  it('normalizes the engine servicesOffered map', function()
    local flags = worldsense.readServices({ servicesOffered = { Barter = true, Training = false } })
    assert.is_true(flags.Barter)
    assert.is_false(flags.Training)   -- present but false
    assert.is_false(flags.Spells)     -- absent
  end)

  it('survives a missing or malformed record', function()
    assert.equals(worldsense.serviceCount(worldsense.readServices(nil)), 0)
    assert.equals(worldsense.serviceCount(worldsense.readServices({})), 0)
    assert.equals(worldsense.serviceCount(worldsense.readServices({ servicesOffered = 5 })), 0)
  end)

  it('counts only the services that are actually offered', function()
    local flags = worldsense.readServices({ servicesOffered = { Barter = true, Repair = true, Spells = true } })
    assert.equals(worldsense.serviceCount(flags), 3)
    assert.is_true(worldsense.offersAnyService(flags))
  end)
end)

describe('worldsense.roles', function()
  it('maps services onto idle roles', function()
    local merchant = worldsense.roles(worldsense.readServices({ servicesOffered = { Barter = true } }), {})
    assert.is_true(merchant.shop)
    assert.is_false(merchant.trainer)
    assert.is_false(merchant.questing)

    local trainer = worldsense.roles(worldsense.readServices({ servicesOffered = { Training = true } }), {})
    assert.is_true(trainer.trainer)

    local healer = worldsense.roles(worldsense.readServices({ servicesOffered = { Potions = true } }), {})
    assert.is_true(healer.healer)
  end)

  it('treats a service-less NPC as a "talker" (possible quest giver)', function()
    local roles = worldsense.roles(worldsense.readServices({}), {})
    assert.is_true(roles.questing)
    assert.is_false(roles.services)
  end)

  it('reads travel from travelDestinations, not from a service flag', function()
    -- "Travel" is documented on servicesOffered but is NOT one of the 19 bound
    -- ServiceNames (servicesoffered.hpp:12); destinations are the real signal.
    local roles = worldsense.roles(worldsense.readServices({}), {
      travelDestinations = { { cell = 'Balmora' } },
    })
    assert.is_true(roles.travel)
    assert.is_false(roles.questing)   -- a travel NPC is not a mere talker
  end)

  it('does not call a travel NPC a talker when it also sells', function()
    local roles = worldsense.roles(
      worldsense.readServices({ servicesOffered = { Barter = true } }),
      { travelDestinations = { { cell = 'Vivec' } } })
    assert.is_true(roles.travel)
    assert.is_true(roles.shop)
    assert.is_false(roles.questing)
  end)
end)

describe('worldsense.hostile', function()
  it('treats creatures as enemies by default', function()
    local hostile, reason = worldsense.hostile({ isCreature = true }, cfg)
    assert.is_true(hostile)
    assert.equals(reason, 'creature')
  end)

  it('can be told to leave creatures alone', function()
    local gentle = configMod.new({ sensing = { creaturesAreHostile = false } })
    assert.is_false(worldsense.hostile({ isCreature = true }, gentle))
  end)

  it('leaves NPCs alone by default, even at Fight 100', function()
    -- the guard/bandit problem: the engine cannot tell them apart, so the safe
    -- default is to never attack an NPC
    assert.is_false(worldsense.hostile({ fight = 100 }, cfg))
    assert.is_false(worldsense.hostile({ fight = 95 }, cfg))
  end)

  it('turns NPCs hostile only when explicitly opted in, at the threshold', function()
    assert.is_true(worldsense.hostile({ fight = 80 }, npcCfg))
    assert.is_true(worldsense.hostile({ fight = 95 }, npcCfg))
    assert.is_false(worldsense.hostile({ fight = 79 }, npcCfg))
    assert.is_false(worldsense.hostile({ fight = 0 }, npcCfg))
  end)

  it('honours a custom threshold', function()
    local jumpy = configMod.new({ sensing = { npcFightHostility = true, hostileFightThreshold = 30 } })
    assert.is_true(worldsense.hostile({ fight = 30 }, jumpy))
    assert.is_false(worldsense.hostile({ fight = 29 }, jumpy))
  end)

  it('never calls an NPC hostile without a fight disposition', function()
    assert.is_false(worldsense.hostile({}, npcCfg))
    assert.is_false(worldsense.hostile(nil, npcCfg))
  end)

  it('spares essential actors and anyone offering a service', function()
    -- a guard has Fight 100 but is not your enemy once it sells something
    assert.is_false(worldsense.hostile({ fight = 100, offersServices = true }, npcCfg))
    assert.is_false(worldsense.hostile({ fight = 100, isEssential = true }, npcCfg))
    assert.is_false(worldsense.hostile({ isCreature = true, isEssential = true }, cfg))
  end)

  it('spares record ids listed in ignoreRecords', function()
    local safe = configMod.new({
      sensing = { npcFightHostility = true, ignoreRecords = { 'caius_cosades' } },
    })
    assert.is_false(worldsense.hostile({ id = 'caius_cosades', fight = 100 }, safe))
    assert.is_true(worldsense.hostile({ id = 'bandit', fight = 100 }, safe))
  end)
end)

describe('worldsense.describe', function()
  it('classifies a merchant and forbids treating it as an enemy', function()
    local described = actor({
      name = 'arrille',
      record = { servicesOffered = { Barter = true }, isEssential = true },
      fight = 100,
    })
    assert.is_true(described.roles.shop)
    assert.is_true(described.offersServices)
    assert.is_false(described.hostile)
    assert.equals(described.name, 'arrille')
  end)

  it('classifies a hostile creature', function()
    local described = actor({ name = 'rat', isCreature = true })
    assert.is_true(described.hostile)
    assert.equals(described.hostileReason, 'creature')
    assert.equals(described.roles.questing, true)  -- no services -> a talker too
    assert.is_false(described.offersServices)
  end)

  it('does not attack an NPC by default, but does when opted in', function()
    local bandit = { name = 'bandit', id = 'bandit', fight = 90 }
    assert.is_false(actor(bandit).hostile)
    assert.is_true(actor({ name = 'bandit', id = 'bandit', fight = 90, cfg = npcCfg }).hostile)
  end)

  it('carries travel destinations through', function()
    local described = actor({
      name = 'strider',
      record = { travelDestinations = { { cell = 'Balmora' }, { cell = 'Vivec' } } },
    })
    assert.equals(#described.travelDestinations, 2)
    assert.is_true(described.roles.travel)
  end)
end)

describe('worldsense.scan', function()
  local origin = { x = 0, y = 0, z = 0 }

  it('measures opportunities by proximity', function()
    local scan = worldsense.scan({
      actor({ name = 'near', position = { x = 100, y = 0, z = 0 }, record = { servicesOffered = { Barter = true } } }),
      actor({ name = 'far', position = { x = 3900, y = 0, z = 0 }, record = { servicesOffered = { Training = true } } }),
    }, { position = origin, scanRadius = 4096 })

    assert.is_true(scan.opportunities.shop > 0.9)      -- 100 away
    assert.is_true(scan.opportunities.trainer < 0.1)   -- 3900 away
    assert.equals(scan.nearest.shop.name, 'near')
  end)

  it('keeps the nearest of several candidates', function()
    local scan = worldsense.scan({
      actor({ name = 'far', position = { x = 3000, y = 0, z = 0 }, record = { servicesOffered = { Barter = true } } }),
      actor({ name = 'near', position = { x = 200, y = 0, z = 0 }, record = { servicesOffered = { Barter = true } } }),
    }, { position = origin, scanRadius = 4096 })
    assert.equals(scan.nearest.shop.name, 'near')
    assert.is_true(scan.nearest.shop.distance < 300)
  end)

  it('collects enemies separately and never as opportunities', function()
    local scan = worldsense.scan({
      actor({ name = 'rat', isCreature = true, level = 3, position = { x = 10, y = 0, z = 0 } }),
      actor({ name = 'merchant', record = { servicesOffered = { Barter = true } }, position = { x = 50, y = 0, z = 0 } }),
    }, { position = origin, scanRadius = 4096 })

    assert.equals(#scan.enemies, 1)
    assert.equals(scan.enemies[1].name, 'rat')
    assert.equals(scan.enemies[1].level, 3)
    assert.is_true(scan.opportunities.shop > 0)
    assert.is_true(scan.opportunities.enemy > 0)   -- tracked, but not a goal
  end)

  it('weights a service-less talker below a real seller', function()
    local scan = worldsense.scan({
      actor({ name = 'seller', position = { x = 100, y = 0, z = 0 }, record = { servicesOffered = { Barter = true } } }),
      actor({ name = 'talker', position = { x = 100, y = 0, z = 0 } }),
    }, { position = origin, scanRadius = 4096 })

    assert.is_true(scan.opportunities.quest > 0)
    assert.is_true(scan.opportunities.quest < scan.opportunities.talk)
  end)

  it('survives an empty scan', function()
    local scan = worldsense.scan({}, { position = origin })
    assert.equals(#scan.enemies, 0)
    assert.equals(scan.opportunities.shop, 0)
    assert.equals(scan.opportunities.talk, 0)
  end)
end)

describe('worldsense.destinationsOf', function()
  it('flattens travel destinations into rows', function()
    local rows = worldsense.destinationsOf({
      travelDestinations = { { cell = 'Balmora', price = 30 }, { name = 'Vivec', price = 50 } },
    })
    assert.equals(#rows, 2)
    assert.equals(rows[1].cell, 'Balmora')
    assert.equals(rows[1].price, 30)
    assert.equals(rows[2].cell, 'Vivec')
  end)

  it('returns nothing for an entry without destinations', function()
    assert.equals(#worldsense.destinationsOf(nil), 0)
    assert.equals(#worldsense.destinationsOf({}), 0)
  end)
end)
