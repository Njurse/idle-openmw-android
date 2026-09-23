-- tests/spec/bridge_spec.lua
-- The engine <-> host bridge (scripts/idle/bridge.lua).
--
-- The bridge is the contract between this mod and whatever sits on top of it (the Android
-- layer, a desktop tool, a monitor). So the tests are about the CONTRACT: a bad request
-- gets a structured error rather than no answer, a missing source is reported as
-- unavailable rather than as a lie, and a handler that throws does not take the bridge down.
describe('idle.bridge', function()
  local bridge = require('scripts.idle.bridge')
  local json = require('scripts.idle.json')

  local function make(sources, options)
    -- these must satisfy the frozen schema, because responses are now validated before they
    -- are sent; a fixture that violates it is exactly what the validation should catch
    return bridge.new(sources or {
      capabilities = function() return { revision = 129 } end,
      player = function() return { id = 'p1', kind = 'player', name = 'DeepSeek', gold = 12 } end,
      cell = function() return { id = 'ship cabin', kind = 'cell', name = 'Imperial Prison Ship' } end,
      entities = function(params)
        return { actors = { { id = 'n1', kind = 'npc', name = 'guard',
                              distance = params and params.radius or 0 } } }
      end,
      quests = function() return { { id = 'a1', stage = 10 } } end,
      topics = function() return { { topic = 'orders' } } end,
      ui = function() return { paused = false } end,
      uiTarget = function() return { id = 'd1', kind = 'door', name = 'hatch' } end,
    }, options)
  end

  --- Answer a request the way a host does: through the prefixed line protocol.
  local function ask(b, request)
    local line = b:handleLine(json.encode(request))
    assert.is_not_nil(line, 'bridge returned no line for ' .. json.encode(request))
    assert.equals(bridge.PREFIX, line:sub(1, #bridge.PREFIX))
    local envelope, err = json.decode(line:sub(#bridge.PREFIX + 1))
    assert.is_nil(err)
    return envelope
  end

  describe('the line protocol', function()
    it('answers every response under a greppable prefix', function()
      assert.equals('IDLEAPI ', bridge.PREFIX)
    end)

    it('ignores blank lines and comments, so a host can annotate its request file', function()
      local b = make()
      assert.is_nil(b:handleLine(''))
      assert.is_nil(b:handleLine('   '))
      assert.is_nil(b:handleLine('# not a request'))
      assert.is_nil(b:handleLine(nil))
    end)

    it('answers malformed JSON with an error and echoes the input', function()
      local b = make()
      local line = b:handleLine('{not json')
      local envelope = json.decode(line:sub(#bridge.PREFIX + 1))
      assert.is_false(envelope.ok)
      assert.is_not_nil(envelope.error)
      assert.is_not_nil(envelope.echo)
    end)
  end)

  describe('methods', function()
    it('answers ping with identity', function()
      local envelope = ask(make(), { method = 'ping' })
      assert.is_true(envelope.ok)
      assert.equals('idle-openmw', envelope.result.mod)
      assert.equals(bridge.VERSION, envelope.result.api)
    end)

    it('is self-describing, so a host need not hard-code us', function()
      local envelope = ask(make(), { method = 'schema' })
      assert.is_true(envelope.ok)
      assert.is_true(#envelope.result.methods > 0)
      local names = {}
      for _, method in ipairs(envelope.result.methods) do names[method.name] = true end
      assert.is_true(names['cell.current'])
      assert.is_true(names['entities.nearby'])
      assert.is_true(names.action)
    end)

    it('serves the runtime sources', function()
      local envelope = ask(make(), { method = 'player' })
      assert.is_true(envelope.ok)
      assert.equals('DeepSeek', envelope.result.name)
    end)

    it('passes params to the source', function()
      local envelope = ask(make(), { method = 'entities.nearby', params = { radius = 512 } })
      assert.is_true(envelope.ok, tostring(envelope.error))
      -- entities.nearby answers a map of kind -> list, so the radius shows up on the entries
      assert.equals(512, envelope.result.actors[1].distance)
    end)

    it('echoes the id so a host can match answers to requests', function()
      local envelope = ask(make(), { id = 99, method = 'player' })
      assert.equals(99, envelope.id)
    end)
  end)

  describe('failure isolation', function()
    it('names an unknown method and hints at the schema', function()
      local envelope = ask(make(), { method = 'nope' })
      assert.is_false(envelope.ok)
      assert.is_true(envelope.error:find('unknown method', 1, true) ~= nil)
      assert.is_not_nil(envelope.hint)
    end)

    it('requires a method', function()
      local envelope = ask(make(), { id = 1 })
      assert.is_false(envelope.ok)
    end)

    it('reports a missing source as unavailable, not as an empty answer', function()
      local envelope = ask(make({ player = function() return {} end }), { method = 'quests.active' })
      assert.is_false(envelope.ok)
      assert.is_true(envelope.error:find('unavailable', 1, true) ~= nil)
    end)

    it('survives a source that throws', function()
      local b = make({ player = function() error('boom') end })
      local envelope = ask(b, { method = 'player' })
      assert.is_false(envelope.ok)
      assert.is_true(envelope.error:find('boom', 1, true) ~= nil)
      -- and the bridge still works afterwards
      assert.is_true(ask(b, { method = 'ping' }).ok)
    end)

    it('rejects a non-object request', function()
      local b = make()
      local envelope = b:dispatch('not a table')
      assert.is_false(envelope.ok)
    end)
  end)

  describe('response validation', function()
    it('passes a schema-sound answer through', function()
      local envelope = ask(make(), { method = 'player' })
      assert.is_true(envelope.ok)
      assert.is_nil(envelope.problems)
    end)

    it('REFUSES an answer that violates the schema, naming the fields', function()
      -- sending a broken shape is worse than sending an error: the host would parse it
      -- wrongly and silently
      local b = make({ player = function() return { name = 'no id, no kind' } end })
      local envelope = ask(b, { method = 'player' })
      assert.is_false(envelope.ok)
      assert.is_true(envelope.error:find('schema violation', 1, true) ~= nil, envelope.error)
      assert.is_true(#envelope.problems > 0)
    end)

    it('catches a wrong type inside a valid-looking entity', function()
      local b = make({ player = function()
        return { id = 'p1', kind = 'player', gold = 'lots' }
      end })
      local envelope = ask(b, { method = 'player' })
      assert.is_false(envelope.ok)
      assert.is_true(envelope.problems[1]:find('gold', 1, true) ~= nil, envelope.problems[1])
    end)

    it('validates a list, saying WHICH entry was bad', function()
      local b = make({ uiInteractables = function()
        return { { id = 'a', kind = 'door' }, { kind = 'door' } }
      end })
      local envelope = ask(b, { method = 'ui.interactables' })
      assert.is_false(envelope.ok)
      assert.is_true(envelope.problems[1]:find('[2]', 1, true) ~= nil, envelope.problems[1])
    end)

    it('validates each bucket of an entity map', function()
      local b = make({ entities = function() return { doors = { { kind = 'door' } } } end })
      local envelope = ask(b, { method = 'entities.nearby' })
      assert.is_false(envelope.ok)
      assert.is_true(envelope.problems[1]:find('doors', 1, true) ~= nil, envelope.problems[1])
    end)

    it('does not object to an unavailable source', function()
      -- nil means "no answer", which the unavailable path already reports
      local b = make({ cell = function() return nil end })
      local envelope = ask(b, { method = 'cell.current' })
      assert.is_true(envelope.ok)
    end)
  end)

  describe('actions', function()
    it('refuses an action when the build takes none', function()
      local envelope = ask(make(), { method = 'action', params = { goal = 'roam' } })
      assert.is_false(envelope.ok)
    end)

    it('routes an action to the director and reports what happened', function()
      local seen = {}
      local b = make(nil, { onAction = function(goal, ttl)
        seen.goal, seen.ttl = goal, ttl
        return { accepted = true, goal = goal }
      end })
      local envelope = ask(b, { method = 'action', params = { goal = 'go_town', ttl = 60 } })
      assert.is_true(envelope.ok)
      assert.equals('go_town', seen.goal)
      assert.equals(60, seen.ttl)
      assert.is_true(envelope.result.accepted)
    end)

    it('needs a goal', function()
      local b = make(nil, { onAction = function() return {} end })
      local envelope = ask(b, { method = 'action', params = {} })
      assert.is_false(envelope.ok)
    end)
  end)

  describe('telemetry', function()
    it('pushes every available source in one line, so a host can just watch', function()
      local line = make():telemetry()
      assert.equals(bridge.PREFIX, line:sub(1, #bridge.PREFIX))
      local envelope = json.decode(line:sub(#bridge.PREFIX + 1))
      assert.is_true(envelope.telemetry)
      assert.equals('DeepSeek', envelope.result.player.name)
      assert.equals('Imperial Prison Ship', envelope.result.cell.name)
    end)

    it('omits a source that is missing rather than failing the push', function()
      local line = make({ player = function() return { name = 'x' } end }):telemetry()
      local envelope = json.decode(line:sub(#bridge.PREFIX + 1))
      assert.is_true(envelope.ok)
      assert.is_not_nil(envelope.result.player)
      assert.is_nil(envelope.result.cell)
    end)
  end)

  -- A method the self-description advertises but nothing serves is drift: the schema method is
  -- how a host discovers what it can call, so an unserved name is a promise broken silently.
  describe('the method table', function()
    it('serves every method it advertises', function()
      local locallyHandled = { ping = true, schema = true, action = true }
      for _, method in ipairs(bridge.METHODS) do
        if not locallyHandled[method.name] then
          assert.is_not_nil(bridge.SOURCE_METHODS[method.name],
            ('%s is advertised but wired to no source'):format(method.name))
        end
      end
    end)

    it('declares each method once', function()
      local seen = {}
      for _, method in ipairs(bridge.METHODS) do
        assert.is_nil(seen[method.name], ('%s is declared twice'):format(method.name))
        seen[method.name] = true
      end
    end)

    it('describes every method, so a host can explain itself to a user', function()
      for _, method in ipairs(bridge.METHODS) do
        assert.is_true(type(method.description) == 'string' and #method.description > 0,
          ('%s has no description'):format(method.name))
        assert.is_true(type(method.params) == 'table',
          ('%s has no params list'):format(method.name))
      end
    end)

    it('serves the registry methods, and a miss is a nil result rather than an error', function()
      -- a miss is not a failure: a stale id should come back as "nothing", not as a broken call
      local b = make({
        entityGet = function(params) return params and params.id == 'known'
          and { id = 'known', kind = 'door', name = 'hatch' } or nil end,
        registry = function() return { cap = 200, count = 1, evicted = 0, entities = {} } end,
      })
      local hit = ask(b, { method = 'entity.get', params = { id = 'known' }, id = 1 })
      assert.is_true(hit.ok)
      assert.equals(hit.result.name, 'hatch')

      local miss = ask(b, { method = 'entity.get', params = { id = 'stale' }, id = 2 })
      assert.is_true(miss.ok, 'a miss is not an error')
      assert.is_nil(miss.result)
      assert.equals(miss.id, 2)

      local listing = ask(b, { method = 'registry', id = 3 })
      assert.is_true(listing.ok)
      assert.equals(listing.result.cap, 200)
    end)
  end)
end)
