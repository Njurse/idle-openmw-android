-- tests/spec/uiReport_spec.lua
-- The UI report and the dev command channel (scripts/idle/uiReport.lua).
--
-- The report is how a running game is understood from outside: it is printed to the engine
-- log and read by a person or a monitor. So it must (a) never throw on partial data -- a
-- report that fails when the UI is half-known is useless exactly when it is needed -- and
-- (b) say plainly what is NOT available instead of printing nothing.
describe('idle.uiReport', function()
  local uiReport = require('scripts.idle.uiReport')

  describe('format', function()
    it('names the open window when the engine reports one', function()
      local text = uiReport.format({ uiModes = { 'Dialogue', 'Interface' } })
      assert.is_true(text:find('Dialogue > Interface', 1, true) ~= nil, text)
    end)

    it('says so when nothing is open, rather than printing an empty line', function()
      local text = uiReport.format({ uiModes = {} })
      assert.is_true(text:find('empty', 1, true) ~= nil, text)
    end)

    it('distinguishes "unavailable" from "empty"', function()
      local text = uiReport.format({ uiModes = 'no _getUiModeStack' })
      assert.is_true(text:find('unavailable', 1, true) ~= nil, text)
    end)

    it('survives an empty table and nil', function()
      assert.is_true(#uiReport.format({}) > 0)
      assert.is_true(#uiReport.format(nil) > 0)
    end)

    it('reports our own elements and says they are ours only', function()
      local text = uiReport.format({
        elements = {
          { layout = { props = { name = 'idle_narration' } } },
          { layout = { props = { name = 'idle_narration' } } },
          { layout = { props = { name = 'idle_row_1' } } },
        },
      })
      assert.is_true(text:find('lua elements', 1, true) ~= nil, text)
      assert.is_true(text:find('ours only', 1, true) ~= nil, text)
      assert.is_true(text:find('idle_narration x2', 1, true) ~= nil, text)
    end)

    it('shows the geometry it assumes and the boxes it drew', function()
      local text = uiReport.format({
        screen = { x = 1600, y = 900 },
        scale = 1.22,
        narrationRect = { x = 160, y = 620, width = 1280, height = 159 },
      })
      assert.is_true(text:find('1600x900', 1, true) ~= nil, text)
      assert.is_true(text:find('1.22', 1, true) ~= nil, text)
      assert.is_true(text:find('160,620 1280x159', 1, true) ~= nil, text)
    end)

    it('reports pause and chargen state, which change what we may do', function()
      local text = uiReport.format({ paused = true, charGenDone = false, phase = 'chargen' })
      assert.is_true(text:find('paused', 1, true) ~= nil)
      assert.is_true(text:find('chargen', 1, true) ~= nil)
      assert.is_true(text:find('false', 1, true) ~= nil)
    end)
  end)

  describe('parseCommand', function()
    it('accepts ui and dump as the same verb', function()
      assert.equals('dump', uiReport.parseCommand('ui').verb)
      assert.equals('dump', uiReport.parseCommand('dump').verb)
      assert.equals('dump', uiReport.parseCommand('  DUMP  ').verb)
    end)

    it('parses a heartbeat interval', function()
      local command = uiReport.parseCommand('heartbeat 15')
      assert.equals('heartbeat', command.verb)
      assert.equals(15, command.seconds)
    end)

    it('parses a note, keeping its text', function()      local command = uiReport.parseCommand('note walking to the trap door')
      assert.equals('note', command.verb)
      assert.equals('walking to the trap door', command.text)
    end)

    it('parses a camera tweak, keeping its argument', function()
      local command = uiReport.parseCommand('camera on')
      assert.equals('camera', command.verb)
      assert.equals('on', command.text)
      assert.equals('pitch -0.7', uiReport.parseCommand('camera pitch -0.7').text)
    end)

    it('parses an economy probe, keeping its argument', function()
      local command = uiReport.parseCommand('economy gold 100')
      assert.equals('economy', command.verb)
      assert.equals('gold 100', command.text)
    end)

    it('ignores blank input and empty files', function()
      assert.is_nil(uiReport.parseCommand(''))
      assert.is_nil(uiReport.parseCommand('   '))
      assert.is_nil(uiReport.parseCommand(nil))
    end)

    it('reports an unknown verb instead of silently doing nothing', function()
      local command = uiReport.parseCommand('frobnicate now')
      assert.equals('unknown', command.verb)
    end)
  end)
end)
