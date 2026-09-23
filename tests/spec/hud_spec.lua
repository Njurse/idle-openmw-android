-- tests/spec/hud_spec.lua
-- Turning engine facts into what a player sees (scripts/idle/hud.lua).
--
-- This exists because the engine will not hand over its on-screen text, so the HUD API
-- derives the same information instead. The wording is part of the product: a hint that
-- does not name the key is only half useful, and one that ignores "above you" fails exactly
-- where Morrowind needs it most (the hatch on the ship is overhead).
describe('idle.hud', function()
  local hud = require('scripts.idle.hud')

  describe('kindOf', function()
    it('classifies by the engine-type flags the runtime passes in', function()
      assert.equals('door', hud.kindOf({ isDoor = true }))
      assert.equals('actor', hud.kindOf({ isActor = true }))
      assert.equals('container', hud.kindOf({ isContainer = true }))
      assert.equals('item', hud.kindOf({ isItem = true }))
      assert.equals('activator', hud.kindOf({ isActivator = true }))
      assert.equals('unknown', hud.kindOf({}))
      assert.equals('unknown', hud.kindOf(nil))
    end)

    it('prefers talking to an actor over searching it', function()
      assert.equals('actor', hud.kindOf({ isActor = true, isContainer = true }))
    end)

    it('prefers opening a door over using it as an activator', function()
      assert.equals('door', hud.kindOf({ isDoor = true, isActivator = true }))
    end)
  end)

  describe('describe', function()
    it('names the action and the thing', function()
      local described = hud.describe({ isDoor = true, name = 'hatch', distance = 120 })
      assert.equals('door', described.kind)
      assert.equals('open', described.action)
      assert.equals('open the hatch', described.label)
      assert.equals(120, described.distance)
    end)

    it('copes with an unnamed target', function()
      local described = hud.describe({ isItem = true })
      assert.equals('take', described.action)
      assert.equals('take it', described.label)
    end)

    it('has no action for something unclassifiable', function()
      local described = hud.describe({})
      assert.is_nil(described.action)
    end)
  end)

  describe('relativeHeight', function()
    it('notices what is above the player -- the ship hatch is overhead', function()
      assert.equals('above', hud.relativeHeight(200, 100))
      assert.equals('below', hud.relativeHeight(0, 100))
      assert.equals('level', hud.relativeHeight(110, 100))
    end)

    it('says nothing when it does not know', function()
      assert.is_nil(hud.relativeHeight(nil, 100))
      assert.is_nil(hud.relativeHeight(200, nil))
    end)
  end)

  describe('hints', function()
    it('tells you the key, the direction and the action', function()
      local hints = hud.hints({
        target = { isDoor = true, name = 'hatch', vertical = 'above' },
        activateKey = 'Space',
      })
      assert.is_true(#hints >= 1)
      assert.is_true(hints[1]:find('above', 1, true) ~= nil, hints[1])
      assert.is_true(hints[1]:find('Space', 1, true) ~= nil, hints[1])
      assert.is_true(hints[1]:find('open', 1, true) ~= nil, hints[1])
    end)

    it('still gives a usable hint when the key is unknown', function()
      local hints = hud.hints({ target = { isDoor = true, name = 'hatch' } })
      assert.is_true(hints[1]:find('open', 1, true) ~= nil, hints[1])
    end)

    it('says the game is paused, because that changes everything', function()
      local hints = hud.hints({ paused = true })
      assert.is_true(hints[1]:find('paused', 1, true) ~= nil, hints[1])
    end)

    it('points at the nearest interactable when nothing is in front of you', function()
      local hints = hud.hints({
        interactables = { { name = 'chest', distance = 240, kind = 'container' } },
      })
      assert.is_true(hints[1]:find('chest', 1, true) ~= nil, hints[1])
      assert.is_true(hints[1]:find('240', 1, true) ~= nil, hints[1])
    end)

    it('says so when there is nothing at all', function()
      local hints = hud.hints({ interactables = {} })
      assert.is_true(#hints >= 1)
      assert.is_true(hints[1]:find('Nothing', 1, true) ~= nil, hints[1])
    end)

    it('is never empty, so a caller need not guard', function()
      assert.is_true(#hud.hints() >= 1)
      assert.is_true(#hud.hints(nil) >= 1)
    end)
  end)

  describe('sortByDistance', function()
    it('orders nearest first, ties broken deterministically', function()
      local sorted = hud.sortByDistance({
        { name = 'far', distance = 900 },
        { name = 'near', distance = 30 },
        { name = 'also-far', distance = 900 },
      })
      assert.equals('near', sorted[1].name)
      assert.equals('also-far', sorted[2].name)
      assert.equals('far', sorted[3].name)
    end)

    it('keeps entries with no distance, at the end', function()
      local sorted = hud.sortByDistance({ { name = 'x' }, { name = 'y', distance = 10 } })
      assert.equals('y', sorted[1].name)
      assert.equals('x', sorted[2].name)
    end)

    it('survives nil and junk', function()
      assert.equals(0, #hud.sortByDistance(nil))
      assert.equals(0, #hud.sortByDistance({ 1, 2 }))
    end)
  end)
end)
