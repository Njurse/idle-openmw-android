-- tests/spec/trace_spec.lua
-- The development decision recorder (scripts/idle/trace.lua).
describe('idle.trace', function()
  local trace = require('scripts.idle.trace')

  it('records events in order and counts them by kind', function()
    local t = trace.new()
    t:add('goal', 'fight', 10)
    t:add('order', 'shop', 12)
    t:add('goal', 'rest', 20)
    assert.equals(t:count(), 3)
    assert.equals(t:countOf('goal'), 2)
    assert.equals(t:countOf('order'), 1)
    assert.equals(t:countOf('nope'), 0)
  end)

  it('renders a fixed-width timeline line', function()
    local t = trace.new()
    t:add('goal', 'fight (2 hostiles)', 12.3, { 'cmds=1' })
    local line = t:lines()[1]
    assert.is_true(line:find('goal', 1, true) ~= nil)
    assert.is_true(line:find('fight (2 hostiles)', 1, true) ~= nil)
    assert.is_true(line:find('[cmds=1]', 1, true) ~= nil)
  end)

  it('keeps only the last `limit` events, and reports the drops', function()
    local t = trace.new(3)
    for i = 1, 10 do t:add('goal', 'g' .. i, i) end
    assert.equals(t:count(), 3)
    assert.equals(t:droppedCount(), 7)
    local lines = t:lines()
    assert.is_true(lines[1]:find('g8', 1, true) ~= nil)
    assert.is_true(lines[3]:find('g10', 1, true) ~= nil)
  end)

  it('tails the most recent events', function()
    local t = trace.new()
    for i = 1, 6 do t:add('goal', 'g' .. i, i) end
    local tail = t:tail(2)
    assert.equals(#tail, 2)
    assert.equals(tail[1].message, 'g5')
    assert.equals(tail[2].message, 'g6')
    -- asking for more than there is returns everything
    assert.equals(#t:tail(99), 6)
  end)

  it('summarises counts by kind, sorted', function()
    local t = trace.new()
    t:add('goal', 'a', 1)
    t:add('order', 'b', 2)
    t:add('goal', 'c', 3)
    assert.equals(t:summary(), 'goal=2  order=1')
  end)

  it('clears', function()
    local t = trace.new()
    t:add('goal', 'a', 1)
    t:clear()
    assert.equals(t:count(), 0)
    assert.equals(t:summary(), '')
  end)

  it('does not throw on odd input', function()
    assert.equals(trace.formatEvent(nil), '')
    local t = trace.new()
    t:add(nil, nil, nil) -- tolerated: a caller bug must not break the loop
    assert.equals(t:count(), 1)
  end)
end)
