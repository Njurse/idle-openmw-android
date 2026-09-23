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

  -- Narration strip: one wrapped line of "what the mod is doing now", centred and
  -- sitting just above the command bar, so it never covers the buttons or the gesture
  -- bar. Sized for three wrapped lines; the text element does the wrapping.
  local narrationHeight = math.floor(60 * scale)
  layout.narration = {
    width = math.min(width - margin * 2, math.floor(width * 0.80)),
    height = narrationHeight,
    y = layout.bar.y - margin - narrationHeight,
  }
  layout.narration.x = math.max(margin, math.floor((width - layout.narration.width) / 2))

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

-- ===========================================================================
-- Panel layout: the bottom-half console (tabs + list + footer + launcher)
-- ===========================================================================

M.MODES = { 'manual', 'directive', 'auto' }

--- Fraction of the screen height the console occupies, per mode.
--- Manual play gives the game as much room as possible (the built-in touch
--- controls live in the lower half), so the console shrinks there.
M.PANEL_FRACTION = {
  manual = 0.30,
  directive = 0.46,
  auto = 0.46,
}

M.TAB_HEIGHT = 34
M.ROW_HEIGHT = 22
M.FOOTER_ROWS = 2

--- When collapsed, the console shrinks to a tab strip, one list row and one
--- footer row, so the player can see almost the whole game while still being one
--- tap away from everything. This is the answer to "the console covers the lower
--- half of the screen" (docs/limitations.md section 3).
M.COLLAPSED_FRACTION = 0.16

function M.panelFraction(mode)
  return M.PANEL_FRACTION[mode] or M.PANEL_FRACTION.auto
end

--- Split the screen into the game viewport (top) and the console (bottom).
--- @param collapsed when true, use the collapsed height (see M.COLLAPSED_FRACTION)
function M.split(base, mode, collapsed)
  local minPanel, maxPanel
  if collapsed then
    minPanel = math.floor(base.height * 0.12)
    maxPanel = math.floor(base.height * 0.26)
  else
    minPanel = math.floor(base.height * 0.22)
    maxPanel = math.floor(base.height * 0.62)
  end

  local fraction = collapsed and M.COLLAPSED_FRACTION or M.panelFraction(mode)
  local panelHeight = math.floor(base.height * fraction)
  panelHeight = util.clamp(panelHeight, minPanel, maxPanel)

  local panelY = base.height - panelHeight
  -- never let the console reach up into the notch area
  if panelY < base.safeTop then
    panelY = base.safeTop
    panelHeight = base.height - panelY
  end

  return {
    viewport = { x = 0, y = 0, width = base.width, height = panelY },
    panel = { x = 0, y = panelY, width = base.width, height = panelHeight },
    collapsed = collapsed and true or false,
  }
end

--- Rectangles for the tab strip along the top of the console.
function M.tabRects(panel, tabs, scale)
  tabs = tabs or {}
  if #tabs == 0 then return {} end
  local height = math.max(M.TAB_HEIGHT, math.floor(M.TAB_HEIGHT * scale * 0.8))
  local width = math.floor(panel.width / #tabs)
  local rects = {}
  for i, tab in ipairs(tabs) do
    rects[i] = {
      id = tab.id or tab,
      label = tab.label or tostring(tab.id or tab),
      x = panel.x + (i - 1) * width,
      y = panel.y,
      width = (i == #tabs) and (panel.width - (i - 1) * width) or width,
      height = height,
    }
  end
  return rects
end

--- Rectangles for the scrollable list area and its up/down controls.
--- When `opts.showPage` is set, a thin readout strip ("rows 1-14 of 40") is
--- carved out of the TOP of the list, so the rows start below it.
function M.listRects(panel, tabsHeight, scale, opts)
  opts = opts or {}
  local rowHeight = math.max(M.ROW_HEIGHT, math.floor(M.ROW_HEIGHT * scale * 0.8))
  local footerHeight = (opts.footerRows or M.FOOTER_ROWS) * rowHeight
  local scrollWidth = math.max(30, math.floor(30 * scale * 0.9))
  local pageHeight = opts.showPage and math.max(1, math.floor(rowHeight * 0.8)) or 0

  local top = panel.y + tabsHeight
  local bottom = panel.y + panel.height - footerHeight
  local span = math.max(rowHeight, bottom - top)

  local list = {
    x = panel.x,
    y = top + pageHeight,
    width = panel.width - scrollWidth,
    height = math.max(rowHeight, span - pageHeight),
    rowHeight = rowHeight,
  }
  if pageHeight > 0 then
    list.page = { x = panel.x, y = top, width = list.width, height = pageHeight }
  end
  list.pageSize = math.max(1, math.floor(list.height / rowHeight))
  list.rows = {}
  for i = 1, list.pageSize do
    list.rows[i] = {
      x = list.x,
      y = list.y + (i - 1) * rowHeight,
      width = list.width,
      height = rowHeight,
      index = i,
    }
  end
  -- the scroll column spans the full list area (the page strip stops at list.width)
  list.up = { x = list.x + list.width, y = top, width = scrollWidth, height = math.floor(span / 2) }
  list.down = { x = list.x + list.width, y = top + math.floor(span / 2),
                width = scrollWidth, height = span - math.floor(span / 2) }
  return list
end

--- Rectangles for the footer action buttons (one row of `count` buttons,
--- wrapped across `opts.footerRows` rows).
function M.footerRects(panel, tabsHeight, scale, count, opts)
  opts = opts or {}
  count = math.max(1, count or 1)
  local rowHeight = math.max(M.ROW_HEIGHT, math.floor(M.ROW_HEIGHT * scale * 0.8))
  local rows = math.max(1, opts.footerRows or M.FOOTER_ROWS)
  local perRow = math.ceil(count / rows)
  local gap = 4
  local rects = {}
  for i = 1, count do
    local row = math.floor((i - 1) / perRow)
    local column = (i - 1) % perRow
    local width = math.floor((panel.width - gap * (perRow - 1)) / perRow)
    rects[i] = {
      x = panel.x + column * (width + gap),
      y = panel.y + panel.height - (rows - row) * rowHeight,
      width = width,
      height = rowHeight,
    }
  end
  return rects
end

--- The complete console layout for a screen, tabs, footer actions and row count.
--- Everything the renderer needs, in one place, so it is all unit-testable.
--- @param screen { x, y }
--- @param cfg    config table
--- @param model  { mode, tabs = {...}, footer = {...}, rowCount = n, footerRows?,
---                  collapsed?, showPage? }
function M.console(screen, cfg, model)
  model = model or {}
  local base = M.compute(screen, cfg)
  local split = M.split(base, model.mode, model.collapsed)

  local tabs = M.tabRects(split.panel, model.tabs or {}, base.scale)
  local tabsHeight = tabs[1] and tabs[1].height or 0
  -- a collapsed console has no room for a readout strip
  local showPage = model.showPage
  if showPage == nil then showPage = not split.collapsed end
  local list = M.listRects(split.panel, tabsHeight, base.scale,
    { footerRows = model.footerRows, showPage = showPage })
  local footer = M.footerRects(split.panel, tabsHeight, base.scale,
    #(model.footer or {}), { footerRows = model.footerRows })

  return {
    base = base,
    mode = model.mode or 'auto',
    collapsed = split.collapsed,
    screen = { width = base.width, height = base.height },
    viewport = split.viewport,
    panel = split.panel,
    showPage = showPage,
    tabs = tabs,
    tabsHeight = tabsHeight,
    list = list,
    page = list.page,
    footer = footer,
    footerIds = util.map(model.footer or {}, function(action) return action.id end),
    pageSize = list.pageSize,
  }
end

--- Named touch regions for a console layout. Used for hit-testing and for the
--- spec that asserts nothing overlaps.
function M.regions(layout)
  local regions = {}
  local function add(name, rect)
    if rect and rect.width and rect.width > 0 and rect.height and rect.height > 0 then
      regions[#regions + 1] = {
        name = name, x = rect.x, y = rect.y, width = rect.width, height = rect.height,
      }
    end
  end

  for _, tab in ipairs(layout.tabs or {}) do add('tab:' .. tab.id, tab) end
  if layout.page then add('page:readout', layout.page) end
  if layout.list then
    for _, row in ipairs(layout.list.rows or {}) do add('row:' .. row.index, row) end
    add('scroll:up', layout.list.up)
    add('scroll:down', layout.list.down)
  end
  for index, rect in ipairs(layout.footer or {}) do
    add('footer:' .. (layout.footerIds[index] or index), rect)
  end
  return regions
end

--- Which named region contains `point` (topmost / first match wins)?
function M.hitTest(regions, point)
  if not point then return nil end
  local x, y = point.x or 0, point.y or 0
  for _, region in ipairs(regions or {}) do
    if x >= region.x and x < region.x + region.width
      and y >= region.y and y < region.y + region.height then
      return region.name
    end
  end
  return nil
end

--- Screen y below which the game renders unobstructed (the console's top edge).
function M.viewportBottom(layout)
  return layout.viewport and (layout.viewport.y + layout.viewport.height) or 0
end

return M
