-- scripts/idle/uiLayout.lua
-- Phone-first layout geometry for the HUD.
--
-- All of the fiddly arithmetic lives here, PURE, so it can be tested headlessly;
-- portraitUI.lua only turns the resulting rectangles into widgets. That is the
-- only sane way to work on a touch layout you cannot see.
--
-- Conventions
--   * coordinates are OpenMW UI units, origin top-left (as ui.screenSize() uses)
--   * the status panel hugs the safe TOP inset (notch / punch-hole camera)
--   * the command bar sits on the safe BOTTOM inset (gesture bar), and extra
--     button rows stack UPWARD from it rather than being clipped off-screen
--
-- Pure: no engine, no I/O.

local util = require('scripts.idle.util')

local M = {}

--- The design reference the scale factor is derived from.
M.REFERENCE_HEIGHT = 1200
M.MIN_SCALE = 1.0
M.MAX_SCALE = 2.4

--- Minimum sane touch target (UI units at scale 1). Android's guidance is
--- ~48dp; we use a roomier 56 to suit a one-handed idle game.
M.TOUCH_TARGET = 56
M.MIN_BUTTON_WIDTH = 118
M.BUTTON_GAP = 8
M.EDGE_MARGIN = 12

--- The command bar's buttons, in tap-priority order.
--- `toggle` and `cancel` are handled by the HUD itself; the rest are directives.
function M.defaultButtons()
  return {
    { id = 'toggle', label = 'AUTO' },
    { id = 'shop', label = 'Shop' },
    { id = 'sell_junk', label = 'Sell junk' },
    { id = 'rest', label = 'Rest' },
    { id = 'train', label = 'Train' },
    { id = 'heal', label = 'Heal' },
    { id = 'explore', label = 'Explore' },
    { id = 'cancel', label = 'Cancel' },
  }
end

--- Human label for the auto-play toggle, which flips with state.
function M.toggleLabel(autoPlaying)
  return autoPlaying and 'AUTO' or 'PAUSED'
end

--- Compute the whole layout for a screen.
--- @param screen { x = width, y = height } — pass ui.screenSize() verbatim
--- @param cfg    config table (uses cfg.ui.*)
function M.compute(screen, cfg)
  cfg = cfg or {}
  local uiCfg = cfg.ui or {}

  local width = math.max(1, math.floor((screen and screen.x) or 720))
  local height = math.max(1, math.floor((screen and screen.y) or 1280))

  -- Bigger screens get proportionally bigger chrome, but never smaller than 1x.
  local scale = util.clamp(height / M.REFERENCE_HEIGHT, M.MIN_SCALE, M.MAX_SCALE)

  local margin = math.floor(M.EDGE_MARGIN * scale)
  -- Safe areas: the larger of the configured inset and a fraction of the screen.
  local safeTop = math.max(math.ceil((uiCfg.topInset or 0) * scale), math.ceil(height * 0.030))
  local safeBottom = math.max(math.ceil((uiCfg.bottomInset or 0) * scale), math.ceil(height * 0.055))

  local touchHeight = math.max(M.TOUCH_TARGET, math.floor(44 * scale))

  local layout = {
    width = width,
    height = height,
    scale = scale,
    margin = margin,
    safeTop = safeTop,
    safeBottom = safeBottom,
    touchHeight = touchHeight,
    textScale = (uiCfg.textScale or 1) * scale,
  }

  -- Status panel (top of the screen, under the notch).
  layout.status = {
    x = margin,
    y = safeTop,
    width = width - margin * 2,
    height = math.floor(104 * scale),
  }

  -- Command bar (above the gesture bar).
  layout.bar = {
    x = margin,
    y = height - safeBottom - touchHeight,
    width = width - margin * 2,
    height = touchHeight,
  }

  -- The strip that must stay free of game rendering.
  layout.viewport = {
    top = safeTop + layout.status.height,
    bottom = layout.bar.y - margin,
  }

  return layout
end

--- Split `buttons` into rows that fit `bar.width`, and give each button its
--- rectangle. Extra rows stack upward from the bar.
--- @return rows (list of list of button-with-geometry), perRow
function M.buttonRows(buttons, bar, scale)
  buttons = buttons or {}
  scale = scale or 1
  local minWidth = M.MIN_BUTTON_WIDTH * math.max(1, scale * 0.85)
  local gap = M.BUTTON_GAP
  local perRow = math.max(1, math.floor((bar.width + gap) / (minWidth + gap)))

  local rows = {}
  for index, button in ipairs(buttons) do
    local rowIndex = math.floor((index - 1) / perRow) + 1
    rows[rowIndex] = rows[rowIndex] or {}
    rows[rowIndex][#rows[rowIndex] + 1] = button
  end

  for rowIndex, row in ipairs(rows) do
    local count = #row
    local width = math.floor((bar.width - gap * (count - 1)) / count)
    for i, button in ipairs(row) do
      button.x = bar.x + (i - 1) * (width + gap)
      button.y = bar.y - (rowIndex - 1) * (bar.height + gap)
      button.width = width
      button.height = bar.height
    end
  end

  return rows, perRow
end

--- How many rows the bar needs for the given buttons.
function M.rowCount(buttons, bar, scale)
  local rows = M.buttonRows(util.deepCopy(buttons), bar, scale)
  return #rows
end

--- The bottom-most y the button stack reaches (used to keep it clear of the
--- status panel on very short screens).
function M.stackTop(buttons, bar, scale)
  local rows = M.buttonRows(util.deepCopy(buttons), bar, scale)
  local top = bar.y
  for rowIndex = 1, #rows do
    top = math.min(top, bar.y - (rowIndex - 1) * (bar.height + M.BUTTON_GAP))
  end
  return top
end

return M
