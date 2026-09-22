-- tests/spec/theme_spec.lua
-- "Paint the console in Morrowind's own colours" -- scripts/idle/theme.lua.
describe('idle.theme', function()
  local theme = require('scripts.idle.theme')

  describe('the shipped palette', function()
    it('is Morrowind\'s: tan normal, parchment header, red health', function()
      local p = theme.PALETTE
      -- 202,165,96 -- the Morrowind tan
      assert.is_true(math.abs(p.normal.r - 202 / 255) < 1e-6)
      assert.is_true(math.abs(p.normal.g - 165 / 255) < 1e-6)
      assert.is_true(math.abs(p.normal.b - 96 / 255) < 1e-6)
      -- 223,201,159 -- parchment (headers, hover)
      assert.is_true(math.abs(p.header.r - 223 / 255) < 1e-6)
      -- 200,60,30 -- health / negative
      assert.is_true(math.abs(p.health.g - 60 / 255) < 1e-6)
    end)

    it('keeps every colour inside 0..1', function()
      for name, c in pairs(theme.PALETTE) do
        for _, channel in ipairs({ 'r', 'g', 'b', 'a' }) do
          local v = c[channel]
          assert.is_true(v ~= nil and v >= 0 and v <= 1,
            ('%s.%s out of range: %s'):format(name, channel, tostring(v)))
        end
      end
    end)
  end)

  describe('parse', function()
    it('reads a Morrowind "r,g,b" string into fractions', function()
      local c = theme.parse('202,165,96')
      assert.is_true(math.abs(c.r - 202 / 255) < 1e-6)
      assert.equals(c.a, 1)
    end)

    it('tolerates surrounding whitespace', function()
      assert.is_true(theme.parse(' 0 , 150 , 60 ') ~= nil)
    end)

    it('returns nil for junk rather than painting black', function()
      assert.is_nil(theme.parse('not a colour'))
      assert.is_nil(theme.parse('1,2'))
      assert.is_nil(theme.parse(nil))
      assert.is_nil(theme.parse(7))
    end)
  end)

  describe('colors', function()
    it('adopts the live game colours when the engine offers them', function()
      local get = function(name)
        if name == 'FontColor_color_normal' then return '1,2,3' end
      end
      local c = theme.colors(get)
      assert.is_true(math.abs(c.normal.r - 1 / 255) < 1e-6)
      assert.is_true(math.abs(c.normal.b - 3 / 255) < 1e-6)
      -- everything else keeps the shipped value
      assert.is_true(math.abs(c.header.r - 223 / 255) < 1e-6)
    end)

    it('falls back cleanly with no engine getter', function()
      local c = theme.colors(nil)
      assert.is_true(math.abs(c.normal.r - 202 / 255) < 1e-6)
    end)

    it('ignores a getter that throws or returns junk', function()
      local thrown = theme.colors(function() error('no GMSTs here') end)
      assert.is_true(math.abs(thrown.normal.r - 202 / 255) < 1e-6)
      local junk = theme.colors(function() return 'garbage' end)
      assert.is_true(math.abs(junk.normal.r - 202 / 255) < 1e-6)
    end)
  end)

  describe('load / colour', function()
    it('loads the morrowind theme by default', function()
      assert.equals(theme.load(nil).name, 'morrowind')
      assert.equals(theme.load('nonsense').name, 'morrowind')
    end)

    it('loads the plain theme when asked', function()
      assert.equals(theme.load('plain').name, 'plain')
      -- plain is brighter than Morrowind's tan
      assert.is_true(theme.load('plain').palette.normal.r > theme.load('morrowind').palette.normal.r)
    end)

    it('resolves a role to a colour, and unknown roles to nil', function()
      local t = theme.load('morrowind')
      assert.is_not_nil(theme.colour(t, 'goal'))
      -- 'header' is a palette entry, not a role
      assert.is_nil(theme.colour(t, 'header'))
      assert.is_nil(theme.colour(t, 'not-a-role'))
      assert.is_nil(theme.colour(nil, 'goal'))
    end)
  end)

  describe('rowColour', function()
    local t = theme.load('morrowind')

    it('paints headings as headers', function()
      assert.equals(theme.rowColour(t, { kind = 'heading' }), theme.colour(t, 'heading'))
    end)

    it('paints a log row by its level', function()
      assert.equals(theme.rowColour(t, { kind = 'log', level = 'bad' }), theme.colour(t, 'alert'))
      assert.equals(theme.rowColour(t, { kind = 'log', level = 'warn' }), theme.colour(t, 'negative'))
      assert.equals(theme.rowColour(t, { kind = 'log', level = 'good' }), theme.colour(t, 'positive'))
      assert.equals(theme.rowColour(t, { kind = 'log' }), theme.colour(t, 'log'))
    end)

    it('paints an ordinary row as the base text colour', function()
      assert.equals(theme.rowColour(t, { kind = 'info' }), theme.colour(t, 'row'))
      assert.equals(theme.rowColour(t, nil), theme.colour(t, 'row'))
    end)
  end)

  describe('poolColour', function()
    it('has a colour per stat pool', function()
      local t = theme.load('morrowind')
      assert.equals(theme.poolColour(t, 'health'), t.palette.health)
      assert.equals(theme.poolColour(t, 'magicka'), t.palette.magic)
      assert.equals(theme.poolColour(t, 'fatigue'), t.palette.fatigue)
      assert.is_nil(theme.poolColour(t, 'luck'))
    end)
  end)
end)
