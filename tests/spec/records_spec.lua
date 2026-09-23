-- tests/spec/records_spec.lua
-- Shaping the engine's read-only dialogue records (scripts/idle/records.lua) -- journal
-- (quest) records, topic lines, and voice lines.
--
-- These records are what makes the journal and the dialogue side possible at all:
-- core.dialogue.journal.records[id].questName names a quest, .infos[] carries one entry per
-- stage with the journal text, and core.dialogue.voice.records[id].infos[].sound names the
-- voice file (see docs/openmw-lua-api.md section 14 for the citations).
describe('idle.records', function()
  local records = require('scripts.idle.records')

  local function info(fields)
    local out = { id = 'i1', text = 'hello' }
    for key, value in pairs(fields or {}) do out[key] = value end
    return out
  end

  describe('substitute', function()
    it('fills the placeholders we can actually know', function()
      local text, count = records.substitute('Congratulations, %PCName the %NextPCRank.', {
        PCName = 'DeepSeek',
      })
      -- the one we cannot know stays visible rather than being invented or dropped
      assert.equals(text, 'Congratulations, DeepSeek the %NextPCRank.')
      assert.equals(count, 1)
    end)

    it('leaves text alone when there is nothing to fill', function()
      local text, count = records.substitute('no placeholders here', {})
      assert.equals(text, 'no placeholders here')
      assert.equals(count, 0)
      assert.is_nil(records.substitute(nil, {}))
      assert.equals(records.substitute('x', nil), 'x')
    end)
  end)

  describe('tidy', function()
    it('collapses the stored wrapping', function()
      assert.equals(records.tidy('  a\n\n  b   c  '), 'a b c')
    end)

    it('clamps without splitting a character or a word', function()
      local long = string.rep('word ', 200)
      local out = records.tidy(long, 40)
      assert.is_true(#out <= 40)
      assert.is_true(out:find('word') ~= nil)
      -- never ends mid-character: the last byte is not a continuation byte
      local last = out:byte(-1)
      assert.is_false(last >= 128 and last < 192)
      assert.is_nil(records.tidy(nil))
    end)
  end)

  describe('shapeRecord', function()
    local function record(fields)
      local out = { id = 'a2_4_milogone', name = 'A2_4_MiloGone', questName = 'Mehra Milo', infos = {} }
      for key, value in pairs(fields or {}) do out[key] = value end
      return out
    end

    it('carries the quest name -- how a quest stops being an id', function()
      local shaped = records.shapeRecord(record(), { family = 'journal' })
      assert.equals(shaped.id, 'a2_4_milogone')
      assert.equals(shaped.questName, 'Mehra Milo')
      assert.equals(shaped.family, 'journal')
      assert.equals(shaped.infosTotal, 0)
    end)

    it('keeps the journal-only fields, and invents nothing for them', function()
      local shaped = records.shapeRecord(record({
        infos = { info({ questStage = 10, isQuestFinished = false, text = 'go to Balmora' }) },
      }), { family = 'journal' })
      local first = shaped.infos[1]
      assert.equals(first.questStage, 10)
      assert.is_false(first.questFinished)
      assert.equals(first.text, 'go to Balmora')
      -- a topic record has no questStage, so the field must be ABSENT, not false/0
      assert.is_nil(first.questRestart)
    end)

    it("carries a voice line's sound file", function()
      local shaped = records.shapeRecord(record({
        infos = { info({ sound = 'sound/vo/a/f/fle_af003.mp3', text = 'flee' }) },
      }), { family = 'voice' })
      assert.equals(shaped.infos[1].sound, 'sound/vo/a/f/fle_af003.mp3')
    end)

    it('CAPS the info list and says how many it dropped', function()
      local many = {}
      for index = 1, 300 do many[index] = info({ id = 'i' .. tostring(index) }) end
      local shaped = records.shapeRecord(record({ infos = many }), { maxInfos = 25 })
      assert.equals(#shaped.infos, 25)
      assert.equals(shaped.infosTotal, 300)
      -- silently returning 25 of 300 would look like the record only has 25 entries
      assert.equals(shaped.infosTruncated, 275)
    end)

    it('does not report truncation when nothing was dropped', function()
      local shaped = records.shapeRecord(record({ infos = { info(), info() } }), { maxInfos = 25 })
      assert.equals(#shaped.infos, 2)
      assert.is_nil(shaped.infosTruncated)
    end)

    it('survives a record with no usable infos', function()
      assert.is_nil(records.shapeRecord(nil))
      local shaped = records.shapeRecord({ id = 'x' })
      assert.equals(shaped.infosTotal, 0)
      assert.equals(#shaped.infos, 0)
    end)
  end)

  describe('the joins a journal needs', function()
    it('finds the entries for one stage', function()
      local shaped = records.shapeRecord({
        id = 'q', infos = {
          info({ questStage = 10, text = 'first' }),
          info({ questStage = 20, text = 'second' }),
          info({ questStage = 10, text = 'also first' }),
        },
      })
      local at10 = records.entriesForStage(shaped, 10)
      assert.equals(#at10, 2)
      assert.equals(at10[1].text, 'first')
      -- a stage with no entry is an empty list, not a guess
      assert.equals(#records.entriesForStage(shaped, 99), 0)
      assert.equals(#records.entriesForStage(nil, 10), 0)
    end)

    it('can tell that a record contains a finished entry', function()
      -- input uses the ENGINE's field name (isQuestFinished); the shaped output uses ours
      -- (questFinished). Getting that backwards in a fixture is easy, so it is spelled out.
      local done = records.shapeRecord({ id = 'q', infos = { info({ isQuestFinished = true }) } })
      assert.is_true(records.isFinished(done))
      local open = records.shapeRecord({ id = 'q', infos = { info({ isQuestFinished = false }) } })
      assert.is_false(records.isFinished(open))
      assert.is_false(records.isFinished(nil))
    end)
  end)

  describe('familyCounts', function()
    it('reports the families in a fixed order, with their counts', function()
      local list = records.familyCounts({ voice = 900, journal = 400, topic = 3000 })
      assert.equals(#list, 3)
      -- fixed order (M.FAMILIES), so two runs are comparable
      assert.equals(list[1].family, 'journal')
      assert.equals(list[1].records, 400)
      assert.equals(list[2].family, 'topic')
      assert.equals(list[2].records, 3000)
      assert.equals(list[3].family, 'voice')
    end)

    it('leaves out a family the engine did not report, rather than claiming zero', function()
      local list = records.familyCounts({ journal = 5 })
      assert.equals(#list, 1)
      assert.equals(list[1].family, 'journal')
    end)

    it('is empty when nothing was readable', function()
      assert.equals(#records.familyCounts(nil), 0)
    end)
  end)

  -- ---------------------------------------------------------------------------
  -- userdata
  -- ---------------------------------------------------------------------------
  -- A record, and its `infos` list, are engine USERDATA. These guards used to be
  -- `type(x) == 'table'`, so every one of these functions returned nil or empty for EVERY real
  -- record -- while this very file stayed green, because the cases above use plain tables.
  describe('userdata records', function()
    local hasNewproxy = type(newproxy) == 'function'

    --- A userdata answering fields from `fields`, like an engine record.
    local function ud(fields)
      local proxy = newproxy(true)
      getmetatable(proxy).__index = function(_, key) return fields[key] end
      return proxy
    end

    --- A userdata list: `#` via __len, `[i]` via __index -- how the engine's lists read.
    local function udList(items)
      local proxy = newproxy(true)
      local mt = getmetatable(proxy)
      mt.__index = function(_, index) return items[index] end
      mt.__len = function() return #items end
      return proxy
    end

    it('shapes a record whose own fields AND info list are userdata', function()
      if not hasNewproxy then return end
      local record = ud({
        id = 'q1', name = 'A Quest',
        infos = udList({ ud({ id = 'i1', text = 'first' }), ud({ id = 'i2', text = 'second' }) }),
      })
      local shaped = records.shapeRecord(record, { family = 'journal' })
      assert.equals('q1', shaped.id)
      assert.equals('A Quest', shaped.name)
      assert.equals('journal', shaped.family)
      assert.equals(2, shaped.infosTotal)
      assert.equals('first', shaped.infos[1].text)
      assert.equals('second', shaped.infos[2].text)
    end)

    it('shapes one info entry read from userdata', function()
      if not hasNewproxy then return end
      local shaped = records.shapeInfo(ud({ id = 'i9', text = 'hi there', questStage = 10 }))
      assert.equals('i9', shaped.id)
      assert.equals('hi there', shaped.text)
      assert.equals(10, shaped.questStage)
    end)

    it('finds the journal entry for a stage in a userdata record', function()
      if not hasNewproxy then return end
      local record = ud({ infos = udList({
        ud({ id = 'a', text = 'stage 5', questStage = 5 }),
        ud({ id = 'b', text = 'stage 10', questStage = 10 }),
      }) })
      local found = records.entriesForStage(record, 10)
      assert.equals(1, #found)
      assert.equals('b', found[1].id)
    end)

    it('sees a finished-state entry in a userdata record', function()
      if not hasNewproxy then return end
      assert.is_true(records.isFinished(ud({ infos = udList({ ud({ id = 'a', questFinished = true }) }) })))
      assert.is_false(records.isFinished(ud({ infos = udList({ ud({ id = 'a' }) }) })))
    end)
  end)
end)
