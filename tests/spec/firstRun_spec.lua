-- tests/spec/firstRun_spec.lua
-- The first run, end to end: start a game, go through character creation, and
-- only then let the mod move the character.
--
-- This is the "are the basics coherent?" spec. It drives the real PLAYER script
-- (scripts/idleDirector.lua) through a whole new-game sequence against the mock
-- engine, and asserts the two halves that matter:
--
--   1. through chargen (name -> race -> class -> birth -> review) the mod emits
--      NOTHING: no movement, no control override, no console;
--   2. the moment the character is released into Seyda Neen, the mod paths the
--      character toward a target (the executor actually steers `self.controls`).
--
-- See docs/openmw-lua-api.md section 13 (the chargen flag) and
-- scripts/idle/lifecycle.lua.
describe('first run: new game -> chargen -> Seyda Neen', function()
  local mocks = require('tests.mocks.openmw')

  local function withScript(spec, fn)
    local env = mocks.install(spec)
    package.loaded['scripts/idleDirector'] = nil
    local ok, handlers = pcall(require, 'scripts/idleDirector')
    if not ok then mocks.uninstall(); error(handlers, 0) end
    local passed, err = pcall(fn, env, handlers)
    mocks.uninstall()
    if not passed then error(err, 0) end
  end

  local function tick(handlers, times, dt)
    for _ = 1, (times or 1) do handlers.engineHandlers.onUpdate(dt or 2.5) end
  end

  local function lastOverride(env)
    for i = #env._interfaceCalls, 1, -1 do
      local call = env._interfaceCalls[i]
      if call[1] == 'movement' then return call[2] end
    end
    return nil
  end

  --- A brand-new game, still inside the Census & Excise office.
  local function newGame(extra)
    local spec = {
      classId = 'warrior',
      position = { x = 0, y = 0, z = 0 },
      rotation = 0,
      cell = { name = 'Census and Excise Office', isExterior = false },
      gold = 0,
      capacity = 400,
      charGenFinished = false,
      actors = {},
      inventory = {},
    }
    for k, v in pairs(extra or {}) do spec[k] = v end
    return spec
  end

  --- The character creation windows, in the order the engine opens them.
  local CHARGEN_MODES = {
    { 'ChargenName' },           -- typing the name
    { 'ChargenRace' },           -- race
    { 'ChargenClass' },          -- class list
    { 'ChargenClassPick' },      -- the questionnaire's answers
    { 'ChargenClassReview' },    -- "Are you sure?"
    { 'ChargenBirth' },          -- birthsign
    { 'ChargenReview' },
  }

  it('does nothing at all while the character is being made', function()
    local env
    local spec = newGame()
    withScript(spec, function(e, handlers)
      env = e
      for _, modes in ipairs(CHARGEN_MODES) do
        env._setUiModes(modes)              -- the engine opens the next window
        tick(handlers, 2)
        local status = handlers.interface.status()
        assert.equals(status.goal, 'chargen')
        assert.is_false(status.acting)
        assert.is_false(lastOverride(env) == true)  -- engine keeps the controls
      end
      -- and the console is not on screen over any of it
      assert.equals(#env._createdElements, 0)
    end)
  end)

  it('starts playing the moment the character reaches Seyda Neen', function()
    local env
    withScript(newGame(), function(e, handlers)
      env = e
      env._setUiModes({ 'ChargenReview' })
      tick(handlers, 2)
      assert.equals(handlers.interface.status().goal, 'chargen')

      -- released: chargen state flips, the engine drops us into the world
      env._modules['openmw.self'].cell = { name = 'Seyda Neen', isExterior = true }
      env._modules['openmw.types'].Player.isCharGenFinished = function() return true end
      env._setUiModes({})
      tick(handlers, 2)

      local status = handlers.interface.status()
      assert.equals(status.phase, 'world')
      assert.is_true(status.acting)
      assert.is_true(lastOverride(env) == true)  -- the mod takes the controls
    end)
  end)

  it('paths the character toward an ordered target and steers the controls', function()
    -- A shop next door: ordering "go shop" must produce real movement.
    local env
    local spec = newGame({
      charGenFinished = true,
      cell = { name = 'Seyda Neen', isExterior = true },
      gold = 400,
      position = { x = 0, y = 0, z = 0 },
      actors = {
        { recordId = 'arrille', name = 'Arrille', position = { x = 900, y = 0, z = 0 },
          servicesOffered = { Barter = true } },
      },
      inventory = { { id = 'chitin dagger', count = 3, value = 8, weight = 4, class = 'Weapon' } },
    })
    withScript(spec, function(e, handlers)
      env = e
      tick(handlers, 2)                          -- settle into the world
      handlers.interface.act('order', { id = 'shop' })  -- the player taps "Find a shop"
      -- the director only decides on its interval (cfg.tick.interval = 2.0s), so
      -- tick at that size, then let the executor steer on sub-interval frames
      tick(handlers, 2, 2.5)
      tick(handlers, 4, 0.5)

      local status = handlers.interface.status()
      assert.equals(status.goal, 'shop')
      -- the executor is actually driving: forward movement and a turn toward the
      -- destination (pathfinder steering writes self.controls)
      local moved = (env.self.controls.movement or 0) ~= 0
      local turned = (env.self.controls.yawChange or 0) ~= 0
      assert.is_true(moved or turned)
    end)
  end)
end)
