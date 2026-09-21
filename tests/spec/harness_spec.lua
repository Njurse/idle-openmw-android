-- tests/spec/smoke_spec.lua
-- Proves the harness itself works before we build on it.

describe('harness', function()
  it('runs a passing assertion', function()
    expect(1 + 1):toBe(2)
    assert.equals('a' .. 'b', 'ab')
    assert.is_true(true)
  end)

  it('compares tables deeply', function()
    local harness = require('tests.harness')
    expect({ a = 1, b = { c = 2 } }):toEqualDeep({ a = 1, b = { c = 2 } })
    assert.is_false(harness.deepEqual({ a = 1 }, { a = 2 }))
  end)

  it('reports floats with tolerance', function()
    expect(0.1 + 0.2):toBeCloseTo(0.3, 1e-9)
  end)

  it('catches thrown errors', function()
    expect(function() error('boom') end):toThrow()
    expect(function() return 1 end):toBeType('function')
  end)
end)

describe('harness before_each', function()
  local n = 0
  before_each(function() n = 0 end)

  it('starts each test at zero', function()
    expect(n):toBe(0)
    n = n + 5
  end)

  it('is reset again for the next test', function()
    expect(n):toBe(0)
  end)
end)
