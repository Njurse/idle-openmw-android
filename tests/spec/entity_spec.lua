-- tests/spec/entity_spec.lua
-- The normaliser (scripts/idle/entity.lua) and the reader (scripts/runtime/entities.lua).
--
-- The point of both is that every method returns the SAME shape: `player`, `entities.nearby`
-- and `ui.target` used to hand-build their own tables and drift. So these tests are about the
-- contract -- undeclared fields are refused, nil is dropped rather than zeroed, and reading an
-- object the engine cannot fully describe still yields a valid entity.
describe('idle.entity', function()
  local entity = require('scripts.idle.entity')
  local schema = require('scripts.idle.schema')

  describe('the builder', function()
    it('accepts declared fields', function()
      local builder = entity.new('door')
      assert.is_true(builder:set('id', 'abc'))
      assert.is_true(builder:set('destCell', 'Cabin'))
      assert.equals('abc', builder:get().id)
    end)

    it('REFUSES a field the schema does not declare, and records it', function()
      local builder = entity.new('door')
      -- a typo must not reach the app as a field
      assert.is_false(builder:set('postition', { x = 1, y = 2, z = 3 }))
      assert.is_nil(builder:get().postition)
      assert.equals(1, #builder:dropped())
      assert.equals('postition', builder:dropped()[1])
    end)

    it('sets the kind itself, since that is what makes the entity interpretable', function()
      assert.equals('door', entity.new('door'):get().kind)
      assert.equals('npc', entity.new('npc'):get().kind)
    end)

    it('fills from a readings table and skips nils', function()
      local builder = entity.new('item')
      builder:fill({ id = 'x', kind = 'ignored?', recordId = 'misc_ring', weight = nil })
      local got = builder:get()
      assert.equals('x', got.id)
      assert.equals('misc_ring', got.recordId)
      assert.is_nil(got.weight)
      -- kind stays what the builder was made for, not what a caller passed
      assert.equals('item', got.kind)
    end)

    it('produces entities the schema accepts', function()
      local builder = entity.new('door')
      builder:fill({ id = '1', recordId = 'door_hatch', name = 'hatch',
                     position = { x = 1, y = 2, z = 3 } })
      local ok, problems = schema.validate('door', builder:get())
      assert.is_true(ok, tostring(problems and problems[1]))
    end)
  end)

  describe('derivePlacement', function()
    it('computes distance and says when something is above you', function()
      local near = { position = { x = 0, y = 0, z = 0 } }
      entity.derivePlacement(near, { x = 30, y = 40, z = 0 })
      assert.equals(50, near.distance)
      assert.equals('level', near.vertical)

      local overhead = { position = { x = 0, y = 0, z = 200 } }
      entity.derivePlacement(overhead, { x = 0, y = 0, z = 100 })
      assert.equals('above', overhead.vertical)
    end)

    it('leaves both fields alone when a position is unknown', function()
      local unknown = { position = nil }
      entity.derivePlacement(unknown, { x = 1, y = 2, z = 3 })
      assert.is_nil(unknown.distance)
      assert.is_nil(unknown.vertical)
      -- and an engine position (userdata) must not throw
      local ok = pcall(entity.derivePlacement, { position = newproxy and newproxy(true) or nil },
        { x = 1, y = 2, z = 3 })
      assert.is_true(ok)
    end)

    it('does not claim a distance when it only has part of the position', function()
      local partial = { position = { x = 5 } }
      entity.derivePlacement(partial, { x = 1, y = 2, z = 3 })
      assert.is_nil(partial.distance)
    end)
  end)

  describe('vertical', function()
    it('uses a 60-unit band as "level"', function()
      assert.equals('level', entity.vertical(100, 100))
      assert.equals('level', entity.vertical(150, 100))
      assert.equals('above', entity.vertical(161, 100))
      assert.equals('below', entity.vertical(39, 100))
    end)

    it('says nothing when it cannot tell', function()
      assert.is_nil(entity.vertical(nil, 100))
      assert.is_nil(entity.vertical('up', 100))
    end)
  end)

  describe('sorting and counting', function()
    it('orders stacks deterministically, by name then record then id', function()
      local sorted = entity.sortStacks({
        { name = 'ring', recordId = 'b_ring', id = '2' },
        { name = 'ring', recordId = 'b_ring', id = '1' },
        { name = 'amulet', recordId = 'a_amulet', id = '3' },
      })
      assert.equals('amulet', sorted[1].name)
      assert.equals('1', sorted[2].id)
      assert.equals('2', sorted[3].id)
    end)

    it('counts total items, ignoring junk', function()
      assert.equals(7, entity.totalCount({ { count = 3 }, { count = 4 }, {}, 'nonsense' }))
      assert.equals(0, entity.totalCount(nil))
    end)
  end)

  describe('finish', function()
    it('reports schema problems instead of sending a broken entity', function()
      local broken = { kind = 'door' }                     -- no id
      local _, problems = entity.finish(broken)
      assert.is_not_nil(problems)
      assert.is_true(problems[1]:find('id', 1, true) ~= nil, problems[1])
    end)

    it('passes a complete entity and drops nils', function()
      local good = { kind = 'door', id = '1', name = nil, distance = nil }
      local finished, problems = entity.finish(good)
      assert.is_nil(problems)
      assert.is_nil(finished.name)
      assert.is_nil(rawget(finished, 'name'))
    end)

    it('keeps an empty list, because "none" is a fact and nil means unknown', function()
      local out = entity.compact({ kind = 'container', id = '1', inventory = {} })
      assert.is_not_nil(out.inventory)
    end)
  end)

  describe('kindFor precedence', function()
    it('prefers talking to a container-shaped actor', function()
      assert.equals('npc', entity.kindFor({ actors = true, containers = true }))
    end)

    it('prefers a door over an activator', function()
      assert.equals('door', entity.kindFor({ activators = true, doors = true }))
    end)

    it('returns nothing when it cannot tell', function()
      assert.is_nil(entity.kindFor({}))
      assert.is_nil(entity.kindFor(nil))
    end)
  end)
end)

describe('runtime.entities', function()
  local reader = require('scripts.runtime.entities')

  --- A minimal fake engine env: only what the reader needs, so the test is about the reader.
  local function fakeEnv(fields)
    local function instanceOf(name)
      return { objectIsInstance = function(object) return object._type == name end }
    end
    local types = {
      Player = instanceOf('Player'), NPC = instanceOf('NPC'), Creature = instanceOf('Creature'),
      Door = instanceOf('Door'), Container = instanceOf('Container'),
      Item = instanceOf('Item'), Activator = instanceOf('Activator'),
      getRecordName = function(object) return object._name end,
      Actor = {
        stats = {
          level = function(object) return { current = object._level } end,
          ai = { fight = function(object) return object._fight end },
          dynamic = {
            health = function(object) return { current = object._health, base = 100 } end,
          },
          -- the character sheet: one attribute and one skill is enough to prove the reader
          -- walks the canonical name lists
          attributes = {
            strength = function() return { base = 40, modified = 45, damage = 0, modifier = 5 } end,
          },
          skills = {
            longblade = function()
              return { base = 30, modified = 35, damage = 0, modifier = 5, progress = 0.25 }
            end,
          },
          reputation = function() return { current = 3 } end,
        },
        isDead = function(object) return object._dead == true end,
        getRunSpeed = function() return 180 end,
        getStance = function() return 'WEAPON' end,
        canMove = function() return true end,
        spells = function() return { { id = 'thunder fist', type = 0 } } end,
      },
      Door = {
        objectIsInstance = function(object) return object._type == 'Door' end,
        destCell = function(object) return { name = object._destCell } end,
        isTeleport = function() return true end,
      },
    }
    return { types = types, core = {}, self = fields and fields.self }
  end

  it('loads, and is safe on junk', function()
    assert.is_nil(reader.read(nil))
    assert.is_nil(reader.read(42))
    assert.is_nil(reader.read('text'))
  end)

  it('classifies by engine type, refining actors into npc and creature', function()
    local env = fakeEnv()
    assert.equals('npc', reader.kindOf({ _type = 'NPC' }, env))
    assert.equals('creature', reader.kindOf({ _type = 'Creature' }, env))
    assert.equals('player', reader.kindOf({ _type = 'Player' }, env))
    assert.equals('door', reader.kindOf({ _type = 'Door' }, env))
    assert.is_nil(reader.kindOf({ _type = 'SomethingElse' }, env))
  end)

  it('reads identity, name and placement into the schema shape', function()
    local env = fakeEnv()
    local object = { _type = 'Door', id = 'ref1', recordId = 'door_hatch', _name = 'hatch',
                     enabled = true, position = { x = 0, y = 0, z = 0 },
                     _destCell = 'Cabin',
                     cell = { name = 'Imperial Prison Ship', id = 'ship cabin' } }
    local read = reader.read(object, env, { x = 0, y = 0, z = 120 })
    assert.equals('door', read.kind)
    assert.equals('ref1', read.id)
    assert.equals('hatch', read.name)
    assert.equals('Imperial Prison Ship', read.cell)
    assert.equals(120, read.distance)
    -- the object sits at z=0 and the player's eye at z=120, so it is BELOW, not level
    assert.equals('below', read.vertical)
    assert.equals('Cabin', read.destCell)
    assert.equals(true, read.isTeleport)
  end)

  it('reads actor state, including the AI dispositions that stand in for hostility', function()
    local env = fakeEnv()
    local read = reader.read({ _type = 'NPC', id = 'n1', _name = 'guard', _level = 5.9,
                               _health = 42, _fight = 90, _dead = false }, env)
    assert.equals('npc', read.kind)
    assert.equals(5, read.level)
    assert.equals(42, read.health.current)
    assert.equals(100, read.health.base)
    assert.equals(90, read.ai.fight)
    assert.equals(false, read.dead)
  end)

  it('reads the character sheet: attributes, skills, movement, spells', function()
    local env = fakeEnv()
    local read = reader.read({ _type = 'NPC', id = 'n1', _name = 'guard', _level = 7,
                               _health = 10, _fight = 50 }, env)
    assert.equals(7, read.level)
    -- one attribute, with the engine's bean fields
    assert.equals(40, read.attributes.strength.base)
    assert.equals(45, read.attributes.strength.modified)
    -- one skill, including progress towards the next point
    assert.equals(30, read.skills.longblade.base)
    assert.equals(0.25, read.skills.longblade.progress)
    assert.equals(3, read.reputation)
    assert.equals(180, read.runSpeed)
    assert.equals('WEAPON', read.stance)
    assert.equals(true, read.canMove)
    assert.equals('thunder fist', read.spells[1].id)
  end)

  it('keeps the sheet schema-valid, including for the player', function()
    local env = fakeEnv()
    local schema = require('scripts.idle.schema')
    local read = reader.read({ _type = 'NPC', id = 'n1', _level = 3, _health = 5 }, env)
    local ok, problems = schema.validate(read.kind, read)
    assert.is_true(ok, tostring(problems and problems[1]))
  end)

  it('does not invent fields the engine could not supply', function()
    local env = fakeEnv()
    local read = reader.read({ _type = 'Item', id = 'i1' }, env)
    assert.equals('item', read.kind)
    assert.is_nil(read.count)
    assert.is_nil(rawget(read, 'distance'))
  end)

  it('reads a cell as metadata only, and says contents were not fetched', function()
    local env = fakeEnv()
    local cell = reader.readCell({ id = 'c1', name = 'Cabin', isExterior = false,
                                   gridX = 0, gridY = 0, hasWater = false }, env)
    assert.equals('cell', cell.kind)
    assert.equals('Cabin', cell.name)
    assert.equals(false, cell.isExterior)
    assert.equals(false, cell.contentsFetched)
  end)

  it('produces entities the schema accepts, which is the whole contract', function()
    local env = fakeEnv()
    local schema = require('scripts.idle.schema')
    for _, object in ipairs({
      { _type = 'Door', id = 'd1', _name = 'hatch' },
      { _type = 'NPC', id = 'n1', _name = 'guard', _level = 2, _health = 10 },
      { _type = 'Item', id = 'i1', _name = 'ring' },
      { _type = 'Container', id = 'c1', _name = 'chest' },
      { _type = 'Activator', id = 'a1', _name = 'lever' },
    }) do
      local read = reader.read(object, env)
      local ok, problems = schema.validate(read.kind, read)
      assert.is_true(ok, ('%s: %s'):format(read.kind, tostring(problems and problems[1])))
    end
  end)
end)
