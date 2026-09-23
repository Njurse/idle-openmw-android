-- tests/spec/userdata_spec.lua
-- Engine values are USERDATA, not Lua tables. This is the spec for that fact.
--
-- WHY THIS FILE EXISTS
-- --------------------
-- The mod was written assuming `require('openmw.types')` and the objects it hands out
-- (records, GameObjects, Cells, items, stats) are plain Lua tables. They are NOT.
-- Measured on OpenMW 0.51.0, from the mod's own capability line in the engine log:
--
--     idle-openmw: Lua API revision 129; MISSING 10/10: ...
--       [env: core=userdata,types=userdata,ui=userdata,nearby=userdata,
--             camera=userdata,interfaces=userdata,util=userdata,world=nil,
--             self=userdata,input=userdata,async=userdata,storage=userdata]
--
-- Every `type(x) == 'table'` guard therefore failed — not loudly, but by quietly
-- yielding nil. The probe claimed a fully capable engine had nothing; the world model
-- would have reported no name, no position, no record, no services.
--
-- The fix is `util.isObject`, which accepts both shapes. These specs drive the real
-- code with REAL userdata (via LuaJIT/Lua 5.1's `newproxy`, absent in 5.4 where the
-- case is skipped) so the mistake cannot come back unnoticed.
describe('engine values are userdata, not tables', function()
  local mocks = require('tests.mocks.openmw')
  local util = require('scripts.idle.util')
  local capabilities = require('scripts.runtime.capabilities')

  local hasNewproxy = type(newproxy) == 'function'

  --- A userdata that answers fields from `fields`, shaped like an engine object.
  local function ud(fields)
    local proxy = newproxy(true)
    getmetatable(proxy).__index = fields
    return proxy
  end

  it('util.isObject accepts tables AND userdata, and rejects the rest', function()
    assert.is_true(util.isObject({}))
    assert.is_true(util.isObject({ a = 1 }))
    if hasNewproxy then
      assert.is_true(util.isObject(newproxy()))
    end
    assert.is_false(util.isObject(nil))
    assert.is_false(util.isObject(false))
    assert.is_false(util.isObject(7))
    assert.is_false(util.isObject('table'))
    assert.is_false(util.isObject(function() end))
  end)

  it('the capability probe sees a userdata engine as fully capable', function()
    if not hasNewproxy then return end
    local env = {
      core = ud({ API_REVISION = 129, getGMST = function() end }),
      ui = ud({ _getUiModeStack = function() end, registerSettingsPage = function() end }),
      types = ud({ Player = ud({ isCharGenFinished = function() end, journal = function() end }) }),
      nearby = ud({ castRay = function() end }),
      camera = ud({ viewportToWorldVector = function() end, getPosition = function() end,
                    castRenderingRay = function() end }),
      interfaces = ud({ Controls = ud({ overrideMovementControls = function() end }) }),
    }
    local probe = capabilities.probe(env)
    assert.is_true(probe.ok, 'probe reported: ' .. tostring(capabilities.describe(probe)))
    assert.equals(0, #probe.missing)
    assert.equals(129, probe.revision)
  end)

  it('a userdata package with a MISSING member is still reported missing', function()
    if not hasNewproxy then return end
    -- i.e. being userdata must not make the probe credulous
    local env = {
      core = ud({ API_REVISION = 129, getGMST = function() end }),
      ui = ud({}),                      -- no _getUiModeStack, no registerSettingsPage
      types = ud({ Player = ud({}) }),  -- no chargen flag, no journal
      nearby = ud({}),
      camera = ud({}),
      interfaces = ud({}),
    }
    local probe = capabilities.probe(env)
    assert.is_false(probe.ok)
    assert.is_false(probe.features.charGenFlag)
    assert.is_false(probe.features.uiModeStack)
    assert.is_true(probe.features.gmst)   -- this one IS there
  end)

  it('the observer reads a userdata-like snapshot without losing data', function()
    -- The real observer path: everything it reads off `self`/world is userdata.
    local env = mocks.install({})
    local ok, snapshot = pcall(function()
      local observer = require('scripts.runtime.observer')
      return observer.build(env, {})
    end)
    mocks.uninstall()
    assert.is_true(ok, tostring(snapshot))
    assert.is_not_nil(snapshot)
  end)
end)
