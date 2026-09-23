-- tests/spec/aim_spec.lua
-- The geometry behind "walk up to the hatch, look up at it, and open it"
-- (scripts/idle/aim.lua).
--
-- The yaw convention is the engine's own, taken from its Activate AI package
-- (apps/openmw/mwmechanics/aiactivate.cpp:44): atan2(dx, dy) -- x first. That is NOT the usual
-- maths convention, so the first test here exists purely to catch anyone "fixing" it.
describe('idle.aim', function()
  local aim = require('scripts.idle.aim')

  local function at(x, y, z) return { x = x, y = y, z = z } end

  describe('yawTo', function()
    it('uses the engine convention: atan2(dx, dy), x FIRST', function()
      -- straight ahead is +Y in Morrowind/OpenMW, and that is yaw 0
      assert.is_true(math.abs(aim.yawTo(at(0, 0, 0), at(0, 10, 0))) < 0.0001)
      -- due +X is a quarter turn the positive way, NOT atan2(y, x) which would also be pi/2
      -- for this case -- so the discriminating case is the diagonal below
      assert.is_true(math.abs(aim.yawTo(at(0, 0, 0), at(10, 0, 0)) - math.pi / 2) < 0.0001)
    end)

    it('is the mirror of atan2(y, x) on a diagonal, which is how the convention shows', function()
      local turned = aim.yawTo(at(0, 0, 0), at(10, 10, 0))
      assert.is_true(math.abs(turned - math.pi / 4) < 0.0001)

      -- A diagonal is the wrong probe: atan2(dx, dy) and atan2(dy, dx) agree when dx == dy. So
      -- use an off-diagonal point, where the two conventions must differ.
      --
      -- Written with single-argument math.atan and dx > 0 so this spec is portable: Lua 5.4 has
      -- no math.atan2 at all (it is math.atan(y, x) there), and `--all` runs this on 5.4 too.
      local dx, dy = 1, 3
      local xFirst = math.atan(dx / dy)   -- atan2(dx, dy) for dx > 0
      local yFirst = math.atan(dy / dx)   -- atan2(dy, dx) for dy > 0
      assert.is_true(math.abs(aim.yawTo(at(0, 0, 0), at(dx, dy, 0)) - xFirst) < 0.0001)
      assert.is_false(math.abs(aim.yawTo(at(0, 0, 0), at(dx, dy, 0)) - yFirst) < 0.0001)
    end)

    it('is nil without two positions', function()
      assert.is_nil(aim.yawTo(nil, at(1, 1, 1)))
      assert.is_nil(aim.yawTo(at(1, 1, 1), nil))
    end)
  end)

  describe('pitchTo', function()
    it('looks up for a target above, and down for one below', function()
      local up = aim.pitchTo(at(0, 0, 0), at(0, 10, 10))
      local down = aim.pitchTo(at(0, 0, 0), at(0, 10, -10))
      assert.is_true(up > 0, 'a target above should need a positive pitch')
      assert.is_true(down < 0)
      assert.is_true(math.abs(up + down) < 0.0001, 'and the two should be symmetric')
    end)

    it('is zero at eye level, and a right angle straight up', function()
      assert.is_true(math.abs(aim.pitchTo(at(0, 0, 0), at(0, 10, 0))) < 0.0001)
      assert.is_true(math.abs(aim.pitchTo(at(0, 0, 0), at(0, 0.0001, 10)) - math.pi / 2) < 0.01)
    end)

    it('can be flipped, for the day the camera quaternion order disagrees', function()
      local flat = aim.pitchTo(at(0, 0, 0), at(0, 10, 10), 1)
      local flipped = aim.pitchTo(at(0, 0, 0), at(0, 10, 10), -1)
      assert.is_true(math.abs(flat + flipped) < 0.0001)
    end)
  end)

  describe('plan', function()
    it('carries the angles, the distance and which way the target is', function()
      local plan = aim.plan(at(0, 0, 0), at(0, 100, 30))
      assert.is_true(math.abs(plan.yaw) < 0.0001)
      assert.is_true(plan.pitch > 0)
      assert.is_true(math.abs(plan.distance - math.sqrt(100 * 100 + 30 * 30)) < 0.001)
      assert.is_true(math.abs(plan.planar - 100) < 0.001)
      assert.is_true(plan.above)
    end)
  end)

  describe('inReach', function()
    it('is inclusive at the boundary, and honest about a missing distance', function()
      assert.is_true(aim.inReach(128, 128))
      assert.is_false(aim.inReach(129, 128))
      assert.is_false(aim.inReach(nil, 128))
      -- with no reach given, the documented engine default applies
      assert.is_true(aim.inReach(aim.DEFAULT_REACH))
      assert.is_false(aim.inReach(aim.DEFAULT_REACH + 1))
    end)
  end)

  describe('chooseExit', function()
    -- `distance = nil` in a table literal is not a key at all, so it cannot express "this field
    -- is missing" -- the default would survive and the test would pass for the wrong reason.
    -- A sentinel says it explicitly.
    local ABSENT = {}
    local function door(fields)
      local out = { id = 'd', kind = 'door', position = at(0, 0, 0), distance = 10 }
      for key, value in pairs(fields or {}) do
        if value == ABSENT then out[key] = nil else out[key] = value end
      end
      return out
    end

    it('says so when there is nothing to leave by', function()
      local chosen, why = aim.chooseExit({})
      assert.is_nil(chosen)
      assert.equals(why, 'no doors nearby')
      assert.is_nil(aim.chooseExit(nil))
    end)

    it('respects a door the player is already looking at', function()
      local chosen = aim.chooseExit({
        door({ id = 'far', isTeleport = true, distance = 5 }),
        door({ id = 'looked', hit = true, distance = 90 }),
      })
      assert.equals(chosen.id, 'looked')
    end)

    it('prefers a teleport door over a nearer ordinary one', function()
      -- only teleport doors move you between cells, so a closer cupboard is not an exit
      local chosen, why = aim.chooseExit({
        door({ id = 'cupboard', distance = 5 }),
        door({ id = 'hatch', isTeleport = true, distance = 60 }),
      })
      assert.equals(chosen.id, 'hatch')
      assert.is_true(why:find('teleport') ~= nil)
    end)

    it('picks the nearest teleport door, and notes when it is already in reach', function()
      local chosen, why = aim.chooseExit({
        door({ id = 'near', isTeleport = true, distance = 60 }),
        door({ id = 'far', isTeleport = true, distance = 600 }),
      }, 128)
      assert.equals(chosen.id, 'near')
      assert.is_true(why:find('already in reach') ~= nil)

      local outOf, why2 = aim.chooseExit({ door({ id = 'far', isTeleport = true, distance = 600 }) }, 128)
      assert.equals(outOf.id, 'far')
      assert.is_true(why2:find('nearest teleport door') ~= nil)
    end)

    it('falls back to an ordinary door, and says that is what it is', function()
      local chosen, why = aim.chooseExit({ door({ id = 'cabin', distance = 20 }) })
      assert.equals(chosen.id, 'cabin')
      assert.is_true(why:find('not a teleport') ~= nil)
    end)

    it('works out a missing distance from the player rather than treating it as zero', function()
      local chosen = aim.chooseExit({
        door({ id = 'unknown-far', distance = ABSENT, position = at(0, 500, 0) }),
        door({ id = 'known-near', distance = ABSENT, position = at(0, 10, 0) }),
      }, 128, at(0, 0, 0))
      assert.equals(chosen.id, 'known-near')
    end)

    it('ignores a door with no position, which cannot be walked to', function()
      local chosen = aim.chooseExit({ door({ id = 'ghost', position = ABSENT }) })
      assert.is_nil(chosen)
    end)
  end)

  describe('step', function()
    it('walks while out of reach -- the "close enough to interact" rule', function()
      local decision = aim.step({ position = at(0, 900, 0) }, at(0, 0, 0), 128)
      assert.equals(decision.step, 'move')
      assert.is_true(decision.reason:find('reach') ~= nil)
    end)

    it('AIMS once in reach -- the step a player calls "look up at the hatch"', function()
      -- the hatch is above; in reach but not yet aimed
      local decision = aim.step({ position = at(0, 10, 40) }, at(0, 0, 0), 128)
      assert.equals(decision.step, 'aim')
      assert.is_true(decision.plan.above)
      assert.is_true(decision.plan.pitch > 0)
    end)

    it('activates only once in reach AND aimed', function()
      local decision = aim.step({ position = at(0, 10, 40) }, at(0, 0, 0), 128, { aimed = true })
      assert.equals(decision.step, 'activate')
    end)

    it('says why when it cannot decide', function()
      assert.equals(aim.step({}, at(0, 0, 0)).step, 'none')
      assert.equals(aim.step({ position = at(0, 0, 0) }, nil).step, 'none')
      assert.is_true(aim.step({}, at(0, 0, 0)).reason:find('position') ~= nil)
    end)
  end)

  describe('sameTarget', function()
    it('compares ids, because engine objects cannot be compared directly', function()
      assert.is_true(aim.sameTarget({ id = 'a' }, { id = 'a' }))
      assert.is_false(aim.sameTarget({ id = 'a' }, { id = 'b' }))
      assert.is_false(aim.sameTarget(nil, { id = 'a' }))
    end)

    it('falls back to the record id when one side has no instance id', function()
      assert.is_true(aim.sameTarget({ recordId = 'x' }, { recordId = 'x' }))
      assert.is_false(aim.sameTarget({ id = 'a', recordId = 'x' }, { id = 'b', recordId = 'y' }))
    end)
  end)
end)
