describe('runtime.portraitUI', function()
  local mocks = require('tests.mocks.openmw')
  local uiLayout = require('scripts.idle.uiLayout')

  --- Load the HUD script fresh against a mocked engine.
  local function loadHud(spec)
    local env = mocks.install(spec or {})
    package.loaded['scripts.portraitUI'] = nil
    local ok, script = pcall(require, 'scripts.portraitUI')
    if not ok then
      mocks.uninstall()
      error(script, 0)
    end
    return env, script
  end

  it('builds the status rows and the touch bar without throwing', function()
    local env, script = loadHud({ screen = { x = 1080, y = 2340 } })
    local ok, err = pcall(script.engineHandlers.onUpdate, 0.5)
    local created = #env._createdElements
    mocks.uninstall()

    assert.is_true(ok, tostring(err))
    -- 6 status rows + (background + label) for each command button
    assert.equals(created, 6 + #uiLayout.defaultButtons() * 2)
  end)

  it('is safe to tick repeatedly', function()
    local env, script = loadHud({ screen = { x = 1080, y = 2340 } })
    local ok = pcall(function()
      for _ = 1, 20 do script.engineHandlers.onUpdate(0.1) end
    end)
    mocks.uninstall()
    assert.is_true(ok)
    assert.equals(#env._createdElements, 6 + #uiLayout.defaultButtons() * 2)
  end)

  it('latches off after a UI failure instead of throwing every frame', function()
    local env = mocks.install({})
    env.ui.create = function() error('boom') end
    package.loaded['scripts.portraitUI'] = nil
    local script = require('scripts.portraitUI')

    local ok = pcall(script.engineHandlers.onUpdate, 0.5)
    local ok2 = pcall(script.engineHandlers.onUpdate, 0.5)
    local ok3 = pcall(script.engineHandlers.onUpdate, 0.5)
    mocks.uninstall()
    assert.is_true(ok and ok2 and ok3)
  end)

  it('rebuilds on resolution change', function()
    local env, script = loadHud({ screen = { x = 1080, y = 2340 } })
    pcall(script.engineHandlers.onUpdate, 0.1)
    local before = #env._createdElements
    local ok = pcall(script.engineHandlers.onResolutionChanged)
    local ok2 = pcall(script.engineHandlers.onUpdate, 0.5)
    local after = #env._createdElements
    mocks.uninstall()
    assert.is_true(ok and ok2)
    assert.is_true(after > before) -- a fresh set of elements was created
  end)

  it('works with a landscape screen too', function()
    local env, script = loadHud({ screen = { x = 2340, y = 1080 } })
    local ok = pcall(script.engineHandlers.onUpdate, 0.5)
    mocks.uninstall()
    assert.is_true(ok)
    assert.is_true(#env._createdElements > 0)
  end)
end)
