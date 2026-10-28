-- tests/spec/appPayload_spec.lua
-- The contract between the mod and the native Android app.
--
-- These specs are behavioural: they assert what the app can rely on (a fraction is always a number
-- in 0..1; an unknown command is refused with a reason), not the incidental field order.

describe('idle.appPayload', function()
  local appPayload = require('scripts.idle.appPayload')

  describe('project', function()
    it('carries the director\'s own words through untouched', function()
      local payload = appPayload.project({
        goal = 'shop', goalReason = 'out of potions', mode = 'auto', phase = 'world',
        cell = 'Seyda Neen, Arrille\'s Tradehouse',
      })
      assert.equals('shop', payload.goal)
      assert.equals('out of potions', payload.goalReason)
      assert.equals('auto', payload.mode)
      assert.equals('Seyda Neen, Arrille\'s Tradehouse', payload.cell)
      assert.equals(appPayload.VERSION, payload.version)
    end)

    it('clamps a fraction into 0..1 rather than passing a wrong number on', function()
      local payload = appPayload.project({
        status = { healthFraction = 1.4, magickaFraction = -2, fatigueFraction = 0.72 },
      })
      assert.equals(1, payload.status.healthFraction)
      assert.equals(0, payload.status.magickaFraction)
      assert.equals(0.72, payload.status.fatigueFraction)
    end)

    it('reports an unusable fraction as 0, not as a missing key', function()
      -- A missing key leaves the app's previous value on screen, which looks live and is not.
      local payload = appPayload.project({ status = { healthFraction = 'lots' } })
      assert.equals(0, payload.status.healthFraction)
    end)

    it('survives a partial panel', function()
      local payload = appPayload.project({ goal = 'fight' })
      assert.equals('fight', payload.goal)
      assert.equals('', payload.goalReason)
      assert.is_true(type(payload.status) == 'table')
      assert.is_true(type(payload.player) == 'table')
    end)

    it('survives no panel at all', function()
      local payload = appPayload.project(nil)
      assert.is_true(type(payload) == 'table')
      assert.equals('idle', payload.goal)
    end)

    it('rounds gold and level to whole numbers', function()
      local payload = appPayload.project({ player = { gold = 1240.4, level = 5.6 } })
      assert.equals(1240, payload.player.gold)
      assert.equals(6, payload.player.level)
    end)

    it('includes encumbrance only when the panel has it', function()
      assert.is_nil(appPayload.project({ player = { gold = 1 } }).player.encumbrance)
      local load = appPayload.project({ player = { encumbrance = { current = 35, max = 90 } } })
      assert.equals(35, load.player.encumbrance.current)
      assert.equals(90, load.player.encumbrance.max)
    end)

    it('sends only the newest log line', function()
      local payload = appPayload.project({ log = {
        { time = 1, message = 'first' }, { time = 2, message = 'second' },
      } })
      assert.equals('second', payload.lastLog.message)
      assert.equals(2, payload.lastLog.time)
    end)

    it('serialises with the mod\'s own json encoder', function()
      -- The app decodes with org.json, so the payload has to be valid JSON by that standard too.
      local encoder = require('scripts.idle.json')
      local text = encoder.encode(appPayload.project({ goal = 'a "quoted" goal' }))
      local decoded = encoder.decode(text)
      assert.equals('a "quoted" goal', decoded.goal)
    end)
  end)

  describe('command', function()
    it('maps every button in docs/app-ui.md to something the director knows', function()
      local buttons = { 'wait', 'go_town', 'roam', 'talk', 'attack', 'flee',
                        'inventory', 'journal', 'magic', 'rest' }
      for _, id in ipairs(buttons) do
        local entry = appPayload.command('{"command":"' .. id .. '"}')
        assert.is_true(entry ~= nil, 'no mapping for ' .. id)
        assert.is_true(type(entry.action) == 'string')
      end
    end)

    it('refuses Sneak, because the mod has no sneak goal or action', function()
      -- app-ui.md asks for a Sneak button; the mod has no verb for it (the word exists only as a
      -- SKILL name), so this asserts the refusal rather than a mapping that would be a silent no-op.
      local entry, reason = appPayload.command('{"command":"sneak"}')
      assert.is_nil(entry)
      assert.is_true(reason:find('sneak') ~= nil)
    end)

    it('turns a window button into a launch with the mode the engine wants', function()
      local entry = appPayload.command('{"command":"journal"}')
      assert.equals('launch', entry.action)
      assert.equals('Journal', entry.payload.mode)
    end)

    it('passes an attached payload through for the director to validate', function()
      local entry = appPayload.command('{"command":"go_town","payload":{"id":"balmora"}}')
      assert.equals('go_town', entry.action)
      assert.equals('balmora', entry.payload.id)
    end)

    it('refuses an unknown command and says which', function()
      local entry, reason = appPayload.command('{"command":"dance"}')
      assert.is_nil(entry)
      assert.is_true(reason:find('dance') ~= nil)
    end)

    it('refuses unreadable text rather than throwing', function()
      local entry, reason = appPayload.command('{not json')
      assert.is_nil(entry)
      assert.is_true(reason ~= nil)
      -- NB: command() returns TWO values, so `command('')[1]` indexes the first of them (nil) and
      -- throws in Lua. Capture both explicitly.
      local emptyEntry, emptyReason = appPayload.command('')
      assert.is_nil(emptyEntry)
      assert.is_true(emptyReason ~= nil)
      local nilEntry, nilReason = appPayload.command(nil)
      assert.is_nil(nilEntry)
      assert.is_true(nilReason ~= nil)
    end)

    it('refuses a command with no name', function()
      local entry, reason = appPayload.command('{"id":7}')
      assert.is_nil(entry)
      assert.is_true(reason:find('name') ~= nil)
    end)
  end)
end)
