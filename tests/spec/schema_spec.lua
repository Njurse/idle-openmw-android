-- tests/spec/schema_spec.lua
-- The data model (scripts/idle/schema.lua): the contract the Android layer is written against.
--
-- These tests exist to make drift LOUD. If someone renames a field, changes its type, or
-- quietly adds one without declaring it, the app would break at runtime with nothing to
-- catch it. So the field names and types are pinned here, and the validator is tested
-- against the mistakes that actually happen.
describe('idle.schema', function()
  local schema = require('scripts.idle.schema')

  -- Lua 5.1 and LuaJIT can make a bare userdata with `newproxy`; Lua 5.4 cannot, so the
  -- userdata half of a test is guarded exactly as tests/spec/userdata_spec.lua does it.
  local hasNewproxy = type(newproxy) == 'function'

  describe('the declaration itself', function()
    it('is versioned', function()
      assert.equals('number', type(schema.VERSION))
      assert.is_true(schema.VERSION >= 1)
    end)

    it('declares at least the kinds the API serves', function()
      for _, kind in ipairs({ 'player', 'npc', 'creature', 'door', 'container', 'item',
                              'activator', 'cell', 'record' }) do
        assert.is_not_nil(schema.KINDS[kind], 'missing kind: ' .. kind)
      end
    end)

    it('gives every field a name, a known type and a note', function()
      for kind, definition in pairs(schema.KINDS) do
        assert.is_true(#definition.fields > 0, kind .. ' declares no fields')
        for _, entry in ipairs(definition.fields) do
          assert.is_not_nil(entry.name, kind .. ' has an unnamed field')
          assert.is_not_nil(schema.TYPE[entry.type],
            ('%s.%s has unknown type %s'):format(kind, entry.name, tostring(entry.type)))
          assert.is_not_nil(entry.note, ('%s.%s has no note'):format(kind, entry.name))
        end
      end
    end)

    it('says which script context serves each kind', function()
      for kind, definition in pairs(schema.KINDS) do
        assert.is_not_nil(definition.context, kind .. ' does not say its context')
      end
      -- the survey kinds are global-only, which is why they are not served by the bridge's
      -- own script
      assert.equals('global', schema.KINDS.cell.context)
    end)

    it('names every field of every kind uniquely within that kind', function()
      for kind, definition in pairs(schema.KINDS) do
        local seen = {}
        for _, entry in ipairs(definition.fields) do
          assert.is_nil(seen[entry.name], ('%s declares %s twice'):format(kind, entry.name))
          seen[entry.name] = true
        end
      end
    end)
  end)

  describe('identity', function()
    it('requires a unique id and a kind on every object-backed entity', function()
      for _, kind in ipairs({ 'player', 'npc', 'creature', 'door', 'container', 'item', 'activator' }) do
        local names = schema.fieldsOf(kind)
        local required = {}
        for _, entry in ipairs(schema.KINDS[kind].fields) do
          if entry.required then required[entry.name] = true end
        end
        assert.is_true(required.id == true, kind .. ' does not require id')
        assert.is_true(required.kind == true, kind .. ' does not require kind')
      end
    end)

    it('does NOT require recordId, because it is a template and not unique', function()
      local required = {}
      for _, entry in ipairs(schema.KINDS.npc.fields) do
        if entry.required then required[entry.name] = true end
      end
      assert.is_nil(required.recordId)
      -- and the note says so, because that is the trap
      local note = nil
      for _, entry in ipairs(schema.KINDS.npc.fields) do
        if entry.name == 'recordId' then note = entry.note end
      end
      assert.is_true(note:find('NOT unique', 1, true) ~= nil, note)
    end)

    it('carries formId for a deterministic cross-save address', function()
      assert.is_true(#schema.fieldsOf('npc') > 0)
      local hasFormId = false
      for _, entry in ipairs(schema.KINDS.npc.fields) do
        if entry.name == 'formId' then hasFormId = true end
      end
      assert.is_true(hasFormId)
    end)
  end)

  describe('the declared gaps', function()
    it('states that projectiles and hostility are unavailable, with a reason', function()
      for _, gap in ipairs({ 'projectiles', 'hostile', 'aiPackage' }) do
        assert.is_not_nil(schema.AVAILABILITY[gap], 'gap not declared: ' .. gap)
        assert.is_false(schema.AVAILABILITY[gap].available)
        assert.is_true(#schema.AVAILABILITY[gap].reason > 20,
          gap .. ' needs a real reason, not a shrug')
      end
    end)

    it('does not pretend hostility is a boolean field', function()
      -- 0.51 has no hostility query, so the honest modelling is dispositions; a boolean
      -- field would be a lie the app would build on
      for _, kind in ipairs({ 'npc', 'creature', 'player' }) do
        for _, entry in ipairs(schema.KINDS[kind].fields) do
          assert.is_true(entry.name ~= 'hostile',
            kind .. ' declares a hostile flag the engine cannot supply')
          assert.is_true(entry.name ~= 'inCombat',
            kind .. ' declares inCombat, which 0.51 cannot answer')
        end
      end
    end)

    it('offers the proxies that do exist', function()
      local names = schema.fieldsOf('npc')
      local present = {}
      for _, name in ipairs(names) do present[name] = true end
      assert.is_true(present.disposition, 'NPC disposal needs the disposition proxy')
      assert.is_true(present.ai, 'needs the ai dispositions')
      assert.is_true(present.dead, 'needs isDead')
    end)
  end)

  describe('validate', function()
    local good = { id = '12345', kind = 'door', recordId = 'door_ship_cabin', name = 'hatch' }

    it('accepts a well-formed entity', function()
      local ok, problems = schema.validate('door', good)
      assert.is_true(ok, tostring(problems and problems[1]))
    end)

    it('reports a missing required field', function()
      local ok, problems = schema.validate('door', { kind = 'door' })
      assert.is_false(ok)
      local found = false
      for _, problem in ipairs(problems) do
        if problem:find('missing required field: id', 1, true) then found = true end
      end
      assert.is_true(found, 'did not report the missing id')
    end)

    it('reports an UNDECLARED field, so drift is caught rather than shipped', function()
      local copy = { id = '1', kind = 'door', postition = { x = 1, y = 2, z = 3 } }
      local ok, problems = schema.validate('door', copy)
      assert.is_false(ok)
      local found = false
      for _, problem in ipairs(problems) do
        if problem:find('undeclared field: postition', 1, true) then found = true end
      end
      assert.is_true(found, 'did not report the undeclared field')
    end)

    it('reports a wrong type', function()
      local ok, problems = schema.validate('door', { id = '1', kind = 'door', distance = 'far' })
      assert.is_false(ok)
      local found = false
      for _, problem in ipairs(problems) do
        if problem:find('should be number', 1, true) then found = true end
      end
      assert.is_true(found)
    end)

    it('accepts a plain position table', function()
      local ok = schema.validate('door', { id = '1', kind = 'door',
        position = { x = 1, y = 2, z = 3 } })
      assert.is_true(ok)
    end)

    it('accepts an ENGINE position (userdata), which is what the engine actually gives', function()
      -- engine values are userdata in 0.51; a validator that demands a table rejected every
      -- real reading once already
      if not hasNewproxy then
        -- Lua 5.4 cannot create bare userdata; the checker is still asserted to exist
        assert.equals('function', type(schema.TYPE.position))
        assert.is_true(schema.TYPE.position({ x = 1, y = 2, z = 3 }))
        return
      end
      local vector = newproxy(true)
      getmetatable(vector).__index = function() return 42 end
      assert.equals('userdata', type(vector))
      local ok, problems = schema.validate('door', { id = '1', kind = 'door', position = vector })
      assert.is_true(ok, tostring(problems and problems[1]))
    end)

    it('rejects a half-formed position', function()
      local ok = schema.validate('door', { id = '1', kind = 'door', position = { x = 1, y = 2 } })
      assert.is_false(ok)
    end)

    it('rejects an integer field given a fraction', function()
      local ok = schema.validate('item', { id = '1', kind = 'item', count = 1.5 })
      assert.is_false(ok)
      assert.is_true(schema.validate('item', { id = '1', kind = 'item', count = 2 }))
    end)

    it('accepts omitted optional fields (nil means unknown, not zero)', function()
      assert.is_true(schema.validate('door', { id = '1', kind = 'door' }))
    end)

    it('never throws, whatever it is handed', function()
      for _, junk in ipairs({ {}, nil, 42, 'text', {} }) do
        local ok = pcall(schema.validate, 'door', junk)
        assert.is_true(ok, 'validate threw on ' .. tostring(junk))
        pcall(schema.validate, 'not-a-kind', junk)
      end
      local ok = schema.validate('no-such-kind', { id = '1' })
      assert.is_false(ok)
    end)
  end)

  describe('validateList', function()
    it('passes a list of good entities', function()
      local ok, problems = schema.validateList('door', {
        { id = '1', kind = 'door' }, { id = '2', kind = 'door' },
      })
      assert.is_true(ok, tostring(problems and problems[1]))
    end)

    it('says WHICH entry was bad', function()
      local ok, problems = schema.validateList('door', {
        { id = '1', kind = 'door' }, { kind = 'door' },
      })
      assert.is_false(ok)
      assert.is_true(problems[1]:find('[2]', 1, true) ~= nil, problems[1])
    end)
  end)

  describe('describe (what the host reads instead of our source)', function()
    it('is deterministic, so two descriptions are diffable', function()
      local json = require('scripts.idle.json')
      assert.equals(json.encode(schema.describe()), json.encode(schema.describe()))
    end)

    it('lists kinds sorted, with their fields and the declared gaps', function()
      local described = schema.describe()
      assert.equals(schema.VERSION, described.version)
      assert.is_true(#described.kinds > 0)
      local previous = ''
      for _, kind in ipairs(described.kinds) do
        assert.is_true(kind.kind > previous, 'kinds are not sorted: ' .. kind.kind)
        previous = kind.kind
        assert.is_true(#kind.fields > 0)
      end
      local gaps = {}
      for _, gap in ipairs(described.unavailable) do gaps[gap.name] = true end
      assert.is_true(gaps.projectiles)
    end)

    it('survives a JSON round trip, which is how the host receives it', function()
      local json = require('scripts.idle.json')
      local decoded, err = json.decode(json.encode(schema.describe()))
      assert.is_nil(err)
      assert.equals(schema.VERSION, decoded.version)
      assert.is_true(#decoded.kinds > 0)
      -- a JSON object decodes to a Lua table, and the field names must survive verbatim
      assert.equals('table', type(decoded.kinds[1]))
      assert.is_not_nil(decoded.kinds[1].kind)
      assert.is_not_nil(decoded.kinds[1].fields[1].name)
    end)

    it('accepts the `list` field every nearby row carries', function()
      -- The reader has always set it (runtime/entities.lua:612) while the schema did not declare
      -- it, so the validator rejected every row and `entities.nearby` returned nothing at all:
      -- 'schema violation: actors [1] undeclared field: list'.
      for _, kind in ipairs({ 'player', 'npc', 'creature', 'door', 'container', 'item' }) do
        local ok, problems = schema.validate(kind, {
          id = '@1', kind = kind, list = 'actors', position = { x = 0, y = 0, z = 0 },
        })
        assert.is_true(ok, kind .. ': ' .. tostring(problems and problems[1]))
      end
      -- and the DECLARED schema must show it, or a host cannot know the field exists
      local described = schema.describe()
      local found = false
      for _, kind in ipairs(described.kinds) do
        if kind.kind == 'npc' then
          for _, field in ipairs(kind.fields) do
            if field.name == 'list' then found = true end
          end
        end
      end
      assert.is_true(found)
    end)
  end)
end)
