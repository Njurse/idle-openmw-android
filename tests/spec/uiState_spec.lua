-- tests/spec/uiState_spec.lua
-- "What does the engine have open right now?" -- the vocabulary the brain, the
-- console and the guardian use to describe the live UI (scripts/idle/uiState.lua).
describe('idle.uiState', function()
  local uiState = require('scripts.idle.uiState')

  describe('kindOf', function()
    it('classifies the whole Chargen family by prefix', function()
      assert.equals(uiState.kindOf('ChargenName'), 'chargen')
      assert.equals(uiState.kindOf('ChargenRace'), 'chargen')
      assert.equals(uiState.kindOf('ChargenClassReview'), 'chargen')
    end)

    it('classifies the everyday windows', function()
      assert.equals(uiState.kindOf('MainMenu'), 'menu')
      assert.equals(uiState.kindOf('Dialogue'), 'dialogue')
      assert.equals(uiState.kindOf('Interface'), 'inventory')
      assert.equals(uiState.kindOf('Container'), 'container')
      assert.equals(uiState.kindOf('Barter'), 'barter')
      assert.equals(uiState.kindOf('Loading'), 'loading')
    end)

    it('flags an unrecognised mode as "other", not as the world', function()
      assert.equals(uiState.kindOf('SomeFutureWindow'), 'other')
    end)

    it('treats no mode as nil', function()
      assert.is_nil(uiState.kindOf(nil))
      assert.is_nil(uiState.kindOf(''))
      assert.is_nil(uiState.kindOf(42))
    end)
  end)

  describe('classify', function()
    it('calls an empty stack "the world", and nothing blocks there', function()
      local state = uiState.classify(nil)
      assert.equals(state.kind, 'world')
      assert.is_false(state.blocking)
      assert.is_nil(state.mode)
    end)

    it('marks the modes the mod must not drive through as blocking', function()
      assert.is_true(uiState.classify('MainMenu').blocking)
      assert.is_true(uiState.classify('ChargenBirth').blocking)
      assert.is_true(uiState.classify('LoadingWallpaper').blocking)
    end)

    it('does NOT block on a normal in-game window', function()
      assert.is_false(uiState.classify('Dialogue').blocking)
      assert.is_false(uiState.classify('Interface').blocking)
    end)

    it('gives a human label', function()
      assert.equals(uiState.classify('MainMenu').label, 'Main menu')
      assert.equals(uiState.classify('ChargenRace').label, 'Character creation')
    end)
  end)

  describe('fromStack', function()
    it('describes the TOP of the stack (newest last)', function()
      local state = uiState.fromStack({ 'Interface', 'Dialogue' })
      assert.equals(state.mode, 'Dialogue')
      assert.equals(state.kind, 'dialogue')
      assert.equals(#state.stack, 2)
    end)

    it('keeps the whole stack for the caller', function()
      local state = uiState.fromStack({ 'Interface', 'Container' })
      assert.equals(state.stack[1], 'Interface')
      assert.equals(state.stack[2], 'Container')
    end)

    it('falls back to a single mode when the stack is empty', function()
      local state = uiState.fromStack({}, 'MainMenu')
      assert.equals(state.mode, 'MainMenu')
      assert.equals(state.kind, 'menu')
      assert.equals(#state.stack, 0)
    end)

    it('is the world when there is neither stack nor fallback', function()
      assert.equals(uiState.fromStack(nil, nil).kind, 'world')
      assert.equals(uiState.fromStack({}, '').kind, 'world')
    end)

    it('ignores non-string junk on the stack', function()
      local state = uiState.fromStack({ 7, 'Dialogue', false })
      assert.equals(state.mode, 'Dialogue')
      assert.equals(#state.stack, 1)
    end)
  end)

  -- The engine hands the mode stack back as USERDATA, not a table. A `type(stack) == 'table'`
  -- test is therefore FALSE for a real window -- which is how a report came to say "screen ->
  -- empty" while a Dialogue window was open and the world was paused. These pin the reader
  -- that replaced it.
  describe('stackOf', function()
    -- newproxy exists in LuaJIT and 5.1, not in 5.4 -- the repo's established guard
    local hasNewproxy = type(newproxy) == 'function'

    it('is empty for nil, and for anything that is not a stack', function()
      assert.equals(#uiState.stackOf(nil), 0)
      assert.equals(#uiState.stackOf(7), 0)
      assert.equals(#uiState.stackOf('Dialogue'), 0)
      assert.equals(#uiState.stackOf({}), 0)
    end)

    it('copies a plain list of names', function()
      local modes = uiState.stackOf({ 'Dialogue', 'Inventory' })
      assert.equals(#modes, 2)
      assert.equals(modes[1], 'Dialogue')
      assert.equals(modes[2], 'Inventory')
    end)

    it('skips junk without losing the real modes', function()
      local modes = uiState.stackOf({ 7, 'Inventory', '', false, 'Dialogue' })
      assert.equals(#modes, 2)
      assert.equals(modes[1], 'Inventory')
      assert.equals(modes[2], 'Dialogue')
    end)

    it('reads a USERDATA stack -- the case a table test gets wrong', function()
      if not hasNewproxy then return end
      local proxy = newproxy(true)
      local meta = getmetatable(proxy)
      -- a userdata list: length plus indexed reads, exactly how the engine's list behaves
      local hidden = { 'Dialogue' }
      meta.__len = function() return #hidden end
      meta.__index = function(_, key) return hidden[key] end
      assert.equals(#uiState.stackOf(proxy), 1)
      assert.equals(uiState.stackOf(proxy)[1], 'Dialogue')
      -- and the table test, for contrast: this is what the old code asked
      assert.is_true(type(proxy) ~= 'table')
    end)

    it('survives a stack that throws when read', function()
      if not hasNewproxy then return end
      local proxy = newproxy(true)
      local meta = getmetatable(proxy)
      meta.__len = function() error('engine exploded') end
      assert.equals(#uiState.stackOf(proxy), 0)
    end)
  end)

  -- TWO causes of a stopped world, which need different remedies. Telling them apart is the
  -- whole point: a mode can be closed by the mod, a message box cannot even be seen from Lua.
  describe('blocking', function()
    it('is not blocked when the world is running', function()
      assert.is_false(uiState.blocking(false, {}).blocked)
      assert.is_false(uiState.blocking(nil, {}).blocked)
      -- even with a window open: an open window does not imply a stopped world
      assert.is_false(uiState.blocking(false, { 'Dialogue' }).blocked)
    end)

    it('blames the open mode when one is on the stack', function()
      local state = uiState.blocking(true, { 'Inventory', 'Dialogue' })
      assert.is_true(state.blocked)
      assert.equals(state.cause, 'menu')
      assert.equals(state.mode, 'Dialogue')
      assert.is_true(type(state.hint) == 'string' and #state.hint > 0)
    end)

    it('refuses to blame one thing when the stack cannot see the cause', function()
      -- This used to say "cause = messageBox". That was a lie: a paused world with an empty mode
      -- stack is equally a cinematic, a loading screen, or the game's own chargen -- and the mod
      -- spent a session acting on the wrong one. The only thing that names the owner is the pause
      -- TAGS, and only a global script can read those.
      local state = uiState.blocking(true, {})
      assert.is_true(state.blocked)
      assert.equals(state.cause, 'unknown')
      assert.is_nil(state.mode)
      -- so the hint must offer the candidates AND say how to tell them apart
      assert.is_true(state.hint:find('message box') ~= nil)
      assert.is_true(state.hint:find('world.pauseTags') ~= nil)
      -- and still name the remedy the host owns, for the one candidate where it applies
      assert.is_true(state.hint:find('host') ~= nil)
    end)

    it('never claims to detect or close the console', function()
      -- The console IS a pause cause (datetimemanager.cpp:259), but the cause is
      -- WindowManager::isConsoleMode() == mConsole->isVisible() (windowmanagerimp.cpp:1746), which
      -- Lua cannot read -- while ui.getConsoleMode() is the console's INPUT MODE (console.hpp:72),
      -- a different thing. So with no window open the honest answer is 'unknown', and the hint
      -- names the console as a candidate the HOST must clear, rather than promising the mod can.
      local state = uiState.blocking(true, {})
      assert.is_true(state.blocked)
      assert.equals(state.cause, 'unknown')
      assert.is_true(state.hint:find('console') ~= nil)
      assert.is_true(state.hint:find('host') ~= nil)
      -- the removed 'console' cause can no longer be produced, even if a caller passes the old
      -- option: a stale caller must not resurrect a claim Lua cannot support
      assert.is_true(uiState.blocking(true, {}, { consoleMode = true }).cause ~= 'console')
      -- and a console that is shut does not mask a window that IS open
      local withMode = uiState.blocking(true, { 'Dialogue' })
      assert.equals(withMode.cause, 'menu')
      assert.equals(withMode.mode, 'Dialogue')
    end)

    it('is equally honest with no stack at all', function()
      local state = uiState.blocking(true, nil)
      assert.is_true(state.blocked)
      assert.equals(state.cause, 'unknown')
    end)
  end)
end)
