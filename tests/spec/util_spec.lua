describe('idle.util', function()
  local util = require('scripts.idle.util')

  describe('numbers', function()
    it('clamps into range', function()
      assert.equals(util.clamp(5, 0, 10), 5)
      assert.equals(util.clamp(-3, 0, 10), 0)
      assert.equals(util.clamp(99, 0, 10), 10)
      assert.equals(util.clamp(nil, 2, 10), 2)
    end)

    it('lerps without clamping t', function()
      assert.equals(util.lerp(0, 10, 0.5), 5)
      assert.equals(util.lerp(0, 10, 2), 20)
    end)

    it('rounds to digits', function()
      assert.equals(util.round(3.14159, 2), 3.14)
      assert.equals(util.round(2.5), 3)
      assert.equals(util.round(-2.5), -2) -- floor-based, documented behaviour
    end)

    it('signs', function()
      assert.equals(util.sign(9), 1)
      assert.equals(util.sign(-9), -1)
      assert.equals(util.sign(0), 0)
    end)

    it('quantizes to a step', function()
      assert.equals(util.quantize(153, 10), 150)
      assert.equals(util.quantize(156, 10), 160)
      assert.equals(util.quantize(5, 0), 5)
    end)
  end)

  describe('angles', function()
    it('normalizes into (-pi, pi]', function()
      assert.is_true(math.abs(util.normalizeAngle(util.TAU) - 0) < 1e-9)
      expect(util.normalizeAngle(util.PI * 1.5)):toBeCloseTo(-util.PI * 0.5, 1e-9)
      expect(util.normalizeAngle(-util.PI * 1.5)):toBeCloseTo(util.PI * 0.5, 1e-9)
    end)

    it('computes shortest delta across the wrap point', function()
      local a = util.TAU - 0.1
      expect(util.angleDelta(a, 0.1)):toBeCloseTo(0.2, 1e-9)
    end)

    it('approaches an angle without overshooting', function()
      expect(util.approachAngle(0, 1.0, 0.25)):toBeCloseTo(0.25, 1e-9)
      expect(util.approachAngle(0, 0.1, 0.25)):toBeCloseTo(0.1, 1e-9)
    end)
  end)

  describe('geometry', function()
    it('measures planar and full distance', function()
      local a, b = { x = 0, y = 0, z = 0 }, { x = 3, y = 4, z = 12 }
      assert.equals(util.planarDistance(a, b), 5)
      assert.equals(util.distance(a, b), 13)
      assert.equals(util.dist2(a, b), 169)
    end)

    it('returns nil for malformed points', function()
      assert.is_nil(util.distance(nil, { x = 1 }))
    end)
  end)

  describe('tables', function()
    it('sums, maps and filters arrays', function()
      assert.equals(util.sum({ 1, 2, 3 }), 6)
      expect(util.map({ 1, 2 }, function(v) return v * 2 end)):toEqualDeep({ 2, 4 })
      expect(util.filter({ 1, 2, 3, 4 }, function(v) return v % 2 == 0 end)):toEqualDeep({ 2, 4 })
      assert.is_true(util.any({ 1, 2 }, function(v) return v == 2 end))
      assert.is_false(util.any({}, function() return true end))
    end)

    it('sorts keys and counts entries', function()
      expect(util.sortedKeys({ b = 1, a = 2 })):toEqualDeep({ 'a', 'b' })
      assert.equals(util.count({ a = 1, b = 2 }), 2)
    end)

    it('deep-copies without aliasing', function()
      local src = { a = { b = 1 } }
      local cp = util.deepCopy(src)
      cp.a.b = 99
      assert.equals(src.a.b, 1)
    end)

    it('deep-merges maps but replaces arrays', function()
      local base = { a = 1, nested = { x = 1, y = 2 }, list = { 1, 2 } }
      local out = util.merge(base, { nested = { y = 5 }, list = { 9 } })
      assert.equals(out.a, 1)
      assert.equals(out.nested.x, 1)
      assert.equals(out.nested.y, 5)
      expect(out.list):toEqualDeep({ 9 })
      -- merge must not mutate the base
      assert.equals(base.nested.y, 2)
    end)

    it('indexes by key and finds the first match', function()
      local list = { { id = 'a', v = 1 }, { id = 'b', v = 2 } }
      local byId = util.indexBy(list, 'id')
      assert.equals(byId.b.v, 2)
      assert.equals(util.firstWhere(list, function(i) return i.v == 2 end).id, 'b')
      assert.is_nil(util.firstWhere(list, function() return false end))
    end)

    it('compacts arrays with holes', function()
      local holey = {}
      holey[1], holey[4] = 'a', 'd'
      expect(util.compact(holey)):toEqualDeep({ 'a', 'd' })
      expect(util.compact({ 1, 2, 3 })):toEqualDeep({ 1, 2, 3 })
    end)

    it('formats numbers with thousands separators', function()
      assert.equals(util.formatNumber(1234567), '1,234,567')
      assert.equals(util.formatNumber(999), '999')
      assert.equals(util.formatNumber(-1234), '-1,234')
    end)
  end)

  -- ---------------------------------------------------------------------------
  -- positions
  -- ---------------------------------------------------------------------------
  -- `self.position` is an engine Vector3 USERDATA. `point()` used to accept only tables, so
  -- every distance in the mod was nil -- and the pathfinder's arrival test (`nil and x <= tol`)
  -- fell through to "arrived". Measured live: the character "arrived" 4000 units from the target
  -- and never took a step. This is the widest-reaching instance of AGENTS.md #7 in the codebase.
  describe('positions from engine userdata', function()
    local hasNewproxy = type(newproxy) == 'function'

    local function vector(x, y, z)
      if not hasNewproxy then return nil end
      local proxy = newproxy(true)
      getmetatable(proxy).__index = { x = x, y = y, z = z }
      return proxy
    end

    it('measures from a table, a userdata, or one of each', function()
      if not hasNewproxy then return end
      local from = vector(0, 0, 0)
      local to = vector(300, 400, 0)
      assert.equals(500, util.distance(from, to))
      assert.equals(500, util.distance({ x = 0, y = 0, z = 0 }, to))
      assert.equals(500, util.distance(from, { x = 300, y = 400, z = 0 }))
      assert.equals(util.distance(from, to), util.distance(to, from))
    end)

    it('measures planar distance from userdata too', function()
      if not hasNewproxy then return end
      assert.equals(500, util.planarDistance(vector(0, 0, 0), vector(300, 400, 900)))
      assert.equals(util.planarDistance(vector(0, 0, 0), vector(300, 400, 0)), 500)
    end)

    it('copies a userdata position without raising', function()
      -- `pairs` on an engine Vector3 is an error, and a copy of a position is the position
      if not hasNewproxy then return end
      local value = vector(1, 2, 3)
      assert.equals(value, util.copy(value))
      assert.equals(2, util.copy({ a = 1, b = 2 }).b)
    end)

    it('still declines a value that is not a position at all', function()
      assert.is_nil(util.distance(nil, { x = 0, y = 0, z = 0 }))
      assert.is_nil(util.distance(7, { x = 0, y = 0, z = 0 }))
      assert.is_nil(util.planarDistance('nope', { x = 0, y = 0, z = 0 }))
    end)
  end)
end)
