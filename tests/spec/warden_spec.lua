-- tests/spec/warden_spec.lua
-- The GLOBAL warden (scripts/idleWarden.lua) is the only place an economy action can happen:
-- `openmw.world` is a global-only module ("Provides an interface to the game world for global
-- scripts", world.lua:3-4) and GameObject:remove/moveInto are registered only for GObject
-- ("Only for global scripts", objectbindings.cpp:399-400). The player script can only ASK, so
-- this drives the asking side's counterpart.
describe('idleWarden economy', function()
  local mocks = require('tests.mocks.openmw')

  local function withWarden(spec, fn)
    local env = mocks.install(spec)
    -- the script is a GLOBAL entry, not a module the tests usually load; require it fresh
    package.loaded['scripts.idleWarden'] = nil
    local ok, warden = pcall(require, 'scripts.idleWarden')
    if not ok then
      mocks.uninstall()
      error('idleWarden.lua did not load: ' .. tostring(warden), 0)
    end
    local called, err = pcall(fn, env, warden.eventHandlers)
    mocks.uninstall()
    if not called then error(err, 0) end
  end

  local function lastEvent(env)
    return env._globalEvents[#env._globalEvents]
  end

  it('banks gold through world.createObject + moveInto', function()
    withWarden({ gold = 0 }, function(env, handlers)
      handlers['IdleOpenMW_Economy']({ op = 'gold', amount = 50 })
      local created = env._createdObjects[#env._createdObjects]
      assert.equals('gold_001', created.recordId)
      assert.equals(50, created.count)
      local reply = lastEvent(env)
      assert.equals('IdleOpenMW_EconomyApplied', reply.name)
      assert.is_true(reply.data.ok)
      assert.equals('gold', reply.data.op)
    end)
  end)

  it('gives an item into the player inventory', function()
    withWarden({ gold = 0 }, function(env, handlers)
      handlers['IdleOpenMW_Economy']({ op = 'give', recordId = 'cure potion', count = 2 })
      local created = env._createdObjects[#env._createdObjects]
      assert.equals('cure potion', created.recordId)
      assert.equals(2, created.count)
      assert.is_true(lastEvent(env).data.ok)
    end)
  end)

  it('takes items out of the player inventory', function()
    withWarden({ gold = 0, inventory = { { id = 'lockpick', count = 12 } } }, function(env, handlers)
      handlers['IdleOpenMW_Economy']({ op = 'take', recordId = 'lockpick', count = 4 })
      local inventory = env.types.Actor.inventory(env.self.object)
      assert.equals(8, inventory:countOf('lockpick'))
      assert.is_true(lastEvent(env).data.ok)
    end)
  end)

  it('reports a refusal instead of failing silently', function()
    withWarden({ gold = 0 }, function(env, handlers)
      handlers['IdleOpenMW_Economy']({ op = 'take', recordId = 'chitin dagger', count = 1 })
      local reply = lastEvent(env)
      assert.is_false(reply.data.ok)
      assert.is_true(tostring(reply.data.detail):find('not carried') ~= nil)
    end)
  end)

  it('reports an unknown operation rather than doing nothing', function()
    withWarden({ gold = 0 }, function(env, handlers)
      handlers['IdleOpenMW_Economy']({ op = 'frobnicate' })
      assert.is_false(lastEvent(env).data.ok)
    end)
  end)
end)
