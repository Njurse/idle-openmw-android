-- tests/spec/tapMove_spec.lua
-- "I tapped there -- what should happen?" (scripts/idle/tapMove.lua).
describe('idle.tapMove', function()
  local tapMove = require('scripts.idle.tapMove')

  local function player(x, y, z) return { position = { x = x, y = y, z = z } } end

  describe('approach', function()
    it('stops `standoff` short of the target, on the side you came from', function()
      local dest = tapMove.approach({ x = 100, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, 40)
      assert.equals(dest.x, 60)   -- 100 - 40, toward the player
      assert.equals(dest.y, 0)
    end)

    it('does not overshoot when you are already closer than the standoff', function()
      local dest = tapMove.approach({ x = 10, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, 40)
      assert.equals(dest.x, 10)
    end)

    it('returns the point unchanged with no origin', function()
      assert.equals(tapMove.approach({ x = 5, y = 6, z = 7 }, nil).x, 5)
    end)

    it('returns nil for a non-point', function()
      assert.is_nil(tapMove.approach(nil, player(0, 0, 0)))
      assert.is_nil(tapMove.approach({ x = 'a' }, player(0, 0, 0)))
    end)
  end)

  describe('intent', function()
    it('is none when the tap hit nothing', function()
      assert.equals(tapMove.intent(nil, player(0, 0, 0)).kind, 'none')
      assert.equals(tapMove.intent({ hit = false }, player(0, 0, 0)).kind, 'none')
      assert.equals(tapMove.intent({ hit = true }, player(0, 0, 0)).kind, 'none')
    end)

    it('refuses a target beyond reach', function()
      local pick = { hit = true, position = { x = 9000, y = 0, z = 0 }, distance = 9000, kind = 'door' }
      local intent = tapMove.intent(pick, player(0, 0, 0))
      assert.equals(intent.kind, 'none')
      assert.is_true(tostring(intent.reason):find('far') ~= nil)
    end)

    it('walks to a door and enters it', function()
      local pick = { hit = true, position = { x = 100, y = 0, z = 0 }, distance = 100,
        kind = 'door', id = 'census door' }
      local intent = tapMove.intent(pick, player(0, 0, 0))
      assert.equals(intent.kind, 'enter')
      assert.is_true(intent.dest.x < 100)          -- stops short
      assert.equals(intent.target, pick)           -- carries the object to activate
      assert.is_true(intent.label:find('census door', 1, true) ~= nil)
    end)

    it('walks to an actor to talk', function()
      local pick = { hit = true, position = { x = 0, y = 200, z = 0 }, distance = 200,
        kind = 'actor', name = 'Arrille' }
      local intent = tapMove.intent(pick, player(0, 0, 0))
      assert.equals(intent.kind, 'talk')
      assert.is_true(intent.label:find('Arrille', 1, true) ~= nil)
    end)

    it('uses a container/activator where it stands', function()
      assert.equals(tapMove.intent({ hit = true, position = { x = 1, y = 0, z = 0 },
        distance = 1, kind = 'container' }, player(0, 0, 0)).kind, 'use')
      assert.equals(tapMove.intent({ hit = true, position = { x = 1, y = 0, z = 0 },
        distance = 1, kind = 'activator' }, player(0, 0, 0)).kind, 'use')
    end)

    it('just walks to bare ground, to the exact spot tapped', function()
      local pick = { hit = true, position = { x = 500, y = 500, z = 0 }, distance = 700 }
      local intent = tapMove.intent(pick, player(0, 0, 0))
      assert.equals(intent.kind, 'walk')
      assert.equals(intent.dest.x, 500)   -- no standoff for ground
      assert.is_nil(intent.target)        -- nothing to activate
    end)

    it('honours a configured reach and standoff', function()
      local pick = { hit = true, position = { x = 100, y = 0, z = 0 }, distance = 100, kind = 'door' }
      assert.equals(tapMove.intent(pick, player(0, 0, 0), { maxReach = 50 }).kind, 'none')
      assert.equals(tapMove.intent(pick, player(0, 0, 0), { standoff = 0 }).dest.x, 100)
    end)
  end)

  describe('describe', function()
    it('reads a label, or the reason it refused', function()
      assert.equals(tapMove.describe({ kind = 'walk', label = 'walk' }), 'walk')
      assert.is_true(tapMove.describe({ kind = 'none', reason = 'nothing there' })
        :find('nothing there', 1, true) ~= nil)
      assert.equals(tapMove.describe(nil), 'nothing')
    end)
  end)
end)
