-- tools/preview/console_mock.lua
-- Build a *description* of the phone console from the REAL pure modules, so it
-- can be drawn outside the game.
--
-- Why this exists: `ui.create()` cannot be verified headlessly and the pixels
-- only exist on a device, but the three things that decide what you see are all
-- pure Lua --
--   scripts/idle/uiLayout.lua (geometry)
--   scripts/idle/uiModel.lua  (tabs, rows, footers, text)
--   scripts/idle/theme.lua    (colours)
-- -- so an accurate mock is possible. `tools/preview_console.py` turns this into
-- an HTML page.
--
-- It is a mock, NOT a screenshot: the game art behind it is a flat placeholder,
-- and the font is a serif stand-in for Morrowind's MysticCards (Lua cannot pick
-- a family -- see docs/theme.md).
--
-- Returns: { screen = {w,h}, elements = { {kind, x, y, w, h, text?, size?, colour?}, ... } }

local uiLayout = require('scripts.idle.uiLayout')
local uiModel = require('scripts.idle.uiModel')
local themeMod = require('scripts.idle.theme')
local configMod = require('scripts.idle.config')
local panels = require('tests.fixtures.panel')

local M = {}

local function percent(f) return math.floor((f or 0) * 100 + 0.5) .. '%' end

--- @param screenW number
--- @param screenH number
--- @param opts? { tab?, theme?, collapsed?, panel?, mode? }
function M.build(screenW, screenH, opts)
  opts = opts or {}
  local screen = { x = screenW, y = screenH }
  local cfg = configMod.new({ ui = { theme = opts.theme or 'morrowind' } })
  local theme = themeMod.load(opts.theme, nil)
  local tab = opts.tab or 'info'
  local collapsed = opts.collapsed == true
  local mode = opts.mode or 'auto'
  local panel = opts.panel or panels.panel({ mode = mode })

  local tabs = uiModel.TABS
  local footer = uiModel.footerFor(tab, { collapsed = collapsed })
  local layout = uiLayout.console(screen, cfg, {
    mode = mode, tabs = tabs, footer = footer, footerRows = 2, collapsed = collapsed,
  })
  local view = uiModel.view({ tab = tab, offset = 0, selection = 1, collapsed = collapsed }, panel, layout)

  local scale = layout.base.scale
  local textScale = layout.base.textScale
  local elements = {}

  local function role(r) return themeMod.colour(theme, r) end

  -- --- panel background ---
  elements[#elements + 1] = {
    kind = 'panel', x = layout.panel.x, y = layout.panel.y,
    w = layout.panel.width, h = layout.panel.height,
    colour = role('panel'),
  }

  -- --- status bar background ---
  elements[#elements + 1] = {
    kind = 'panel', x = layout.base.status.x, y = layout.base.status.y,
    w = layout.base.status.width, h = layout.base.status.height,
    colour = role('panel'),
  }

  -- --- top strip (mirrors portraitUI.render) ---
  local status = panel.status or {}
  local player = panel.player or {}
  local log = panel.log or {}
  local lastLog = log[#log]
  local stripHeight = math.floor(20 * scale)
  local strip = {
    { key = 'mode', size = 15 * textScale, role = 'mode',
      text = ('[%s]  %s   (tap to change)'):format(uiModel.modeLabel(view.mode),
        uiModel.MODE_HINT[view.mode] or '') },
    { key = 'goal', size = 13 * textScale, role = 'goal',
      text = ('%s%s%s'):format(tostring(status.goal or 'idle'),
        status.reason and ('  (' .. status.reason .. ')') or '',
        view.directive and ('   ORDER: ' .. view.directive) or '') },
    { key = 'pools', size = 12 * textScale, role = 'pools',
      text = ('HP %s  MP %s  FT %s  LOAD %s'):format(percent(status.healthFraction),
        percent(status.magickaFraction), percent(status.fatigueFraction),
        percent(status.encumbranceFraction)) },
    { key = 'gold', size = 12 * textScale, role = 'gold',
      text = ('Gold %s   lvl %s%s'):format(tostring(player.gold or 0),
        tostring(player.level or '?'),
        player.encumbrance and ('   load %d/%d'):format(player.encumbrance.current or 0,
          player.encumbrance.max or 0) or '') },
    { key = 'log', size = 11 * textScale, role = 'log',
      text = lastLog and (('%s  %s'):format('5h', tostring(lastLog.message))) or 'starting up…' },
  }
  for index, row in ipairs(strip) do
    elements[#elements + 1] = {
      kind = 'text', text = row.text, size = row.size, colour = role(row.role),
      x = layout.base.margin, y = layout.base.safeTop + (index - 1) * stripHeight,
      w = screenW - layout.base.margin * 2, h = stripHeight,
    }
  end

  -- --- tabs ---
  for _, t in ipairs(layout.tabs) do
    local active = (t.id == view.tab)
    elements[#elements + 1] = {
      kind = 'text', text = active and ('[' .. t.label .. ']') or t.label,
      size = 12 * textScale, colour = role(active and 'tabActive' or 'tabIdle'),
      x = t.x, y = t.y, w = t.width, h = t.height,
    }
  end

  -- --- rows ---
  for index = 1, layout.pageSize do
    local rect = layout.list.rows[index]
    local row = view.visible.rows[index]
    local text = ''
    local colour = nil
    if row then
      local absolute = view.offset + index
      local marker = (absolute == view.selection) and '>' or ' '
      text = marker .. ' ' .. uiModel.formatRow(row)
      local c = (absolute == view.selection) and themeMod.colour(theme, 'rowSelected')
        or themeMod.rowColour(theme, row)
      colour = c
    end
    elements[#elements + 1] = {
      kind = 'text', text = text, size = 11 * textScale, colour = colour,
      x = rect.x + math.floor(4 * scale), y = rect.y,
      w = rect.width - math.floor(8 * scale), h = rect.height,
    }
  end

  -- --- scroll affordances ---
  elements[#elements + 1] = { kind = 'text', text = '^', size = 14 * textScale,
    colour = role('scroll'), x = layout.list.up.x, y = layout.list.up.y,
    w = layout.list.up.width, h = layout.list.up.height }
  elements[#elements + 1] = { kind = 'text', text = 'v', size = 14 * textScale,
    colour = role('scroll'), x = layout.list.down.x, y = layout.list.down.y,
    w = layout.list.down.width, h = layout.list.down.height }

  -- --- page readout ---
  if layout.page then
    elements[#elements + 1] = {
      kind = 'text', text = uiModel.pageText({
        total = view.total, offset = view.offset, pageSize = layout.pageSize }),
      size = 10 * textScale, colour = role('page'),
      x = layout.page.x + math.floor(6 * scale), y = layout.page.y,
      w = layout.page.width - math.floor(12 * scale), h = layout.page.height,
    }
  end

  -- --- footer ---
  for index, rect in ipairs(layout.footer) do
    local button = view.footer[index]
    elements[#elements + 1] = {
      kind = 'text', text = button and button.label or '',
      size = 12 * textScale, colour = role('footer'),
      x = rect.x + 2, y = rect.y, w = rect.width - 4, h = rect.height,
    }
  end

  return { screen = screen, elements = elements }
end

return M
