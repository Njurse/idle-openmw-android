describe('idle.rng', function()
  local rng = require('scripts.idle.rng')

  it('is deterministic for a given seed', function()
    local a, b = rng.new(42), rng.new(42)
    for _ = 1, 100 do
      assert.equals(a:nextUInt(), b:nextUInt())
    end
  end)

  it('diverges for different seeds', function()
    local a, b = rng.new(1), rng.new(2)
    assert.is_not_nil(a)
    local differ = false
    for _ = 1, 20 do
      if a:nextUInt() ~= b:nextUInt() then differ = true break end
    end
    assert.is_true(differ)
  end)

  it('produces floats in [0,1)', function()
    local r = rng.new(7)
    for _ = 1, 500 do
      local f = r:float01()
      assert.is_true(f >= 0)
      assert.is_true(f < 1)
    end
  end)

  it('respects integer range bounds', function()
    local r = rng.new(9)
    local seenLo, seenHi = false, false
    for _ = 1, 500 do
      local n = r:range(3, 7)
      assert.is_true(n >= 3 and n <= 7)
      if n == 3 then seenLo = true end
      if n == 7 then seenHi = true end
    end
    assert.is_true(seenLo and seenHi)
  end)

  it('handles degenerate ranges', function()
    local r = rng.new(3)
    assert.equals(r:range(5, 5), 5)
    assert.equals(r:range(7, 2), 7)
  end)

  it('treats chance(0) and chance(1) as constants', function()
    local r = rng.new(11)
    for _ = 1, 50 do
      assert.is_false(r:chance(0))
      assert.is_true(r:chance(1))
    end
  end)

  it('chooses only from the given list', function()
    local r = rng.new(5)
    local list = { 'a', 'b', 'c' }
    for _ = 1, 50 do
      assert.is_true(r:choice(list) ~= nil)
    end
    assert.is_nil(r:choice({}))
  end)

  it('respects weighted choice proportions', function()
    local r = rng.new(123)
    local counts = { always = 0, never = 0 }
    for _ = 1, 200 do
      local picked = r:weightedChoice({ 'always', 'never' }, function(item)
        return item == 'always' and 1 or 0
      end)
      counts[picked] = counts[picked] + 1
    end
    assert.equals(counts.never, 0)
    assert.equals(counts.always, 200)
  end)

  it('returns nil from weighted choice when all weights are non-positive', function()
    local r = rng.new(1)
    assert.is_nil(r:weightedChoice({ 'a', 'b' }, function() return 0 end))
  end)

  it('shuffles deterministically', function()
    local a = { 1, 2, 3, 4, 5, 6, 7, 8 }
    local b = { 1, 2, 3, 4, 5, 6, 7, 8 }
    rng.new(77):shuffle(a)
    rng.new(77):shuffle(b)
    expect(a):toEqualDeep(b)
  end)

  it('jitters multiplicatively around the base', function()
    local r = rng.new(2)
    local lo, hi = math.huge, -math.huge
    for _ = 1, 500 do
      local v = r:jitter(100, 0.1)
      lo, hi = math.min(lo, v), math.max(hi, v)
    end
    assert.is_true(lo >= 90 - 1e-9)
    assert.is_true(hi <= 110 + 1e-9)
    assert.equals(r:jitter(50, 0), 50)
  end)

  it('can round-trip its state', function()
    local r = rng.new(4)
    for _ = 1, 10 do r:nextUInt() end
    local saved = r:getState()
    local x1, x2 = r:nextUInt(), r:nextUInt()
    r:setState(saved)
    assert.equals(r:nextUInt(), x1)
    assert.equals(r:nextUInt(), x2)
  end)

  it('never seeds to zero, which would stall the generator', function()
    local r = rng.new(0)
    assert.is_true(r:getState() ~= 0)
    local first = r:nextUInt()
    assert.is_true(r:nextUInt() ~= first)
  end)
end)
