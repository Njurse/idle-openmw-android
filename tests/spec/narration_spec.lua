-- tests/spec/narration_spec.lua
-- The HUD narration line (scripts/idle/narration.lua) and where it is drawn.
--
-- The narration is small but it is the only thing on screen while the console is
-- hidden, so its rules matter: it must fit in the box it is given, and an operator's
-- note must win over the mod's own line without either being able to break the render.
--
-- NOTE ON NON-ASCII: this file builds every multi-byte character with string.char
-- instead of writing it literally. Shell heredocs in this workspace mangle non-ASCII
-- and backslash escapes, and a literal written that way silently becomes a DIFFERENT
-- character -- which then fails an assertion whose expected value was mangled the same
-- way, or worse, passes while testing the wrong thing.
-- tools/dev/check_ascii.py enforces that rule for .lua sources.
describe('idle.narration', function()
  local narration = require('scripts.idle.narration')
  local uiLayout = require('scripts.idle.uiLayout')

  local ELLIPSIS = string.char(226, 128, 166)      -- U+2026, three bytes in UTF-8
  local E_ACUTE = string.char(195, 169)            -- U+00E9, two bytes in UTF-8

  describe('sanitize', function()
    it('collapses whitespace and newlines to single spaces', function()
      assert.equals('one two three', narration.sanitize('  one\n\ntwo   three  '))
    end)

    it('handles nil and non-strings', function()
      assert.equals('', narration.sanitize(nil))
      assert.equals('42', narration.sanitize(42))
    end)

    it('clamps over-long text and marks it', function()
      local out = narration.sanitize(string.rep('word ', 200), 40)
      assert.is_true(#out <= 40, 'clamped text was ' .. #out .. ' bytes')
      -- NB compare the last THREE bytes: the ellipsis is not one byte, and `sub(-1)`
      -- would compare a single continuation byte against a whole character.
      assert.equals(ELLIPSIS, out:sub(-3))
    end)

    it('does not touch text that already fits', function()
      assert.equals('short enough', narration.sanitize('short enough', 40))
    end)

    it('clamps short limits without producing an empty string', function()
      local out = narration.sanitize(string.rep('word ', 50), 8)
      assert.is_true(#out > 0)
      assert.is_true(#out <= 8)
    end)

    it('never splits a UTF-8 character (Morrowind text is full of accents)', function()
      -- Checking "does it end with a continuation byte" is NOT the test: a string ending
      -- in a complete two-byte character legitimately ends with one. The real question is
      -- whether the bytes still form valid sequences, so decode them.
      local function isUtf8Clean(text)
        local i = 1
        while i <= #text do
          local b = text:byte(i)
          local size
          if b < 0x80 then size = 1
          elseif b >= 0xF0 then size = 4
          elseif b >= 0xE0 then size = 3
          elseif b >= 0xC0 then size = 2
          else return false end                      -- stray continuation byte
          for k = 1, size - 1 do
            local c = text:byte(i + k)
            if c == nil or c < 0x80 or c >= 0xC0 then return false end
          end
          i = i + size
        end
        return true
      end

      local accented = string.rep('caf' .. E_ACUTE .. ' ', 30)
      local out = narration.sanitize(accented, 41)
      assert.is_true(#out <= 41, 'clamp overran: ' .. #out .. ' bytes')
      assert.is_true(isUtf8Clean(out:sub(1, #out - #ELLIPSIS)),
        'clamped text left a split character: ' .. out)
    end)
  end)

  describe('wrap', function()
    it('keeps every line within the column limit', function()
      local lines = narration.wrap(string.rep('alpha bravo charlie delta ', 12), 20)
      for _, line in ipairs(lines) do
        assert.is_true(#line <= 20, ('line too long (%d): %s'):format(#line, line))
      end
      assert.is_true(#lines > 1, 'long text should wrap onto several lines')
    end)

    it('splits a word longer than a whole line instead of overflowing', function()
      local lines = narration.wrap(string.rep('x', 55), 20)
      for _, line in ipairs(lines) do assert.is_true(#line <= 20) end
      assert.equals(3, #lines)
    end)

    it('always returns at least one line', function()
      assert.equals(1, #narration.wrap('', 20))
      assert.equals(1, #narration.wrap(nil, 20))
    end)

    it('preserves the words', function()
      local lines = narration.wrap('the quick brown fox', 9)
      assert.equals('the quick', lines[1])
      assert.equals('brown fox', lines[2])
    end)
  end)

  describe('the store', function()
    it('reports a change only when the text actually changes', function()
      local n = narration.new('first')
      assert.equals('first', n:get())
      assert.is_false(n:set('first'), 'setting the same text is not a change')
      assert.is_true(n:set('second'))
      assert.equals('second', n:get())
      local revision = n:revision()
      n:set('second')
      assert.equals(revision, n:revision(), 'a no-op set must not bump the revision')
      n:set('third')
      assert.equals(revision + 1, n:revision())
    end)

    it('sanitizes what it is given', function()
      local n = narration.new()
      n:set('  a\n b  ')
      assert.equals('a b', n:get())
    end)
  end)

  describe('choose', function()
    it("prefers the operator's line over the mod's", function()
      assert.equals('watch this', narration.choose('watch this', 'the mod thinks'))
    end)

    it("falls back to the mod's line when the operator has none", function()
      assert.equals('the mod thinks', narration.choose(nil, 'the mod thinks'))
      assert.equals('the mod thinks', narration.choose('', 'the mod thinks'))
      assert.equals('the mod thinks', narration.choose('   ', 'the mod thinks'))
    end)

    it('is empty when there is nothing to say', function()
      assert.equals('', narration.choose(nil, nil))
    end)
  end)

  describe('where it is drawn', function()
    local function base(width, height)
      return uiLayout.compute({ x = width, y = height }, { textScale = 1 })
    end

    it('exists, is centred, and sits above the command bar', function()
      local layout = base(1080, 2340)
      local rect = layout.narration
      assert.is_not_nil(rect)
      local leftGap = rect.x
      local rightGap = 1080 - (rect.x + rect.width)
      assert.is_true(math.abs(leftGap - rightGap) <= 2,
        ('not centred: %d vs %d'):format(leftGap, rightGap))
      assert.is_true(rect.y + rect.height <= layout.bar.y,
        'narration overlaps the command bar')
    end)

    it('fits on a landscape desktop screen too', function()
      local layout = base(1600, 900)
      local rect = layout.narration
      assert.is_true(rect.x >= 0 and rect.x + rect.width <= 1600)
      assert.is_true(rect.y > 0 and rect.y + rect.height <= layout.bar.y)
    end)

    it('is wide enough for a real sentence on a small screen', function()
      local layout = base(720, 1280)
      assert.is_true(layout.narration.width >= 300,
        'narration box is too narrow: ' .. layout.narration.width)
    end)
  end)
end)
