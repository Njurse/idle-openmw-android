-- tests/spec/places_spec.lua
-- Nearby go-to buttons and the town wander leash (scripts/idle/places.lua).
describe('idle.places', function()
  local places = require('scripts.idle.places')

  local function door(dest, x, y) return { entity = { kind = 'door', destCell = dest, position = { x = x, y = y, z = 0 } } } end
  local function npc(name, x, y, dead) return { entity = { kind = 'npc', id = name, name = name, dead = dead, position = { x = x, y = y, z = 0 } } } end

  it('knows Seyda Neen and its interiors', function()
    assert.equals(places.townOf('Seyda Neen'), 'Seyda Neen')
    assert.equals(places.townOf("Seyda Neen, Arrille's Tradehouse"), 'Seyda Neen')
    assert.is_nil(places.townOf('Balmora'))
  end)

  it('lists doors by destination, nearest first, deduped, then NPCs', function()
    local list = places.collect({
      cell = { name = 'Seyda Neen', isExterior = true },
      from = { x = 0, y = 0, z = 0 },
      doors = { door("Seyda Neen, Arrille's Tradehouse", 500, 0), door("Seyda Neen, Arrille's Tradehouse", 300, 0),
        door('Seyda Neen, Census and Excise Office', 100, 0), door(nil, 10, 0), door('Far Away', 9000, 0) },
      actors = { npc('Fargoth', 200, 0), npc('Dead Guy', 50, 0, true), { entity = { kind = 'creature', name = 'Mudcrab', position = { x = 1, y = 0 } } } },
    })
    assert.equals(#list, 3)
    assert.equals(list[1].label, 'Census and Excise Office')
    assert.equals(list[2].label, "Arrille's Tradehouse")
    assert.equals(list[2].distance, 300)
    assert.equals(list[3].kind, 'talk')
    assert.equals(list[3].label, 'Fargoth')
    local pub = places.public(list)
    assert.is_nil(pub[1].ref)
    assert.equals(pub[1].id, 'door:census_and_excise_office')
  end)

  it('keeps wander points on the leash', function()
    local anchor = { x = 1000, y = 1000, z = 5 }
    local seq, i = { 0.9, 0.5, 0.99 }, 0
    local function rng() i = i + 1 return seq[(i - 1) % #seq + 1] end
    for _ = 1, 20 do
      local p = places.wanderPoint(anchor, {}, rng, 800)
      assert.is_true(places.dist(p, anchor) <= 800.001)
    end
    assert.is_nil(places.wanderPoint(nil, {}, rng))
  end)
end)
