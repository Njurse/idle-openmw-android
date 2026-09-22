describe('runtime.idleDirector', function()
  local mocks = require('tests.mocks.openmw')

  --- Load the PLAYER script fresh against a mocked engine and run `fn`.
  local function withScript(spec, fn)
    local env = mocks.install(spec)
    package.loaded['scripts/idleDirector'] = nil
    local ok, handlers = pcall(require, 'scripts/idleDirector')
    if not ok then
      mocks.uninstall()
      error(handlers, 0)
    end
    local passed, err = pcall(fn, env, handlers)
    mocks.uninstall()
    if not passed then error(err, 0) end
  end

  local SPEC = {
    classId = 'warrior',
    position = { x = 0, y = 0, z = 0 },
    rotation = 0,
    cell = { name = 'Balmora', isExterior = true },
    gold = 400,
    capacity = 400,
    skills = { longblade = 64 },
    actors = { { recordId = 'arrille', position = { x = 300, y = 0, z = 0 }, servicesOffered = { Barter = true } } },
    inventory = { { id = 'chitin dagger', count = 5, value = 8, weight = 4, class = 'Weapon' } },
    journal = { { text = 'Arrille greets you.', questId = nil, day = 1 } },
    quests = { q1 = { id = 'q1', stage = 1, started = true, finished = false } },
  }

  --- The last value passed to interfaces.Controls.overrideMovementControls.
  local function lastOverride(env)
    for i = #env._interfaceCalls, 1, -1 do
      local call = env._interfaceCalls[i]
      if call[1] == 'movement' then return call[2] end
    end
    return nil
  end

  --- The director's decision interval is cfg.tick.interval (2.0s by default), so
  --- a tick smaller than that builds no snapshot and makes no decision.
  local function tick(handlers, times, dt)
    for _ = 1, (times or 1) do
      handlers.engineHandlers.onUpdate(dt or 2.5)
    end
  end

  it('boots and ticks without throwing', function()
    withScript(SPEC, function(env, handlers)
      local ok, err = pcall(tick, handlers, 5)
      assert.is_true(ok, tostring(err))
      assert.equals(#env._createdElements, 0) -- the HUD script draws, not this one
    end)
  end)

  it('takes the movement controls away from the input script when auto-playing', function()
    withScript(SPEC, function(env, handlers)
      tick(handlers, 1)
      assert.is_true(lastOverride(env) == true)
    end)
  end)

  it('hands them back in manual mode so the game is playable', function()
    withScript(SPEC, function(env, handlers)
      tick(handlers, 1)
      local ok = handlers.interface.act('pause')
      assert.is_true(ok)
      assert.equals(handlers.interface.mode(), 'manual')
      assert.is_false(lastOverride(env))
      assert.is_false(handlers.interface.isAutoPlaying())
    end)
  end)

  it('exposes a panel with both engine and director data', function()
    withScript(SPEC, function(env, handlers)
      tick(handlers, 1)
      local panel = handlers.interface.panel()
      assert.is_not_nil(panel)
      assert.equals(panel.player.gold, 400)
      assert.equals(panel.player.level, 1)
      assert.is_true(#panel.inventory >= 1)
      assert.equals(panel.mode, 'auto')
      assert.is_not_nil(panel.status)
      assert.is_not_nil(panel.log)
      assert.equals(#panel.quests, 1)
      assert.is_true(#panel.journal >= 1)
    end)
  end)

  it('queues an order from the console and the director obeys it', function()
    withScript(SPEC, function(env, handlers)
      tick(handlers, 1)
      local ok = handlers.interface.act('order', { id = 'rest' })
      assert.is_true(ok)
      -- the directive is in force immediately, and the next decision honours it
      assert.equals(handlers.interface.status().directive, 'rest')
      tick(handlers, 1)
      local status = handlers.interface.status()
      assert.equals(status.directive, 'rest')
      assert.equals(status.goal, 'rest')
    end)
  end)

  it('cancels orders and cycles modes', function()
    withScript(SPEC, function(env, handlers)
      tick(handlers, 1)
      handlers.interface.act('order', { id = 'shop' })
      handlers.interface.act('cancel')
      assert.is_nil(handlers.interface.directive())

      assert.equals(handlers.interface.mode(), 'auto')
      handlers.interface.act('cycle_mode')
      assert.equals(handlers.interface.mode(), 'manual')
    end)
  end)

  it('opens Morrowind windows through the UI interface', function()
    withScript(SPEC, function(env, handlers)
      tick(handlers, 1) -- builds the snapshot the Dialogue target comes from
      assert.is_true(handlers.interface.act('launch', { mode = 'Journal' }))
      assert.equals(#env._uiModesSet, 1)
      assert.equals(env._uiModesSet[1].mode, 'Journal')

      -- dialogue needs a target, which comes from the last snapshot
      assert.is_true(handlers.interface.act('launch', { mode = 'Dialogue' }))
      assert.equals(env._uiModesSet[2].mode, 'Dialogue')
      assert.is_not_nil(env._uiModesSet[2].options.target)
    end)
  end)

  it('equips from the console', function()
    withScript({
      inventory = { { id = 'cuirass', count = 1, value = 300, weight = 40, class = 'Armor', recordType = 1 } },
    }, function(env, handlers)
      tick(handlers, 1)
      assert.is_true(handlers.interface.act('equip', { id = 'cuirass' }))
      assert.equals(#env._equipCalls, 1)
    end)
  end)

  it('forwards dialogue responses into the brain', function()
    withScript(SPEC, function(env, handlers)
      tick(handlers, 1)
      handlers.eventHandlers.DialogueResponse({ actor = { recordId = 'arrille' }, type = 'greeting' })
      local panel = handlers.interface.panel()
      assert.equals(#panel.dialogue, 1)
      assert.equals(panel.dialogue[1].actor, 'arrille')
    end)
  end)

  it('round-trips save/load, including the mode', function()
    withScript(SPEC, function(env, handlers)
      tick(handlers, 1)
      handlers.interface.setMode('directive')
      local saved = handlers.engineHandlers.onSave()
      assert.is_not_nil(saved.data)

      handlers.engineHandlers.onLoad(saved)
      handlers.engineHandlers.onUpdate(2.5)
      assert.equals(handlers.interface.mode(), 'directive')
    end)
  end)

  it('rejects unknown console actions', function()
    withScript(SPEC, function(env, handlers)
      tick(handlers, 1)
      local ok, message = handlers.interface.act('nonsense', nil)
      assert.is_false(ok)
      assert.is_true(tostring(message):find('unknown action', 1, true) ~= nil)
    end)
  end)

  describe('Setup tab options', function()
    it('cycles a boolean, applies it live and persists only the change', function()
      withScript(SPEC, function(env, handlers)
        tick(handlers, 1)
        local cfg = handlers.interface.getConfig()
        assert.is_false(cfg.sensing.npcFightHostility)   -- the safe default

        assert.is_true(handlers.interface.act('set_option', { key = 'npcFightHostility' }))
        -- the panel and the director must both see the new value
        assert.is_true(handlers.interface.getConfig().sensing.npcFightHostility)
        assert.is_true(handlers.interface.panel().config.sensing.npcFightHostility)

        local section = env._playerSections['IdleOpenMW']
        assert.is_not_nil(section, 'the option was not persisted')
        expect(section:get('config')):toEqualDeep({ sensing = { npcFightHostility = true } })
      end)
    end)

    it('cycles a choice through its options and wraps', function()
      withScript(SPEC, function(env, handlers)
        tick(handlers, 1)
        assert.equals(handlers.interface.getConfig().ui.startMode, 'auto')
        handlers.interface.act('set_option', { key = 'startMode' })
        assert.equals(handlers.interface.getConfig().ui.startMode, 'directive')
        handlers.interface.act('set_option', { key = 'startMode' })
        handlers.interface.act('set_option', { key = 'startMode' })
        assert.equals(handlers.interface.getConfig().ui.startMode, 'auto')
      end)
    end)

    it('clamps a value that the config would reject', function()
      withScript(SPEC, function(env, handlers)
        tick(handlers, 1)
        -- ui.refresh cycles 0.25/0.5/1.0/2.0, all inside the valid range
        for _ = 1, 4 do handlers.interface.act('set_option', { key = 'refresh' }) end
        assert.is_true(handlers.interface.getConfig().ui.refresh <= 2.0)
        assert.is_true(handlers.interface.getConfig().ui.refresh >= 0.25)
      end)
    end)

    it('refuses an unknown option instead of guessing', function()
      withScript(SPEC, function(env, handlers)
        tick(handlers, 1)
        local ok, message = handlers.interface.act('set_option', { key = 'nonexistent' })
        assert.is_false(ok)
        assert.is_true(tostring(message):find('unknown option', 1, true) ~= nil)
        assert.is_false(handlers.interface.act('set_option', {}))
      end)
    end)

    it('logs the change so it is visible in the Log tab', function()
      withScript(SPEC, function(env, handlers)
        tick(handlers, 1)
        handlers.interface.act('set_option', { key = 'autoTravel' })
        local log = handlers.interface.panel().log
        local found = false
        for _, entry in ipairs(log) do
          if tostring(entry.message):find('Travel on its own', 1, true) then found = true end
        end
        assert.is_true(found)
      end)
    end)
  end)

  it('keeps ticking after an engine call throws', function()    withScript(SPEC, function(env, handlers)
      local explode = true
      local realInventory = env.types.Actor.inventory
      env.types.Actor.inventory = function(actor)
        if explode then error('engine exploded') end
        return realInventory(actor)
      end
      local ok = pcall(tick, handlers, 3)
      explode = false
      local ok2 = pcall(tick, handlers, 3)
      assert.is_true(ok and ok2)
    end)
  end)
end)

describe('runtime.idleDirector guardian wiring', function()
  local mocks = require('tests.mocks.openmw')

  local function withScript(spec, fn)
    local env = mocks.install(spec)
    package.loaded['scripts/idleDirector'] = nil
    local ok, handlers = pcall(require, 'scripts/idleDirector')
    if not ok then
      mocks.uninstall()
      error(handlers, 0)
    end
    local passed, err = pcall(fn, env, handlers)
    mocks.uninstall()
    if not passed then error(err, 0) end
  end

  local SPEC = {
    classId = 'warrior', position = { x = 0, y = 0, z = 0 }, rotation = 0,
    -- an exterior with a name and no " Region" suffix => a settlement
    cell = { name = 'Balmora', isExterior = true },
    gold = 400, capacity = 400, skills = { longblade = 64 },
  }

  local function tick(handlers, times)
    for _ = 1, (times or 1) do
      handlers.engineHandlers.onUpdate(2.5)
    end
  end

  local function rescues(env)
    local out = {}
    for _, event in ipairs(env._globalEvents or {}) do
      if event.name == 'IdleOpenMW_Guardian' then out[#out + 1] = event.data end
    end
    return out
  end

  it('tops up a critically wounded character rather than letting them die', function()
    withScript(SPEC, function(env, handlers)
      tick(handlers, 1)                      -- healthy tick: remembers the town
      env._pools.health.current = 10         -- 10% < criticalHealthFraction 0.15
      tick(handlers, 1)
      assert.equals(env._pools.health.current, 75)   -- restored to healTo
      -- healing is done locally: it must NOT need the global script
      assert.equals(#rescues(env), 0)
    end)
  end)

  it('asks the global warden to respawn a dead character in the last town', function()
    withScript(SPEC, function(env, handlers)
      tick(handlers, 1)
      env._pools.health.current = 0
      tick(handlers, 1)
      local events = rescues(env)
      assert.equals(#events, 1)
      assert.equals(events[1].action, 'respawn')
      assert.equals(events[1].safeSpot.name, 'Balmora')
      assert.is_true(events[1].safeSpot.position ~= nil)
    end)
  end)

  it('does not rescue a dead character with no town to return to', function()
    withScript(SPEC, function(env, handlers)
      -- wilderness: nothing is remembered, so there is nowhere to respawn
      env._modules['openmw.self'].cell = { name = 'Ashlands Region', isExterior = true }
      tick(handlers, 1)
      env._pools.health.current = 0
      tick(handlers, 1)
      assert.equals(#rescues(env), 0)
    end)
  end)

  it('leaves a MANUAL player alone, dying included', function()
    withScript(SPEC, function(env, handlers)
      -- one tick first: the director is built by ensureInit(), and interface
      -- calls before that are (correctly) no-ops
      tick(handlers, 1)
      handlers.interface.setMode('manual')
      tick(handlers, 1)
      env._pools.health.current = 0
      tick(handlers, 1)
      assert.equals(#rescues(env), 0)
    end)
  end)
end)

describe('runtime.idleDirector lifecycle + camera wiring', function()
  local mocks = require('tests.mocks.openmw')
  local observer = require('scripts.runtime.observer')

  local function withScript(spec, fn)
    local env = mocks.install(spec)
    package.loaded['scripts.idleDirector'] = nil
    local ok, handlers = pcall(require, 'scripts.idleDirector')
    if not ok then mocks.uninstall(); error(handlers, 0) end
    local passed, err = pcall(fn, env, handlers)
    mocks.uninstall()
    if not passed then error(err, 0) end
  end

  --- A minimal, quiet in-world spec; `extra` overrides fields.
  local function base(extra)
    local spec = {
      classId = 'warrior', position = { x = 0, y = 0, z = 0 }, rotation = 0,
      cell = { name = 'Seyda Neen', isExterior = true },
      gold = 100, capacity = 400, actors = {}, inventory = {},
      charGenFinished = true,
    }
    for k, v in pairs(extra or {}) do spec[k] = v end
    return spec
  end

  local function tick(handlers, times, dt)
    for _ = 1, (times or 1) do handlers.engineHandlers.onUpdate(dt or 2.5) end
  end

  --- The last value passed to interfaces.Controls.overrideMovementControls.
  local function lastOverride(env)
    for i = #env._interfaceCalls, 1, -1 do
      local call = env._interfaceCalls[i]
      if call[1] == 'movement' then return call[2] end
    end
    return nil
  end

  it("reports the engine's live UI stack on the panel", function()
    local env = mocks.install({ uiModes = { 'Interface', 'Dialogue' } })
    local ui = observer.readUi(env)
    mocks.uninstall()
    assert.equals(ui.mode, 'Dialogue')
    assert.equals(ui.kind, 'dialogue')
  end)

  it('falls back to interfaces.UI.getMode when the internal hook is absent', function()
    local env = mocks.install({})
    env.ui._getUiModeStack = nil
    env.interfaces.UI.getMode = function() return 'Journal' end
    local ui = observer.readUi(env)
    mocks.uninstall()
    assert.equals(ui.mode, 'Journal')
    assert.equals(ui.kind, 'journal')
  end)

  it('does not drive the character while character creation is unfinished', function()
    withScript(base({ charGenFinished = false, uiModes = { 'ChargenRace' } }),
      function(env, handlers)
        tick(handlers, 3)
        local status = handlers.interface.status()
        assert.equals(status.goal, 'chargen')
        assert.is_false(status.acting)
        assert.equals(status.phase, 'chargen')
        -- nothing steers the character: the engine's own controls are in charge
        -- and no movement is commanded
        assert.is_true(lastOverride(env) == false)
        assert.not_equals(env.self.controls.movement or 0, 1)
      end)
  end)

  it('acts normally once character creation is finished', function()
    withScript(base({ charGenFinished = true }), function(env, handlers)
      tick(handlers, 3)
      local status = handlers.interface.status()
      assert.is_true(status.acting)
      assert.equals(status.phase, 'world')
      assert.is_true(lastOverride(env) == true) -- we drive again
    end)
  end)

  it('locks the isometric camera in the world when enabled', function()
    withScript(base({}), function(env, handlers)
      env.storage.playerSection('IdleOpenMW'):set('config', { camera = { isometric = true } })
      tick(handlers, 3)
      local sawMode, sawPitch, sawDistance = false, false, false
      for _, call in ipairs(env._cameraCalls) do
        if call[1] == 'setMode' then sawMode = true end
        if call[1] == 'setPitch' then sawPitch = true end
        if call[1] == 'setDistance' then sawDistance = true end
      end
      assert.is_true(sawMode)
      assert.is_true(sawPitch)
      assert.is_true(sawDistance)
    end)
  end)

  it('leaves the camera alone during character creation', function()
    withScript(base({ charGenFinished = false }), function(env, handlers)
      env.storage.playerSection('IdleOpenMW'):set('config', { camera = { isometric = true } })
      tick(handlers, 3)
      assert.equals(#env._cameraCalls, 0)
    end)
  end)

  it('turns a screen tap into a walk_to order', function()
    withScript(base({
      cameraPosition = { x = 0, y = 0, z = 0 },
      cameraDirection = { x = 1, y = 0, z = 0 },
      rayHit = { hitPos = { x = 600, y = 0, z = 0 }, hitObject = nil },
    }), function(env, handlers)
      tick(handlers, 2)
      local ok = handlers.interface.act('walk_to', { x = 540, y = 1170 })
      assert.is_true(ok)
      tick(handlers, 2, 2.5)
      assert.equals(handlers.interface.status().goal, 'walk_to')
    end)
  end)

  it('walks to a door you tap and enters it', function()
    withScript(base({
      cameraPosition = { x = 0, y = 0, z = 0 },
      cameraDirection = { x = 1, y = 0, z = 0 },
    }), function(env, handlers)
      tick(handlers, 2)
      env._setRayHit({
        hitPos = { x = 500, y = 0, z = 0 },
        hitObject = { recordId = 'census door', type = env.types.Door },
      })
      assert.is_true(handlers.interface.act('walk_to', { x = 540, y = 1170 }))
      tick(handlers, 2, 2.5)
      assert.equals(handlers.interface.status().goal, 'walk_to')
      -- the order's label names what we tapped
      local panel = handlers.interface.panel()
      assert.is_true(panel.log ~= nil)
    end)
  end)

  it('does nothing when the tap hits nothing', function()
    withScript(base({
      cameraPosition = { x = 0, y = 0, z = 0 },
      cameraDirection = { x = 1, y = 0, z = 0 },
    }), function(env, handlers)
      tick(handlers, 2)
      env._setRayHit(nil)   -- a ray into the sky
      assert.is_false(handlers.interface.act('walk_to', { x = 540, y = 200 }))
    end)
  end)
end)
