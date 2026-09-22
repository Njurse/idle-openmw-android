-- tests/spec/lifecycle_spec.lua
-- "Where are we in the game's life?" -- the gate that stops the director from
-- driving the character during character creation (scripts/idle/lifecycle.lua).
describe('idle.lifecycle', function()
  local lifecycle = require('scripts.idle.lifecycle')

  describe('phase precedence', function()
    it('is the menu when there is no player at all', function()
      assert.equals(lifecycle.phase({ playerExists = false }).id, 'menu')
    end)

    it('is loading when the engine shows a load screen', function()
      assert.equals(lifecycle.phase({ playerExists = true, uiKind = 'loading' }).id, 'loading')
    end)

    it('is the menu when the main menu is open', function()
      assert.equals(lifecycle.phase({ playerExists = true, uiKind = 'menu' }).id, 'menu')
    end)

    it('is character creation while isCharGenFinished is false', function()
      local phase = lifecycle.phase({ playerExists = true, charGenFinished = false })
      assert.equals(phase.id, 'chargen')
      assert.is_false(phase.acting)
    end)

    it('is character creation when a Chargen UI mode is open, even if the flag is missing', function()
      assert.equals(lifecycle.phase({ playerExists = true, uiKind = 'chargen' }).id, 'chargen')
    end)

    it('is dead when the character is at zero health', function()
      assert.equals(lifecycle.phase({ playerExists = true, charGenFinished = true, dead = true }).id, 'dead')
    end)

    it('is the world once character creation is done', function()
      assert.equals(lifecycle.phase({ playerExists = true, charGenFinished = true }).id, 'world')
    end)
  end)

  describe('the unknown-flag safety net', function()
    it('treats an engine that cannot report char-gen as "in the world"', function()
      -- charGenFinished == nil must NOT lock the mod out of playing.
      local phase = lifecycle.phase({ playerExists = true })
      assert.equals(phase.id, 'world')
      assert.is_true(phase.acting)
    end)
  end)

  describe('acting', function()
    it('allows acting only in the world', function()
      assert.is_true(lifecycle.mayAct(lifecycle.describe('world')))
      assert.is_false(lifecycle.mayAct(lifecycle.describe('chargen')))
      assert.is_false(lifecycle.mayAct(lifecycle.describe('menu')))
      assert.is_false(lifecycle.mayAct(lifecycle.describe('loading')))
      assert.is_false(lifecycle.mayAct(lifecycle.describe('dead')))
      assert.is_false(lifecycle.mayAct(nil))
    end)

    it('explains itself with a note', function()
      assert.is_string(lifecycle.describe('chargen').note)
      assert.equals(lifecycle.describe('chargen').label, 'Character creation')
    end)
  end)

  describe('describe', function()
    it('falls back to the world for an unknown id', function()
      assert.equals(lifecycle.describe('nonsense').id, 'world')
      assert.equals(lifecycle.describe(nil).id, 'world')
    end)
  end)
end)
