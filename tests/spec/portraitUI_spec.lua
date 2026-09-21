describe('runtime.portraitUI', function()
  local mocks = require('tests.mocks.openmw')
  local uiLayout = require('scripts.idle.uiLayout')
  local uiModel = require('scripts.idle.uiModel')
  local panels = require('tests.fixtures.panel')

  local SCREEN = { x = 1080, y = 2340 }

  --- How many root elements the console creates for a given tab.
  local function expectedElements(tab)
    local console = uiLayout.console(SCREEN, nil, {
      mode = 'auto', tabs = uiModel.TABS, footer = uiModel.footerFor(tab), footerRows = 2,
    })
    return 5 + 1 + #uiModel.TABS + console.pageSize + 2 + #console.footer
  end

  --- Load the HUD script fresh against a mocked engine.
  --- @param spec mock spec
  --- @param idle  optional fake IdleOpenMW interface
  local function loadHud(spec, idle)
    local env = mocks.install(spec or { screen = SCREEN })
    if idle then env.interfaces.IdleOpenMW = idle end
    package.loaded['scripts/portraitUI'] = nil
    local ok, script = pcall(require, 'scripts/portraitUI')
    if not ok then
      mocks.uninstall()
      error(script, 0)
    end
    return env, script
  end

  --- Find a created element by its current text.
  local function elementWithText(env, text)
    for _, element in ipairs(env._createdElements) do
      if element.layout.props.text == text then return element end
    end
    return nil
  end

  --- Find a created element whose text contains a substring.
  local function elementContaining(env, needle)
    for _, element in ipairs(env._createdElements) do
      local value = element.layout.props.text
      if type(value) == 'string' and value:find(needle, 1, true) then return element end
    end
    return nil
  end

  --- A fake IdleOpenMW interface, recording everything the HUD asks for.
  local function stubInterface(panelData)
    local calls, logs = {}, {}
    return {
      calls = calls,
      logs = logs,
      panel = function() return panelData end,
      getConfig = function() return panelData and panelData.config or nil end,
      mode = function() return panelData and panelData.mode or 'auto' end,
      act = function(action, payload)
        calls[#calls + 1] = { action = action, payload = payload }
        return true
      end,
      log = function(message, level) logs[#logs + 1] = { message = message, level = level } end,
    }
  end

  it('builds the console without throwing', function()
    local env, script = loadHud({ screen = SCREEN })
    local ok, err = pcall(script.engineHandlers.onUpdate, 0.5)
    local created = #env._createdElements
    mocks.uninstall()

    assert.is_true(ok, tostring(err))
    assert.equals(created, expectedElements('info'))
  end)

  it('is safe to tick repeatedly', function()
    local env, script = loadHud({ screen = SCREEN })
    local ok = pcall(function()
      for _ = 1, 20 do script.engineHandlers.onUpdate(0.1) end
    end)
    mocks.uninstall()
    assert.is_true(ok)
    assert.equals(#env._createdElements, expectedElements('info'))
  end)

  it('draws the mode indicator and the goal in the top strip', function()
    local idle = stubInterface(panels.panel())
    local env, script = loadHud({ screen = SCREEN }, idle)
    pcall(script.engineHandlers.onUpdate, 0.6)

    local modeLine = elementContaining(env, '[AUTO]')
    local goalLine = elementContaining(env, 'fight')
    mocks.uninstall()
    assert.is_not_nil(modeLine)
    assert.is_not_nil(goalLine)
  end)

  it('switches tabs when a tab is tapped', function()
    local idle = stubInterface(panels.panel())
    local env, script = loadHud({ screen = SCREEN }, idle)
    pcall(script.engineHandlers.onUpdate, 0.6)

    local packTab = elementWithText(env, 'Pack')
    assert.is_not_nil(packTab)
    assert.is_not_nil(packTab.layout.events.mouseClick)

    packTab.layout.events.mouseClick()          -- tap the tab
    pcall(script.engineHandlers.onUpdate, 0.1)  -- refresh

    local itemRow = elementContaining(env, 'heavy cuirass')
    local activeTab = elementWithText(env, '[Pack]')
    mocks.uninstall()
    assert.is_not_nil(itemRow, 'the pack rows should be drawn after switching tabs')
    assert.is_not_nil(activeTab, 'the active tab should be highlighted')
  end)

  it('orders the character when an order row is tapped', function()
    local idle = stubInterface(panels.panel())
    local env, script = loadHud({ screen = SCREEN }, idle)
    pcall(script.engineHandlers.onUpdate, 0.6)

    local ordersTab = elementWithText(env, 'Order')
    ordersTab.layout.events.mouseClick()
    pcall(script.engineHandlers.onUpdate, 0.1)

    local restRow = elementContaining(env, 'Rest')
    assert.is_not_nil(restRow)
    restRow.layout.events.mouseClick()

    local ordered = nil
    for _, call in ipairs(idle.calls) do
      if call.action == 'order' and call.payload and call.payload.id == 'rest' then ordered = call end
    end
    mocks.uninstall()
    assert.is_not_nil(ordered, 'tapping an order row must issue that order')
  end)

  it('asks for a selection before acting on the pack', function()
    local idle = stubInterface(panels.empty())  -- nothing to select
    local env, script = loadHud({ screen = SCREEN }, idle)
    pcall(script.engineHandlers.onUpdate, 0.6)

    elementWithText(env, 'Pack').layout.events.mouseClick()
    pcall(script.engineHandlers.onUpdate, 0.1)

    local equipButton = elementWithText(env, 'Equip')
    assert.is_not_nil(equipButton)
    equipButton.layout.events.mouseClick()

    local warned = false
    for _, entry in ipairs(idle.logs) do
      if entry.message:find('Select an item', 1, true) then warned = true end
    end
    -- no equip call should have been made
    local equipped = false
    for _, call in ipairs(idle.calls) do
      if call.action == 'equip' then equipped = true end
    end
    mocks.uninstall()
    assert.is_true(warned)
    assert.is_false(equipped)
  end)

  it('cycles the mode when the mode line is tapped', function()
    local idle = stubInterface(panels.panel())
    local env, script = loadHud({ screen = SCREEN }, idle)
    pcall(script.engineHandlers.onUpdate, 0.6)

    local modeLine = elementContaining(env, '[AUTO]')
    modeLine.layout.events.mouseClick()

    local cycled = false
    for _, call in ipairs(idle.calls) do
      if call.action == 'cycle_mode' then cycled = true end
    end
    mocks.uninstall()
    assert.is_true(cycled)
  end)

  it('offers scroll buttons that actually move the window', function()
    -- a long pack on a small screen, so the list overflows its page
    local items = {}
    for i = 1, 40 do
      items[i] = { id = ('junk %02d'):format(i), count = 1, value = 5, weight = 1,
                   junk = true, valuePerWeight = 5.0 }
    end
    local idle = stubInterface(panels.panel({ inventory = items }))
    local env, script = loadHud({ screen = { x = 480, y = 900 } }, idle)
    pcall(script.engineHandlers.onUpdate, 0.6)

    elementWithText(env, 'Pack').layout.events.mouseClick()
    pcall(script.engineHandlers.onUpdate, 0.1)

    local firstRowBefore = elementContaining(env, 'junk 01')
    assert.is_not_nil(firstRowBefore, 'the first window should start at junk 01')

    local down = elementWithText(env, 'v')
    assert.is_not_nil(down)
    assert.is_not_nil(down.layout.events.mouseClick)
    down.layout.events.mouseClick()            -- scroll down three rows
    pcall(script.engineHandlers.onUpdate, 0.1)

    local firstRowAfter = elementContaining(env, 'junk 01')
    local newTop = elementContaining(env, 'junk 04')
    mocks.uninstall()
    assert.is_nil(firstRowAfter, 'junk 01 should have scrolled out of the window')
    assert.is_not_nil(newTop, 'junk 04 should now be the top row')
  end)

  it('latches off after a UI failure instead of throwing every frame', function()
    local env = mocks.install({})
    env.ui.create = function() error('boom') end
    package.loaded['scripts/portraitUI'] = nil
    local script = require('scripts/portraitUI')

    local ok = pcall(script.engineHandlers.onUpdate, 0.5)
    local ok2 = pcall(script.engineHandlers.onUpdate, 0.5)
    local ok3 = pcall(script.engineHandlers.onUpdate, 0.5)
    mocks.uninstall()
    assert.is_true(ok and ok2 and ok3)
  end)

  it('rebuilds on resolution change', function()
    local env, script = loadHud({ screen = SCREEN })
    pcall(script.engineHandlers.onUpdate, 0.1)
    local before = #env._createdElements
    local ok = pcall(script.engineHandlers.onResolutionChanged)
    local ok2 = pcall(script.engineHandlers.onUpdate, 0.5)
    local after = #env._createdElements
    mocks.uninstall()
    assert.is_true(ok and ok2)
    assert.is_true(after > before)
  end)

  it('works with a landscape screen too', function()
    local env, script = loadHud({ screen = { x = 2340, y = 1080 } })
    local ok = pcall(script.engineHandlers.onUpdate, 0.5)
    mocks.uninstall()
    assert.is_true(ok)
    assert.is_true(#env._createdElements > 0)
  end)
end)
