-- scripts/idle/theme.lua
-- The console's palette: Morrowind's own UI colours, and the roles it paints.
--
-- WHY THESE EXACT NUMBERS
-- -----------------------
-- They are Morrowind's GMST font colours, verbatim, as OpenMW ships them in
-- `files/openmw.cfg` (`fallback=FontColor_color_*`). The classic Morrowind tan is
-- `202,165,96`; headers and hover text are the parchment `223,201,159`; health is
-- the deep red `200,60,30`; magicka blue `53,69,159`; fatigue green `0,150,60`.
-- Hard-coding them keeps this module PURE (engine-free, unit-testable); the
-- runtime prefers the *live* values via `colors(getGmst)` when the game exposes
-- them, so a modded Morrowind with different colours still matches.
--
-- THE FONT (and the honest limit)
-- -------------------------------
-- The console text uses the engine's own UI font, which is Morrowind's: OpenMW
-- maps `Fonts_Font_0` = **MysticCards**, `Fonts_Font_2` = **DemonicLetters**
-- (`files/openmw.cfg:68-70`), and the MWUI `textNormal`/`textHeader` templates
-- carry no font of their own. Lua *cannot* choose a different family: the Lua
-- text element exposes only `text`, `textSize`, `textColor`, `wordWrap`, … and
-- no font property (`components/lua_ui/text.cpp:52`). So "the Morrowind font" is
-- already what you see; what this module changes is the *colour*, and
-- `ui.textScale` changes the size.

local M = {}

--- Role -> the game's GMST/fallback name, so `colors()` can adopt live values.
M.GMST = {
  normal     = 'FontColor_color_normal',
  normalOver = 'FontColor_color_normal_over',
  pressed    = 'FontColor_color_normal_pressed',
  header     = 'FontColor_color_header',
  disabled   = 'FontColor_color_disabled',
  link       = 'FontColor_color_link',
  answer     = 'FontColor_color_answer',
  negative   = 'FontColor_color_negative',
  positive   = 'FontColor_color_positive',
  health     = 'FontColor_color_health',
  magic      = 'FontColor_color_magic',
  fatigue    = 'FontColor_color_fatigue',
  misc       = 'FontColor_color_misc',
  focus      = 'FontColor_color_focus',
}

local function frac(r, g, b, a) return { r = r / 255, g = g / 255, b = b / 255, a = a or 1 } end

--- The shipped palette: Morrowind's UI colours as `{ r, g, b, a }` in 0..1.
M.PALETTE = {
  normal     = frac(202, 165, 96),   -- the Morrowind tan
  normalOver = frac(223, 201, 159),  -- parchment (headers, hover)
  pressed    = frac(243, 237, 221),
  header     = frac(223, 201, 159),
  disabled   = frac(179, 168, 135),  -- dimmed / secondary
  link       = frac(112, 126, 207),  -- topic blue
  answer     = frac(150, 50, 30),
  negative   = frac(200, 60, 30),
  positive   = frac(223, 201, 159),
  health     = frac(200, 60, 30),
  magic      = frac(53, 69, 159),
  fatigue    = frac(0, 150, 60),
  misc       = frac(0, 205, 205),
  focus      = frac(80, 80, 80),
  -- not a GMST: the dark translucent panel behind the text
  panel      = { r = 0, g = 0, b = 0, a = 0.62 },
}

--- A high-contrast alternative, for legibility on a bright phone screen.
M.PLAIN_PALETTE = {
  normal     = frac(235, 235, 235),
  normalOver = frac(255, 255, 255),
  pressed    = frac(255, 255, 255),
  header     = frac(255, 235, 150),
  disabled   = frac(150, 150, 150),
  link       = frac(120, 170, 255),
  answer     = frac(255, 140, 120),
  negative   = frac(255, 90, 90),
  positive   = frac(140, 230, 140),
  health     = frac(255, 90, 90),
  magic      = frac(140, 170, 255),
  fatigue    = frac(130, 230, 130),
  misc       = frac(130, 230, 230),
  focus      = frac(90, 90, 90),
  panel      = { r = 0, g = 0, b = 0, a = 0.72 },
}

--- Cream, as a last-resort colour. Anything we draw on the dark HUD must never fall back
--- to black: MyGUI's default text colour is black, and a nil colour therefore renders as
--- invisible text rather than as an error.
M.FALLBACK = { r = 223, g = 201, b = 159 }

--- Which palette entry each part of the console paints with.
M.THEMES = {
  morrowind = {
    base = M.PALETTE,
    role = {
      mode = 'header', goal = 'normal', pools = 'normal', gold = 'normalOver',
      log = 'disabled', tabActive = 'header', tabIdle = 'normal',
      row = 'normal', rowSelected = 'pressed', heading = 'header',
      footer = 'header', alert = 'negative', marker = 'header',
      panel = 'panel', scroll = 'normalOver', page = 'disabled',
      -- The narration line is cream: it is the one thing on screen while the console is
      -- hidden, so it must not rely on a role that might resolve to nothing (a nil colour
      -- rendered BLACK on a dark screen, which is how it first shipped).
      narration = 'parchment',
      -- The narration line is cream: it is the one thing on screen while the console is
      -- hidden, so it must not rely on a role that might resolve to nothing (a nil colour
      -- rendered BLACK on a dark screen, which is how it first shipped).
      narration = 'parchment',
    },
    pools = { health = 'health', magicka = 'magic', fatigue = 'fatigue' },
  },
  plain = {
    base = M.PLAIN_PALETTE,
    role = {
      mode = 'header', goal = 'normal', pools = 'normal', gold = 'normalOver',
      log = 'disabled', tabActive = 'header', tabIdle = 'normal',
      row = 'normal', rowSelected = 'pressed', heading = 'header',
      footer = 'header', alert = 'negative', marker = 'header',
      panel = 'panel', scroll = 'normalOver', page = 'disabled',
    },
    pools = { health = 'health', magicka = 'magic', fatigue = 'fatigue' },
  },
}

M.DEFAULT = 'morrowind'
M.NAMES = { 'morrowind', 'plain' }

--- Parse a Morrowind colour string "r,g,b" (0..255) into 0..1 fractions.
--- Anything unparseable returns nil, so a bad GMST never paints black.
function M.parse(text)
  if type(text) ~= 'string' then return nil end
  local r, g, b = text:match('^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$')
  if not r then return nil end
  return { r = tonumber(r) / 255, g = tonumber(g) / 255, b = tonumber(b) / 255, a = 1 }
end

--- Build a palette, preferring the live game values where they exist.
--- @param get value `function(gmstName) -> "r,g,b"|nil` — `core.getGMST`, else nil
--- @param base table the fallback palette (defaults to Morrowind's)
function M.colors(get, base)
  local out = {}
  base = base or M.PALETTE
  for name, colour in pairs(base) do out[name] = { r = colour.r, g = colour.g, b = colour.b, a = colour.a } end
  if type(get) == 'function' then
    for name, gmst in pairs(M.GMST) do
      local ok, value = pcall(get, gmst)
      if ok then
        local parsed = M.parse(value)
        if parsed then out[name] = parsed end
      end
    end
  end
  return out
end

--- Resolve a named theme to `{ palette, theme }`.
function M.load(name, get)
  if not M.THEMES[name] then name = M.DEFAULT end
  local definition = M.THEMES[name]
  return { name = name, palette = M.colors(get, definition.base), roles = definition.role, pools = definition.pools }
end

--- The colour for a role, or nil if the role is unknown.
function M.colour(theme, role)
  if not theme or not role then return nil end
  local key = theme.roles and theme.roles[role]
  if not key then return nil end
  return theme.palette and theme.palette[key] or nil
end

--- The colour for a stat pool ('health' | 'magicka' | 'fatigue').
function M.poolColour(theme, pool)
  local key = theme and theme.pools and theme.pools[pool]
  return key and theme.palette[key] or nil
end

--- The colour for a console row, by its kind and (for log rows) its level.
function M.rowColour(theme, row)
  if type(row) ~= 'table' then return M.colour(theme, 'row') end
  if row.kind == 'heading' then return M.colour(theme, 'heading') end
  if row.kind == 'log' then
    if row.level == 'bad' then return M.colour(theme, 'alert') end
    if row.level == 'warn' then return M.colour(theme, 'negative') end
    if row.level == 'good' then return M.colour(theme, 'positive') end
    return M.colour(theme, 'log')
  end
  return M.colour(theme, 'row')
end

return M
