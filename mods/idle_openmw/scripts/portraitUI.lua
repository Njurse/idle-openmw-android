-- scripts/portraitUI.lua
-- PLAYER script: the portrait status HUD + touch command bar.
--
--   .omwscripts declares:  PLAYER: scripts/portraitUI.lua
--
-- Built for a phone in portrait (Galaxy S23+, 1080x2340):
--   * all geometry comes from scripts/idle/uiLayout.lua, which is pure and
--     unit-tested -- the notch and gesture bar never cover the game HUD,
--   * the bottom command bar uses real touch targets (>=56 UI units) and its
--     buttons carry `mouseClick` handlers on interactive HUD-layer widgets,
--   * extra button rows stack UPWARD so nothing is pushed off-screen,
--   * Morrowind-native look via the MWUI templates when that interface exists.
--
-- ⚠️  The widget creation itself (ui.create / Element:update) is engine-side and
-- CANNOT be verified headlessly. Everything is pcall-guarded and latches off
-- after one failure, so a UI problem can never take the director down. Expect to
-- nudge the cosmetic offsets on-device; the geometry is already tested.

local engine = require('scripts.runtime.engine')
local uiLayout = require('scripts.idle.uiLayout')
local activityLog = require('scripts.idle.activityLog')
local util = require('scripts.idle.util')

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
  status = {},
  buttons = {},
  backgrounds = {},
  buttonList = nil,
  cfg = nil,
}

-- ---------------------------------------------------------------------------
-- small helpers (all defensive)
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

local function usable()
  if state.disabled then return false end
  if not (ui and ui.create and ui.TYPE and engines and engines.vector2) then return false end
  return true
end

--- Create a text element. Uses an MWUI template when available, else a bare Text.
local function createText(x, y, text, size, colour, templateName, extra)
  local props = {
    position = vec2(math.floor(x), math.floor(y)),
    text = text,
    textSize = math.max(8, math.floor(size)),
    textColor = colour,
  }
  for key, value in pairs(extra or {}) do props[key] = value end

  local t = templateName and template(templateName)
  if t then
    return ui.create { layer = 'HUD', template = t, props = props }
  end
  return ui.create { layer = 'HUD', type = ui.TYPE.Text, props = props }
end

--- Create a tappable background rectangle carrying the click handler.
local function createButtonFace(rect, callback)
  local props = {
    position = vec2(rect.x, rect.y),
    size = vec2(rect.width, rect.height),
  }
  local events = nil
  if callback and async and type(async.callback) == 'function' then
    events = { mouseClick = async.callback(callback) }
  end

  local t = template('boxTransparentThick')
  if t then
    return ui.create { layer = 'HUD', template = t, props = props, events = events }
  end
  return ui.create { layer = 'HUD', type = ui.TYPE.Window, props = props, events = events }
end

-- ---------------------------------------------------------------------------
-- commands
-- ---------------------------------------------------------------------------

local function onButton(id)
  local api = idle()
  if not api then return end

  if id == 'toggle' then
    if type(api.toggleAutoPlay) == 'function' then pcall(api.toggleAutoPlay) end
  elseif id == 'cancel' then
    if type(api.clearDirectives) == 'function' then pcall(api.clearDirectives) end
    if type(api.log) == 'function' then pcall(api.log, 'Directive cancelled', 'warn') end
  else
    if type(api.pushDirective) == 'function' then
      local ok, entry = pcall(api.pushDirective, id)
      if ok and not entry and type(api.log) == 'function' then
        pcall(api.log, ('No such directive: %s'):format(id), 'warn')
      end
    end
  end
  state.sinceRefresh = REFRESH_SECONDS -- refresh immediately after a tap
end

-- ---------------------------------------------------------------------------
-- build
-- ---------------------------------------------------------------------------

local function build()
  local api = idle()
  local cfg = (api and type(api.getConfig) == 'function') and (select(1, pcall(api.getConfig))) or nil
  state.cfg = cfg

  local screen = nil
  if ui.screenSize then
    local ok, size = pcall(ui.screenSize)
    if ok then screen = size end
  end

  local layout = uiLayout.compute(screen, cfg)
  state.layout = layout

  -- status panel: one text row per line, stacked under the notch
  local rowHeight = math.floor(20 * layout.scale)
  local y = layout.status.y
  local definitions = {
    { key = 'header', size = 18 * layout.textScale, colour = rgb(1.0, 0.85, 0.40), template = 'textHeader' },
    { key = 'goal', size = 15 * layout.textScale, colour = rgb(0.92, 0.92, 0.92), template = 'textNormal' },
    { key = 'pools', size = 13 * layout.textScale, colour = rgb(0.80, 0.92, 0.80), template = 'textNormal' },
    { key = 'gold', size = 13 * layout.textScale, colour = rgb(0.92, 0.86, 0.52), template = 'textNormal' },
    { key = 'log1', size = 11 * layout.textScale, colour = rgb(0.70, 0.70, 0.70), template = 'textNormal' },
    { key = 'log2', size = 11 * layout.textScale, colour = rgb(0.70, 0.70, 0.70), template = 'textNormal' },
  }
  for _, definition in ipairs(definitions) do
    state.status[definition.key] = createText(
      layout.status.x, y, '', definition.size, definition.colour, definition.template)
    y = y + rowHeight
  end

  -- command bar: buttons, wrapped into rows that stack upward
  state.buttonList = uiLayout.defaultButtons()
  local rows = uiLayout.buttonRows(state.buttonList, layout.bar, layout.scale)

  for _, row in ipairs(rows) do
    for _, button in ipairs(row) do
      state.backgrounds[button.id] = createButtonFace(button, function() onButton(button.id) end)
      state.buttons[button.id] = createText(
        button.x + button.width / 2,
        button.y + button.height / 2,
        button.label,
        14 * layout.textScale,
        rgb(1, 1, 1),
        'textHeader',
        { anchor = vec2(0.5, 0.5), ignorePointerEvents = true })
    end
  end

  state.built = true
end

-- ---------------------------------------------------------------------------
-- render
-- ---------------------------------------------------------------------------

local function setText(key, value)
  local element = state.status[key]
  if not element then return end
  element.layout.props.text = value
  element:update()
end

local function setButtonLabel(id, value)
  local element = state.buttons[id]
  if not element then return end
  element.layout.props.text = value
  element:update()
end

local function render()
  local api = idle()
  local percent = function(fraction) return math.floor((fraction or 0) * 100 + 0.5) .. '%' end

  local playing = true
  local status = nil
  if api then
    if type(api.isAutoPlaying) == 'function' then
      local ok, value = pcall(api.isAutoPlaying)
      if ok then playing = value end
    end
    if type(api.status) == 'function' then
      local ok, value = pcall(api.status)
      if ok then status = value end
    end
  end

  local directive = status and status.directive or nil
  setText('header', ('Idle OpenMW  ·  lvl %s  ·  %s%s'):format(
    tostring(status and status.level or '?'),
    uiLayout.toggleLabel(playing),
    directive and ('  ·  ' .. directive) or ''))

  if not status then
    setText('goal', 'waiting for the director…')
    setText('pools', '')
    setText('gold', '')
  else
    setText('goal', ('%s%s'):format(tostring(status.goal or 'idle'),
      status.reason and ('  (' .. status.reason .. ')') or ''))
    setText('pools', ('HP %s  MP %s  FT %s  LOAD %s'):format(
      percent(status.healthFraction), percent(status.magickaFraction),
      percent(status.fatigueFraction), percent(status.encumbranceFraction)))
    setText('gold', 'Gold ' .. util.formatNumber(status.gold or 0))
  end

  local lines = (status and status.log) or {}
  for i = 1, 2 do
    local entry = lines[#lines - (2 - i)]
    if entry then
      setText('log' .. i, ('%s  %s'):format(activityLog.formatTime(entry.time), entry.message))
    else
      setText('log' .. i, '')
    end
  end

  setButtonLabel('toggle', uiLayout.toggleLabel(playing))
end

-- ---------------------------------------------------------------------------
-- handlers
-- ---------------------------------------------------------------------------

local function update(dt)
  if state.disabled then return end
  if not usable() then state.disabled = true return end

  local ok, err = pcall(function()
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
      print('[IdleOpenMW] HUD disabled: ' .. tostring(err))
    end
  end
end

--- Rebuild on resize/rotation (the layout is resolution-derived).
local function onResolutionChanged()
  if state.disabled then return end
  pcall(function()
    for _, element in pairs(state.status) do if element.destroy then element:destroy() end end
    for _, element in pairs(state.buttons) do if element.destroy then element:destroy() end end
    for _, element in pairs(state.backgrounds) do if element.destroy then element:destroy() end end
  end)
  state.status, state.buttons, state.backgrounds, state.built = {}, {}, {}, false
end

return {
  engineHandlers = {
    onUpdate = update,
    onResolutionChanged = onResolutionChanged,
  },
}
