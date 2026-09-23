-- tests/spec/capabilities_spec.lua
-- "What can this engine actually do?" (scripts/runtime/capabilities.lua).
--
-- The point of these tests is the DEGRADATION contract: on an engine missing the
-- modern API the probe must report what is absent -- never throw, never claim a
-- capability, and never stay silent about a missing one.
describe('runtime.capabilities', function()
  local mocks = require('tests.mocks.openmw')
  local capabilities = require('scripts.runtime.capabilities')

  local function withEnv(spec, fn)
    local env = mocks.install(spec or {})
    local ok, err = pcall(fn, env)
    mocks.uninstall()
    if not ok then error(err, 0) end
  end

  describe('a modern engine', function()
    it('reports every capability present', function()
      withEnv({ apiRevision = 128 }, function(env)
        env.interfaces = env.interfaces or {}
        env.interfaces.Controls = { overrideMovementControls = function() end }
        env.camera.castRenderingRay = function() end
        local probe = capabilities.probe(env)
        assert.equals(probe.revision, 128)
        assert.is_true(probe.features.charGenFlag)
        assert.is_true(probe.features.uiModeStack)
        assert.is_true(probe.features.castRay)
        assert.is_true(probe.features.journalTopics)
        assert.is_true(probe.features.gmst)
        assert.is_true(probe.ok)
        assert.equals(#probe.missing, 0)
      end)
    end)
  end)

  describe('an old engine (0.48: no chargen flag, no UI stack, no journal topics)', function()
    local function stripped(env)
      env.types.Player.isCharGenFinished = nil
      env.ui._getUiModeStack = nil
      env.types.Player.journal = nil
      env.interfaces.Controls = nil
      return env
    end

    it('reports exactly what is missing, and is not ok', function()
      withEnv({ apiRevision = 40 }, function(env)
        stripped(env)
        local probe = capabilities.probe(env)
        assert.is_false(probe.ok)
        assert.is_false(probe.features.charGenFlag)
        assert.is_false(probe.features.uiModeStack)
        assert.is_false(probe.features.journalTopics)
        assert.is_false(probe.features.controlsOverride)
        -- and the things that ARE there are still reported as present
        assert.is_true(probe.features.castRay)
        assert.is_true(probe.features.gmst)
      end)
    end)

    it('flags the required capability, not just any', function()
      withEnv({}, function(env)
        stripped(env)
        local missing = capabilities.requiredMissing(capabilities.probe(env))
        assert.equals(#missing, 1)
        assert.equals(missing[1], 'charGenFlag')
      end)
    end)

    it('describes itself in one line, naming what is absent', function()
      withEnv({ apiRevision = 40 }, function(env)
        stripped(env)
        local line = capabilities.describe(capabilities.probe(env))
        assert.is_true(line:find('revision 40', 1, true) ~= nil)
        assert.is_true(line:find('MISSING', 1, true) ~= nil)
        assert.is_true(line:find('character-creation flag', 1, true) ~= nil)
      end)
    end)
  end)

  describe('robustness', function()
    it('survives a completely empty env', function()
      local probe = capabilities.probe({})
      assert.is_false(probe.ok)
      assert.is_nil(probe.revision)
      assert.is_true(#probe.missing > 0)
    end)

    it('survives nil', function()
      assert.is_false(capabilities.probe(nil).ok)
    end)

    it('does not throw when a probe itself throws', function()
      local probe = capabilities.probe(setmetatable({}, {
        __index = function() error('boom') end,
      }))
      assert.is_false(probe.ok) -- reported missing, not raised
    end)

    it('describes an unprobed value safely', function()
      assert.is_true(capabilities.describe(nil):find('not probed') ~= nil)
    end)
  end)
end)
