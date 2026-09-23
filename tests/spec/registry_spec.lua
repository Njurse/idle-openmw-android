-- tests/spec/registry_spec.lua
-- The bounded memory of named entities (scripts/idle/registry.lua).
--
-- The registry exists so a host can say "the hatch you told me about a second ago" without
-- being able to hold an engine object. Its two promises are what this spec is about: it
-- remembers enough to find the thing again, and it does not grow forever.
describe('idle.registry', function()
  local registry = require('scripts.idle.registry')

  local function entity(fields)
    local out = { id = 'e1', kind = 'door', recordId = 'ex_de_door_01', name = 'hatch' }
    for key, value in pairs(fields or {}) do out[key] = value end
    return out
  end

  describe('remember', function()
    it('stores an entity under the engine id', function()
      local reg = registry.new()
      reg:remember(entity({ id = 'hatch1' }))
      local got = reg:get('hatch1')
      assert.equals(got.kind, 'door')
      assert.equals(got.name, 'hatch')
      assert.is_true(got.remembered)
    end)

    it('refuses an entity with no id -- it could never be named again', function()
      local reg = registry.new()
      assert.is_nil(reg:remember({ kind = 'door', name = 'anonymous' }))
      assert.is_nil(reg:remember(entity({ id = '' })))
      assert.is_nil(reg:remember(nil))
      assert.equals(reg:count(), 0)
    end)

    it('refreshes a known entity instead of duplicating it', function()
      local reg = registry.new()
      reg:remember(entity({ id = 'npc1' }), 1)
      reg:remember(entity({ id = 'npc1', name = 'renamed' }), 5)
      assert.equals(reg:count(), 1)
      local got = reg:get('npc1')
      assert.equals(got.name, 'renamed')
      assert.equals(got.seen, 2)
      assert.equals(got.firstSeen, 1)
      assert.equals(got.lastSeen, 5)
    end)

    it('keeps the first sighting when a later read drops a field', function()
      local reg = registry.new()
      reg:remember(entity({ id = 'd1', recordId = 'a' }), 1)
      -- a partial read must not erase what we already knew
      reg:remember({ id = 'd1', kind = 'door' }, 2)
      assert.equals(reg:get('d1').recordId, 'a')
    end)

    it('stores a whole nearby list in one call', function()
      local reg = registry.new()
      local stored = reg:rememberAll({
        entity({ id = 'a' }), entity({ id = 'b' }), entity({ id = 'c' }),
      }, 10)
      assert.equals(stored, 3)
      assert.equals(reg:count(), 3)
      assert.equals(reg:rememberAll(nil, 11), 0)
    end)
  end)

  describe('identity, not state', function()
    it('hands back a COPY, so a caller cannot rewrite our memory', function()
      local reg = registry.new()
      reg:remember(entity({ id = 'x' }), 1)
      local got = reg:get('x')
      got.name = 'tampered'
      assert.equals(reg:get('x').name, 'hatch')
    end)

    it('remembers identity fields and the place it was last seen', function()
      local reg = registry.new()
      reg:remember(entity({
        id = 'z', formId = '12345', recordId = 'ex_hatch', name = 'hatch',
        position = { x = 1, y = 2, z = 3 }, cell = 'Imperial Prison Ship',
      }), 7)
      local got = reg:get('z')
      assert.equals(got.formId, '12345')
      assert.equals(got.cell, 'Imperial Prison Ship')
      assert.equals(got.position.z, 3)
      assert.equals(got.lastSeen, 7)
    end)
  end)

  describe('the cap', function()
    it('evicts the least recently seen first', function()
      local reg = registry.new(3)
      reg:remember(entity({ id = 'old' }), 1)
      reg:remember(entity({ id = 'mid' }), 2)
      reg:remember(entity({ id = 'new' }), 3)
      -- touching 'old' makes 'mid' the stalest, even though 'new' is older by first sighting
      reg:remember(entity({ id = 'old' }), 4)
      reg:remember(entity({ id = 'newest' }), 5)

      assert.equals(reg:count(), 3)
      assert.is_true(reg:has('old'), 'touched recently, so it stays')
      assert.is_true(reg:has('newest'))
      assert.is_true(reg:has('new'))
      assert.is_false(reg:has('mid'), 'the stalest entity should have been evicted')
      assert.equals(reg:evictedCount(), 1)
    end)

    it('touching an entry is what protects it from eviction', function()
      local reg = registry.new(2)
      reg:remember(entity({ id = 'a' }), 1)
      reg:remember(entity({ id = 'b' }), 2)
      reg:remember(entity({ id = 'a' }), 3) -- a -> most recent, so b is now the stalest
      reg:remember(entity({ id = 'c' }), 4)
      assert.is_true(reg:has('a'))
      assert.is_true(reg:has('c'))
      assert.is_false(reg:has('b'))
    end)

    it('never grows past the cap, however many entities it sees', function()
      local reg = registry.new(10)
      for index = 1, 500 do
        reg:remember(entity({ id = 'e' .. tostring(index) }), index)
      end
      assert.equals(reg:count(), 10)
      -- and what is left is the most recent ten
      assert.is_true(reg:has('e500'))
      assert.is_true(reg:has('e491'))
      assert.is_false(reg:has('e490'))
      assert.equals(reg:evictedCount(), 490)
    end)

    it('falls back to the default cap when handed nonsense', function()
      assert.equals(registry.new(0).cap, registry.DEFAULT_CAP)
      assert.equals(registry.new(-5).cap, registry.DEFAULT_CAP)
      assert.equals(registry.new('lots').cap, registry.DEFAULT_CAP)
      assert.equals(registry.new(nil).cap, registry.DEFAULT_CAP)
    end)
  end)

  describe('list', function()
    it('is ordered most recently seen first, and stable', function()
      local reg = registry.new()
      reg:remember(entity({ id = 'a' }), 1)
      reg:remember(entity({ id = 'b' }), 2)
      reg:remember(entity({ id = 'c' }), 2) -- same tick: ties break by id, not hash order
      local ids = {}
      for index, entry in ipairs(reg:list()) do ids[index] = entry.id end
      assert.equals(#ids, 3)
      assert.equals(ids[1], 'b')
      assert.equals(ids[2], 'c')
      assert.equals(ids[3], 'a')
    end)

    it('can be filtered by kind', function()
      local reg = registry.new()
      reg:remember(entity({ id = 'door1', kind = 'door' }), 1)
      reg:remember(entity({ id = 'npc1', kind = 'npc' }), 2)
      assert.equals(#reg:list(), 2)
      assert.equals(#reg:list('npc'), 1)
      assert.equals(reg:list('npc')[1].id, 'npc1')
      assert.equals(#reg:list('creature'), 0)
    end)
  end)

  describe('forget and clear', function()
    it('forgets one entity', function()
      local reg = registry.new()
      reg:remember(entity({ id = 'a' }))
      assert.is_true(reg:forget('a'))
      assert.is_false(reg:has('a'))
      assert.is_nil(reg:get('a'))
      assert.is_false(reg:forget('a'), 'forgetting twice is not an error, just not a change')
      assert.equals(reg:count(), 0)
    end)

    it('clears everything and reports how much it held', function()
      local reg = registry.new()
      reg:remember(entity({ id = 'a' }))
      reg:remember(entity({ id = 'b' }))
      assert.equals(reg:clear(), 2)
      assert.equals(reg:count(), 0)
      assert.equals(#reg:list(), 0)
    end)
  end)

  describe('describe', function()
    it('names an entry for a human or a log line', function()
      local reg = registry.new()
      reg:remember(entity({ id = 'h', name = 'hatch', kind = 'door' }), 3)
      local line = registry.describe(reg:get('h'))
      assert.is_true(line:find('hatch') ~= nil)
      assert.is_true(line:find('door') ~= nil)
      assert.is_true(line:find('t=3') ~= nil)
      assert.equals(registry.describe(nil), 'unknown entity')
    end)
  end)
end)
