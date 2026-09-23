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

  --- A userdata list: `#` via __len, `[i]` via __index -- how the engine's lists read. `ipairs`
  --- cannot be used on one (LuaJIT's ipairs is the 5.1 builtin), which is why the mod's readers
  --- walk by index.
  local function udList(items)
    local proxy = newproxy(true)
    local mt = getmetatable(proxy)
    mt.__index = function(_, index) return items[index] end
    mt.__len = function() return #items end
    return proxy
  end

  --- Type sentinels that classify userdata objects, like the engine's do.
  local function classifyingTypes()
    local names = { 'Player', 'NPC', 'Creature', 'Door', 'Container', 'Activator', 'Item' }
    local types = {}
    for _, name in ipairs(names) do
      types[name] = { objectIsInstance = function(o) return o and o._type == name end }
    end
    return types
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

  it('reads a position out of a userdata Vector3, not only a table', function()
    -- The bug this pins: observer.point() guarded with `type(v) ~= 'table'`, so a Vector3
    -- USERDATA was rejected. The player then read as (0,0,0) and every actor's position as nil --
    -- and the director derives every distance, arrival and steering decision from those. The
    -- mocks pass plain tables, so they never caught it; only a real engine did.
    if not hasNewproxy then return end
    local observer = require('scripts.runtime.observer')
    local fromUserdata = observer.point(ud({ x = 100, y = 200, z = 300 }))
    assert.equals(100, fromUserdata.x)
    assert.equals(300, fromUserdata.z)
    -- a plain table must keep working
    assert.equals(100, observer.point({ x = 100, y = 200, z = 300 }).x)
    assert.is_nil(observer.point(nil))
    assert.is_nil(observer.point(7))
  end)

  it('the record shapers read a userdata record and its info list', function()
    -- records.lua is spec'd in its own file too; this is the userdata case, in the file whose
    -- whole job is to state the fact. `type(raw) ~= 'table'` made every shaper return nil for
    -- EVERY real record.
    if not hasNewproxy then return end
    local records = require('scripts.idle.records')
    local record = ud({ id = 'q1', name = 'A Quest',
                        infos = udList({ ud({ id = 'i1', text = 'hi', questStage = 10 }) }) })
    local shaped = records.shapeRecord(record)
    assert.equals('q1', shaped.id)
    assert.equals(1, shaped.infosTotal)
    assert.equals('hi', shaped.infos[1].text)
    assert.equals(1, #records.entriesForStage(record, 10))
  end)

  it('the hud orders a userdata list of interactables', function()
    if not hasNewproxy then return end
    local hud = require('scripts.idle.hud')
    local sorted = hud.sortByDistance(udList({
      { id = 'far', distance = 30 },
      { id = 'near', distance = 10 },
    }))
    assert.equals(2, #sorted)
    assert.equals('near', sorted[1].id)
    assert.equals('far', sorted[2].id)
  end)

  it('the entity reader walks a userdata list and classifies it', function()
    -- nearby.actors is an ObjectList userdata. `type(list) == 'table'` read every list as EMPTY,
    -- so the world model went blind on a real engine while the mock (plain tables) stayed green.
    if not hasNewproxy then return end
    local entities = require('scripts.runtime.entities')
    local env = { types = classifyingTypes() }
    local actor = ud({ _type = 'NPC', recordId = 'fargoth', name = 'Fargoth',
                       position = ud({ x = 10, y = 20, z = 30 }) })
    local rows = entities.readList(udList({ actor }), env, { x = 0, y = 0, z = 0 })
    assert.equals(1, #rows)
    assert.equals('fargoth', rows[1].recordId)
  end)
end)
