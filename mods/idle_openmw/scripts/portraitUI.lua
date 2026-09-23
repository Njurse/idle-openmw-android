-- scripts/portraitUI.lua
-- PLAYER script: the phone console.
--
--   .omwscripts declares:  PLAYER: scripts/portraitUI.lua
--
-- A bottom-half console over the game, built for a phone in portrait:
--
--   ┌──────────────────────────────┐
--   │ [AUTO]  tap to change        │  top strip: mode, goal, pools, gold, log
--   │ fight  (2 hostiles)          │
--   │ HP 84%  MP 60%  FT 71%  L 12%│
--   │ Gold 1,240   lvl 5  load 35/…│
--   │ 5h 03m  Sold junk for 32 g   │
--   ├──────────────────────────────┤
--   │ Info Order Pack Talk Log Open│  tab strip
--   │ > heavy cuirass  x1 300g …   │  scrollable rows
--   │   chitin dagger  x5  8g …  ▲ │
--   │   longsword      x1 90g …  ▼ │
--   ├──────────────────────────────┤
--   │ [Equip] [Sell] [Drop] [Refr] │  contextual footer
--   └──────────────────────────────┘
--
-- All geometry comes from scripts/idle/uiLayout.lua and all row/action logic
-- from scripts/idle/uiModel.lua -- both pure and unit-tested. This file is only
-- a renderer, because ui.create() cannot be verified headlessly.
--
-- Rendering strategy: elements are created ONCE per resolution and then have
-- their `layout.props.text` updated in place. OpenMW's Element:update() refreshes
-- the element's own props but not its children's layouts, so every node here is
-- a root element rather than a nested child tree.
--
-- ⚠️  Cosmetics (exact offsets, template fit) still need an on-device pass.

local engine = require('scripts.runtime.engine')
local uiLayout = require('scripts.idle.uiLayout')
local uiModel = require('scripts.idle.uiModel')
local util = require('scripts.idle.util')
local themeMod = require('scripts.idle.theme')
local narrationMod = require('scripts.idle.narration')

local ui = engine.ui()
local engines = engine.util()
local async = engine.async()
local interfaces = engine.interfaces()

local REFRESH_SECONDS = 0.5

local state = {
  built = false,
  disabled = false,
  warned = false,
  sinceRefresh = 0,
  layout = nil,
  view = nil,
  tab = 'info',
  offset = 0,
  selection = 1,
  elements = {},
  rowCount = 0,
  footerCount = 0,
  -- Collapsing is a purely presentational concern, so it lives here rather than
  -- in the director (see docs/limitations.md section 3).
  collapsed = false,
  hidden = false,
  theme = nil,
  tapToMove = true,
  -- the live narration line (scripts/idle/narration.lua); revision-guarded so the
  -- element is only touched when the text actually changes
  narration = narrationMod.new(),
}

-- ---------------------------------------------------------------------------
-- defensive engine helpers
-- ---------------------------------------------------------------------------

local function idle() return interfaces and interfaces.IdleOpenMW end

local function template(name)
  local mwui = interfaces and interfaces.MWUI
  local templates = mwui and mwui.templates
  return templates and templates[name] or nil
end

local function rgb(r, g, b)
  if engines and engines.color and engines.color.rgb then return engines.color.rgb(r, g, b) end
  return nil
end

local function vec2(x, y) return engines.vector2(x, y) end

--- A theme role (see scripts/idle/theme.lua) as an engine colour.
local function roleColour(role)
  local c = role and state.theme and themeMod.colour(state.theme, role)
  -- NEVER nil. A nil text colour becomes MyGUI's black default, so a missing theme or an
  -- unknown role renders as invisible text on a dark HUD instead of as an error. Cream is
  -- the floor, because that is what has to be readable over the game.
  if not c then c = themeMod.FALLBACK end
  return rgb(c.r, c.g, c.b)
end

--- The colour a list row wants: its kind/level, or the selection highlight.
local function rowColour(row, selected)
  local c = selected and themeMod.colour(state.theme, 'rowSelected')
  c = c or themeMod.rowColour(state.theme, row)
  if not c then return nil end
  return rgb(c.r, c.g, c.b)
end

local function setColour(element, colour)
  if not element or not colour then return end
  element.layout.props.textColor = colour
  element:update()
end

local function usable()
  if state.disabled then return false end
  return ui ~= nil and ui.create ~= nil and ui.TYPE ~= nil
    and engines ~= nil and engines.vector2 ~= nil
end

--- Colour from components, for the few places that need one inline.
local function utilColor(r, g, b, a)
  if engines and engines.util and engines.util.color then
    return engines.util.color(r / 255, g / 255, b / 255, a or 1)
  end
  return nil
end

--- Create a root element. `rect` gives both the position and the tap area.
local function createElement(opts)
  local props = {
    position = vec2(math.floor(opts.x or 0), math.floor(opts.y or 0)),
    text = opts.text or '',
    textSize = math.max(8, math.floor(opts.size or 12)),
    textColor = opts.color,
  }
  if opts.width and opts.height then
    props.size = vec2(math.floor(opts.width), math.floor(opts.height))
  end
  if opts.anchor then props.anchor = opts.anchor end
  if opts.ignorePointerEvents then props.ignorePointerEvents = true end
  -- Text properties the engine supports (components/lua_ui/text.cpp:52): text, textSize,
  -- textColor, wordWrap, textAlignH/V, multiline, autoSize, textShadow, textShadowColor.
  -- `wordWrap`+`multiline`+`autoSize=false` is what makes the narration one fixed box of
  -- wrapped lines rather than one long line running off the screen.
  if opts.wordWrap then props.wordWrap = true end
  if opts.multiline then props.multiline = true end
  if opts.autoSize ~= nil then props.autoSize = opts.autoSize end
  if opts.textAlignH ~= nil then props.textAlignH = opts.textAlignH end
  if opts.textAlignV ~= nil then props.textAlignV = opts.textAlignV end
  if opts.textShadow then
    props.textShadow = true
    props.textShadowColor = opts.textShadowColor or utilColor(0, 0, 0, 0.85)
  end

  local layout = { layer = 'HUD', props = props }
  local t = opts.template and template(opts.template)
  if t then layout.template = t else layout.type = opts.type or ui.TYPE.Text end
  -- `async:callback` is a METHOD -- the engine's own scripts call `async:callback`
  -- (e.g. vfs-mw/scripts/omw/settings/renderers.lua:88 wires mouseClick that way).
  -- Calling it with a DOT passes the function where the package id belongs and throws
  -- "expected userdata, received function", which silently disabled the whole console.
  if opts.onTap and async and type(async.callback) == 'function' then
    layout.events = { mouseClick = async:callback(opts.onTap) }
  end
  -- `mouseRelease` is the event that carries a POSITION (mouseClick gives none;
  -- components/lua_ui/widget.cpp:546 vs :566). Tap-to-move needs the coordinate.
  if opts.onRelease and async and type(async.callback) == 'function' then
    layout.events = layout.events or {}
    layout.events.mouseRelease = async:callback(opts.onRelease)
  end
  -- our rect props deliberately override template defaults; silence the warnings
  return ui.create(layout, { noWarnUnused = true })
end

local function setText(element, text)
  if not element then return end
  element.layout.props.text = text or ''
  element:update()
end

-- ---------------------------------------------------------------------------
-- taps
-- ---------------------------------------------------------------------------

local function refreshNow() state.sinceRefresh = REFRESH_SECONDS end

--- Destroy every element the console owns. A rebuild MUST go through this, or the
--- old widgets stay on screen and the touch regions go stale (which is exactly
--- how the collapse toggle leaked its elements the first time).
local function destroyElements()
  local function destroyAll(list)
    for _, element in pairs(list or {}) do
      if element and not element.destroyed and element.destroy then element:destroy() end
    end
  end
  destroyAll(state.elements.top)
  destroyAll(state.elements.tabs)
  destroyAll(state.elements.rows)
  destroyAll(state.elements.footer)
  if state.elements.page then destroyAll({ state.elements.page }) end
  if state.elements.scrollUp then destroyAll({ state.elements.scrollUp }) end
  if state.elements.scrollDown then destroyAll({ state.elements.scrollDown }) end
  if state.elements.panel then destroyAll({ state.elements.panel }) end
  if state.elements.status then destroyAll({ state.elements.status }) end
  if state.elements.tap then destroyAll({ state.elements.tap }) end
end

--- Drop the current widgets so the next update rebuilds from scratch.
local function requestRebuild()
  destroyElements()
  state.elements = {}
  state.built = false
end

local function onTabTap(tabId)
  state.tab = tabId
  state.offset = 0
  state.selection = 1
  refreshNow()
end

local function onScroll(delta)
  local view = state.view
  if not view then return end
  state.offset = uiModel.scroll(state.offset, delta, #view.rows, state.layout.pageSize)
  refreshNow()
end

local function onRowTap(index)
  local view = state.view
  if not view then return end
  local row = view.visible.rows[index]
  if not row then return end

  local absolute = view.offset + index
  state.selection = absolute

  local api = idle()
  if not api then return end

  if row.action == 'order' and row.payload then
    -- one tap = order it, the whole point of the console
    local ok, entry = pcall(api.act, 'order', row.payload)
    if ok and not entry and api.log then
      pcall(api.log, ('Cannot order %s'):format(tostring(row.payload.id)), 'warn')
    end
  elseif row.action == 'launch' and row.payload then
    pcall(api.act, 'launch', row.payload)
  end
  -- 'select' rows just move the selection; the footer acts on it
  refreshNow()
end

local function onFooterTap(index)
  local view = state.view
  if not view then return end
  local button = view.footer[index]
  if not button then return end

  -- collapsing the console is UI-local: flip it and rebuild the geometry
  if button.id == 'toggle_panel' then
    state.collapsed = not state.collapsed
    requestRebuild()
    refreshNow()
    return
  end

  local api = idle()
  if not api then return end

  local payload = nil
  if uiModel.REQUIRES_SELECTION[button.id] then
    local selected = view.selected
    if not selected or not selected.payload or not selected.payload.id then
      if api.log then pcall(api.log, 'Select an item in the Pack tab first', 'warn') end
      return
    end
    payload = { id = selected.payload.id, count = selected.payload.count }
  end

  pcall(api.act, button.id, payload)
  refreshNow()
end

local function onModeTap()
  local api = idle()
  if api then pcall(api.act, 'cycle_mode') end
  refreshNow()
end

-- ---------------------------------------------------------------------------
-- build (once per resolution)
-- ---------------------------------------------------------------------------

--- The world was tapped: hand the screen point to the runtime, which raycasts
--- and decides (docs/tap-to-move.md). The renderer deliberately does no engine
--- maths -- mouseRelease gives an absolute pixel position
--- (components/lua_ui/widget.cpp:566).
local function onGameTap(event)
  local api = idle()
  if not (api and type(api.act) == 'function') then return end
  local position = event and event.position
  if type(position) ~= 'table' then return end
  pcall(api.act, 'walk_to', { x = position.x, y = position.y })
end

local function build()
  local api = idle()

  -- NB: `select(1, pcall(f))` yields BOTH the pcall status and the value, so an
  -- `and` chain around it silently produces `true`. Unpack explicitly instead.
  local cfg = nil
  if api and type(api.getConfig) == 'function' then
    local ok, value = pcall(api.getConfig)
    if ok then cfg = value end
  end
  local startMode = 'auto'
  if api and type(api.mode) == 'function' then
    local ok, value = pcall(api.mode)
    if ok and value then startMode = value end
  end

  -- The palette. Prefer the game's *live* Morrowind colours via core.getGMST;
  -- fall back to the shipped ones (scripts/idle/theme.lua).
  local core = engine.core()
  local getGmst = nil
  if core and type(core.getGMST) == 'function' then
    getGmst = function(name)
      local ok, value = pcall(core.getGMST, name)
      if ok then return value end
    end
  end
  state.theme = themeMod.load(cfg and cfg.ui and cfg.ui.theme, getGmst)

  local screen = nil
  if ui.screenSize then
    local ok, size = pcall(ui.screenSize)
    if ok then screen = size end
  end

  local tabs = uiModel.TABS
  local footer = uiModel.footerFor(state.tab, { collapsed = state.collapsed })
  local layout = uiLayout.console(screen, cfg, {
    mode = startMode,
    tabs = tabs,
    footer = footer,
    footerRows = 2,
    collapsed = state.collapsed,
  })
  state.layout = layout
  state.elements = {}

  local scale = layout.base.scale
  local textScale = layout.base.textScale

  -- --- tap-to-move layer (full screen, UNDER everything) ---
  -- A tap on the world walks you there / enters the door / talks to the NPC. It
  -- must be created FIRST so the console's own widgets (created below) sit on top
  -- of it and keep their own taps. Ignored by pointer events in MANUAL mode so the
  -- game's own controls stay usable (see render()).
  state.tapToMove = not (cfg and cfg.ui and cfg.ui.tapToMove == false)
  state.elements.tap = createElement({
    x = 0, y = 0, width = layout.screen.width, height = layout.screen.height,
    size = 10, type = ui.TYPE.Widget,
    ignorePointerEvents = not state.tapToMove,
    onRelease = onGameTap,
  })

  -- --- status bar background ---
  -- uiLayout gives us `layout.status` (top of the screen, under the notch) but
  -- the strip text was drawn straight onto the game: tan Morrowind text over
  -- bright terrain is unreadable. Fill the rect the layout already reserved.
  state.elements.status = createElement({
    x = layout.base.status.x, y = layout.base.status.y,
    width = layout.base.status.width, height = layout.base.status.height,
    size = 10, type = ui.TYPE.Window, template = 'boxTransparentThick',
    onTap = function() end, -- swallow taps so they do not reach the game
  })

  -- --- top strip (four text rows + a mode button) ---
  local stripHeight = math.floor(20 * scale)
  local strip = {
    -- Sizes raised ~12% over the original 15/13/12/12/11 after seeing them rendered:
    -- the small rows were too small to read comfortably at a glance on a real screen,
    -- which defeats the point of a status console. `ui.textScale` remains the knob.
    { key = 'mode', size = 17 * textScale, role = 'mode', template = 'textHeader' },
    { key = 'goal', size = 15 * textScale, role = 'goal', template = 'textNormal' },
    { key = 'pools', size = 13 * textScale, role = 'pools', template = 'textNormal' },
    { key = 'gold', size = 13 * textScale, role = 'gold', template = 'textNormal' },
    { key = 'log', size = 12 * textScale, role = 'log', template = 'textNormal' },
  }
  state.elements.top = {}
  for index, row in ipairs(strip) do
    state.elements.top[row.key] = createElement({
      x = layout.base.margin, y = layout.base.safeTop + (index - 1) * stripHeight,
      width = layout.screen.width - layout.base.margin * 2, height = stripHeight,
      size = row.size, color = roleColour(row.role), template = row.template,
      onTap = row.key == 'mode' and onModeTap or nil,
    })
  end

  -- --- panel background ---
  state.elements.panel = createElement({
    x = layout.panel.x, y = layout.panel.y,
    width = layout.panel.width, height = layout.panel.height,
    size = 10, type = ui.TYPE.Window, template = 'boxTransparentThick',
    onTap = function() end, -- swallow taps so they do not reach the game
  })

  -- --- tabs ---
  state.elements.tabs = {}
  for _, tab in ipairs(layout.tabs) do
    local tabId = tab.id
    state.elements.tabs[tabId] = createElement({
      x = tab.x, y = tab.y, width = tab.width, height = tab.height,
      text = tab.label, size = 13 * textScale, color = roleColour('tabIdle'),
      template = 'textNormal',
      onTap = function() onTabTap(tabId) end,
    })
  end

  -- --- list rows (page size fixed by the geometry) ---
  state.rowCount = layout.pageSize
  state.elements.rows = {}
  for index = 1, layout.pageSize do
    local rect = layout.list.rows[index]
    state.elements.rows[index] = createElement({
      x = rect.x + math.floor(4 * scale), y = rect.y,
      width = rect.width - math.floor(8 * scale), height = rect.height,
      size = 11 * textScale, color = roleColour('row'), template = 'textNormal',
      onTap = function() onRowTap(index) end,
    })
  end

  -- --- scroll buttons ---
  state.elements.scrollUp = createElement({
    x = layout.list.up.x, y = layout.list.up.y,
    width = layout.list.up.width, height = layout.list.up.height,
    text = '^', size = 14 * textScale, color = roleColour('scroll'), template = 'textNormal',
    onTap = function() onScroll(-3) end,
  })
  state.elements.scrollDown = createElement({
    x = layout.list.down.x, y = layout.list.down.y,
    width = layout.list.down.width, height = layout.list.down.height,
    text = 'v', size = 14 * textScale, color = roleColour('scroll'), template = 'textNormal',
    onTap = function() onScroll(3) end,
  })

  -- --- page readout ("rows 1-14 of 40"), absent when collapsed ---
  state.elements.page = nil
  if layout.page then
    state.elements.page = createElement({
      x = layout.page.x + math.floor(6 * scale), y = layout.page.y,
      width = layout.page.width - math.floor(12 * scale), height = layout.page.height,
      text = '', size = 10 * textScale, color = roleColour('page'), template = 'textNormal',
    })
  end

  -- --- footer buttons ---
  state.footerCount = #layout.footer
  state.elements.footer = {}
  for index, rect in ipairs(layout.footer) do
    state.elements.footer[index] = createElement({
      x = rect.x + 2, y = rect.y, width = rect.width - 4, height = rect.height,
      text = '', size = 12 * textScale, color = roleColour('footer'), template = 'textHeader',
      onTap = function() onFooterTap(index) end,
    })
  end

  state.built = true
end

-- ---------------------------------------------------------------------------
-- render
-- ---------------------------------------------------------------------------

local function render()
  local api = idle()
  local panelData = nil
  if api and type(api.panel) == 'function' then
    local ok, value = pcall(api.panel)
    if ok then panelData = value end
  end

  local view = uiModel.view(state, panelData, state.layout)
  state.view = view

  local percent = function(fraction) return math.floor((fraction or 0) * 100 + 0.5) .. '%' end
  local status = (panelData and panelData.status) or {}

  -- top strip
  setText(state.elements.top.mode,
    ('[%s]  %s   (tap to change)'):format(uiModel.modeLabel(view.mode),
      uiModel.MODE_HINT[view.mode] or ''))
  setText(state.elements.top.goal, ('%s%s%s'):format(
    tostring(status.goal or 'idle'),
    status.reason and ('  (' .. status.reason .. ')') or '',
    view.directive and ('   ORDER: ' .. view.directive) or ''))
  setText(state.elements.top.pools, ('HP %s  MP %s  FT %s  LOAD %s'):format(
    percent(status.healthFraction), percent(status.magickaFraction),
    percent(status.fatigueFraction), percent(status.encumbranceFraction)))
  local player = (panelData and panelData.player) or {}
  local load = player.encumbrance
  setText(state.elements.top.gold, ('Gold %s   lvl %s%s'):format(
    util.formatNumber(player.gold or status.gold or 0),
    tostring(player.level or status.level or '?'),
    load and ('   load %d/%d'):format(load.current or 0, load.max or 0) or ''))

  local log = (panelData and panelData.log) or {}
  local lastLog = log[#log]
  setText(state.elements.top.log, lastLog
    and (('%s  %s'):format(require('scripts.idle.activityLog').formatTime(lastLog.time or 0),
      tostring(lastLog.message)))
    or 'starting up…')

  -- tabs (highlight the active one, in the theme's colours)
  for _, tab in ipairs(view.tabs) do
    local element = state.elements.tabs[tab.id]
    local active = (tab.id == view.tab)
    setText(element, (active and '[' .. tab.label .. ']' or tab.label))
    setColour(element, roleColour(active and 'tabActive' or 'tabIdle'))
  end

  -- rows
  for index = 1, state.rowCount do
    local element = state.elements.rows[index]
    local row = view.visible.rows[index]
    if not row then
      setText(element, '')
    else
      local absolute = view.offset + index
      local marker = (absolute == view.selection) and '>' or ' '
      setText(element, marker .. ' ' .. uiModel.formatRow(row))
      -- colour by kind/level, with the selection picked out (scripts/idle/theme.lua)
      setColour(element, rowColour(row, absolute == view.selection))
    end
  end

  -- scroll affordances: the glyphs stay put (they are the tap targets); the
  -- clamped scroll position is what actually limits them
  setText(state.elements.scrollUp, '^')
  setText(state.elements.scrollDown, 'v')

  -- footer
  for index = 1, state.footerCount do
    local button = view.footer[index]
    setText(state.elements.footer[index], button and button.label or '')
  end

  -- page readout (absent while collapsed)
  if state.elements.page and state.layout then
    setText(state.elements.page, uiModel.pageText({
      total = view.total,
      offset = view.offset,
      pageSize = state.layout.pageSize,
    }))
  end

  -- Tap-to-move: the full-screen layer must NOT swallow input when the human is
  -- driving (MANUAL) or when the option is off -- otherwise the game's own touch
  -- controls never see the tap (docs/tap-to-move.md).
  if state.elements.tap then
    local ignoring = not (state.tapToMove and view.mode ~= 'manual')
    if state.elements.tap.layout.props.ignorePointerEvents ~= ignoring then
      state.elements.tap.layout.props.ignorePointerEvents = ignoring
      state.elements.tap:update()
    end
  end
end

-- ---------------------------------------------------------------------------
-- handlers
-- ---------------------------------------------------------------------------

--- Should the console be on screen right now?
-- ---------------------------------------------------------------------------
-- narration -- shown even when the console is hidden
-- ---------------------------------------------------------------------------

--- Draw (or refresh) the narration line.
---
--- Unlike the console, this is deliberately ALWAYS visible. The console hides during
--- character creation because the engine is asking the player questions; the narration
--- does the opposite, because that is exactly when someone watching needs to know the
--- mod is holding back on purpose rather than stuck. It is also the only way to talk to
--- a person watching a run: write `narration.txt` in the data folder and it appears here
--- (scripts/runtime/engine.lua readTextFile -> scripts/idle/narration.lua choose).
local function updateNarration()
  local api = idle()
  if not api or type(api.narration) ~= 'function' then return end
  local okText, text = pcall(api.narration)
  if not okText then return end

  local changed = state.narration:set(text)

  if not state.narrationElement then
    -- compute the base layout just for the narration rect: build() owns its own layout
    -- and only runs in the world, but narration must exist before that.
    local screen = nil
    if ui.screenSize then
      local okSize, size = pcall(ui.screenSize)
      if okSize then screen = size end
    end
    local cfg = {}
    if api.getConfig then
      local okCfg, value = pcall(api.getConfig)
      if okCfg and util.isObject(value) then cfg = value end
    end
    -- The theme is normally loaded in build(), which only runs in the world -- but the
    -- narration exists during character creation, so load it here if it is not up yet.
    -- Without this, roleColour had nothing to resolve and the text came out black.
    if not state.theme then
      -- same construction build() uses: adopt the game's own GMST colours when readable
      local core = engine.core()
      local getGmst = nil
      if core and type(core.getGMST) == 'function' then
        getGmst = function(name)
          local okGmst, value = pcall(core.getGMST, name)
          if okGmst then return value end
        end
      end
      state.theme = themeMod.load(cfg and cfg.ui and cfg.ui.theme, getGmst)
    end
    local base = uiLayout.compute(screen, cfg)
    local rect = base.narration
    state.narrationElement = createElement({
      x = rect.x, y = rect.y, width = rect.width, height = rect.height,
      text = state.narration:get(),
      -- a touch larger than the consoles body text: this is meant to be read at a glance
      size = 16 * base.textScale,
      color = roleColour('narration'),
      wordWrap = true, multiline = true, autoSize = false,
      textAlignH = ui.ALIGNMENT and ui.ALIGNMENT.Center or nil,
      textAlignV = ui.ALIGNMENT and ui.ALIGNMENT.Start or nil,
      textShadow = true,
      ignorePointerEvents = true,
    })
    if state.narrationElement then setText(state.narrationElement, state.narration:get()) end
    return
  end

  if changed then
    setText(state.narrationElement, state.narration:get())
  end
end

--- It is a game HUD, so it stays hidden until the character is free in the
--- world -- never over the character-creation windows (scripts/idle/lifecycle.lua).
--- A mod build without the `phase` interface keeps the old always-visible
--- behaviour rather than guessing.
local function consoleWanted()
  local api = idle()
  if not api or type(api.phase) ~= 'function' then return true end
  local ok, phase = pcall(api.phase)
  if not ok then return true end
  return phase == nil or phase == 'world'
end

local function update(dt)
  if state.disabled then return end
  if not usable() then state.disabled = true return end

  local ok, err = pcall(function()
    -- Narration first, and BEFORE the console gate below: it must be up during
    -- character creation, which is exactly where the console is hidden.
    updateNarration()

    -- The console is a *game* HUD. During character creation (and the menu / a
    -- load screen) the engine is asking the player questions and the console
    -- must not cover them -- so it hides until the character is free in the
    -- world (scripts/idle/lifecycle.lua). Skipping the build also means no
    -- elements exist to interact with, which is exactly right there.
    if not consoleWanted() then
      if not state.hidden then
        destroyElements()
        state.elements = {}
        state.rowCount = 0
        state.footerCount = 0
        state.built = false
        state.hidden = true
      end
      return
    end
    if state.hidden then
      state.hidden = false
      state.built = false -- force a fresh build now that we are in the world
    end

    if not state.built then build() end
    state.sinceRefresh = state.sinceRefresh + (dt or 0)
    if state.sinceRefresh >= REFRESH_SECONDS then
      state.sinceRefresh = 0
      render()
    end
  end)

  if not ok then
    state.disabled = true
    if not state.warned then
      state.warned = true
      print('[IdleOpenMW] console disabled: ' .. tostring(err))
    end
  end
end

--- Rebuild on resize/rotation: the layout is resolution-derived.
---
--- The handler is `onViewportResized(width, height)`, NOT `onResolutionChanged` --
--- that name does not exist in the engine at all
--- (docs/source/reference/lua-scripting/engine_handlers.rst; registered in
--- mwlua/playerscripts.hpp:56). Declaring a handler the engine does not know is not
--- fatal, but it logs "Not supported handler ..." and then never fires, so the
--- console would keep the stale layout after a rotation on a phone.
local function onViewportResized()
  if state.disabled then return end
  pcall(requestRebuild)
end

return {
  engineHandlers = {
    onUpdate = update,
    onViewportResized = onViewportResized,
  },
}
