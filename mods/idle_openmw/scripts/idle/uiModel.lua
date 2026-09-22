-- scripts/idle/uiModel.lua
-- The console's brain: what tabs exist, what rows each tab shows, what the
-- footer actions do, how scrolling and selection behave, and how modes cycle.
--
-- PURE. No engine, no ui.*, no I/O -- so the entire interaction model is
-- unit-testable even though the widgets that draw it are not. portraitUI.lua is
-- just a renderer over this.
--
-- PANEL SNAPSHOT (built by runtime/observer.lua:readPanel)
--   {
--     status     = <director:status()>,
--     player     = { gold, level, encumbrance = {current,max} },
--     inventory  = { { id, count, value, weight, equipped, junk, valuePerWeight }, ... },
--     dialogue   = { { actor, kind, recordId, time }, ... },   -- newest last
--     topics     = { { topic, count }, ... },
--     journal    = { { text, questId }, ... },                 -- newest last
--     quests     = { { id, stage, started, finished }, ... },
--     log        = { { message, level, time }, ... },           -- oldest first
--     mode       = 'manual'|'directive'|'auto',
--     directive  = <id or nil>,
--     config     = <config table>,
--   }

local util = require('scripts.idle.util')
local activityLog = require('scripts.idle.activityLog')
local economy = require('scripts.idle.economy')
local equipment = require('scripts.idle.equipment')

local M = {}

-- ---------------------------------------------------------------------------
-- vocabulary
-- ---------------------------------------------------------------------------

M.TABS = {
  { id = 'info', label = 'Info' },
  { id = 'orders', label = 'Order' },
  { id = 'pack', label = 'Pack' },
  { id = 'talk', label = 'Talk' },
  { id = 'log', label = 'Log' },
  { id = 'open', label = 'Open' },
  { id = 'setup', label = 'Setup' },
}

M.MODES = { 'manual', 'directive', 'auto' }
M.MODE_LABEL = { manual = 'MANUAL', directive = 'ORDERS', auto = 'AUTO' }

M.MODE_HINT = {
  manual = 'you drive — game controls active',
  directive = 'auto-play, obeying your orders',
  auto = 'auto-play',
}

--- Player orders (mapped to directive ids the director understands).
M.ORDERS = {
  { id = 'shop', label = 'Find a shop' },
  { id = 'sell_junk', label = 'Sell junk' },
  { id = 'rest', label = 'Rest' },
  { id = 'train', label = 'Train' },
  { id = 'heal', label = 'Heal up' },
  { id = 'talk', label = 'Talk to someone' },
  { id = 'quest', label = 'Do a quest' },
  { id = 'travel', label = 'Travel' },
  { id = 'explore', label = 'Explore' },
  -- "World actions": keep the character in place, or move it deliberately.
  { id = 'wait', label = 'Wait / stop' },
  { id = 'roam', label = 'Roam the area' },
  { id = 'go_town', label = 'Go to town' },
}

--- Options the player can cycle from the Setup tab. Each is a dotted path into
--- the live config, so changing one takes effect on the next tick.
M.OPTIONS = {
  { key = 'simulateActions', kind = 'boolean', path = { 'behaviour', 'simulateActions' },
    label = 'Simulated actions' },
  { key = 'autoTravel', kind = 'boolean', path = { 'behaviour', 'autoTravel' },
    label = 'Travel on its own' },
  { key = 'roam', kind = 'boolean', path = { 'behaviour', 'roam' },
    label = 'Roam on its own' },
  { key = 'npcFightHostility', kind = 'boolean', path = { 'sensing', 'npcFightHostility' },
    label = 'Attack hostile NPCs' },
  { key = 'creaturesAreHostile', kind = 'boolean', path = { 'sensing', 'creaturesAreHostile' },
    label = 'Attack creatures' },
  { key = 'refresh', kind = 'choice', path = { 'ui', 'refresh' },
    choices = { 0.25, 0.5, 1.0, 2.0 }, label = 'Console refresh (s)' },
  { key = 'startMode', kind = 'choice', path = { 'ui', 'startMode' },
    choices = { 'auto', 'directive', 'manual' }, label = 'Mode on load' },
  { key = 'isometric', kind = 'boolean', path = { 'camera', 'isometric' },
    label = 'Isometric camera' },
  { key = 'theme', kind = 'choice', path = { 'ui', 'theme' },
    choices = { 'morrowind', 'plain' }, label = 'Console colours' },
}

--- Read an option's current value out of a config by its path.
function M.optionValue(config, option)
  local node = config
  for _, key in ipairs(option.path or {}) do
    if type(node) ~= 'table' then return nil end
    node = node[key]
  end
  return node
end

--- The next value in an option's cycle: booleans flip, choices wrap.
function M.nextOptionValue(option, current)
  if option.kind == 'boolean' then return not (current == true) end
  local choices = option.choices or {}
  if #choices == 0 then return current end
  for index, value in ipairs(choices) do
    if value == current then return choices[(index % #choices) + 1] end
  end
  return choices[1]
end

--- Find an option definition by key.
function M.findOption(key)
  for _, option in ipairs(M.OPTIONS) do
    if option.key == key then return option end
  end
  return nil
end

--- Write `value` at an option's path, creating intermediate tables as needed.
--- Returns true on success. Refuses rather than guessing when the path is broken.
function M.setOptionValue(config, option, value)
  if type(config) ~= 'table' or type(option) ~= 'table' then return false end
  local path = option.path or {}
  if #path == 0 then return false end
  local node = config
  for index = 1, #path - 1 do
    local key = path[index]
    if node[key] == nil then node[key] = {} end
    if type(node[key]) ~= 'table' then return false end
    node = node[key]
  end
  node[path[#path]] = value
  return true
end

--- How an option's value reads in the list.
function M.formatOptionValue(option, value)
  if option.kind == 'boolean' then return value and 'ON' or 'OFF' end
  if value == nil then return '--' end
  if type(value) == 'number' then return ('%.2f'):format(value) end
  return tostring(value)
end

--- Launchers: open Morrowind's OWN windows. This is what keeps the whole game
--- reachable from the console (modes verified in mwlua/uibindings.cpp).
M.LAUNCHERS = {
  { id = 'open_inventory', label = 'Inventory', detail = 'equip, drop, use', mode = 'Interface' },
  { id = 'open_journal', label = 'Journal', detail = 'quests and entries', mode = 'Journal' },
  { id = 'open_barter', label = 'Barter', detail = 'trade with a merchant', mode = 'Barter' },
  { id = 'open_training', label = 'Training', detail = 'spend gold on skills', mode = 'Training' },
  { id = 'open_dialogue', label = 'Dialogue', detail = 'talk to the nearest NPC', mode = 'Dialogue' },
  { id = 'open_rest', label = 'Rest', detail = 'the rest window', mode = 'Rest' },
  { id = 'open_spellbuying', label = 'Spells', detail = 'buy spells', mode = 'SpellBuying' },
  { id = 'open_map', label = 'Map', detail = 'the world map', mode = 'Interface', window = 'Map' },
}

--- Contextual footer per tab. `label` is the text on the button.
--- Every tab also gets a `toggle_panel` button, because collapsing the console is
--- how the player gets the game back (docs/limitations.md section 3).
--- @param opts { collapsed? } — flips the toggle's label
function M.footerFor(tabId, opts)
  opts = opts or {}
  local actions
  if tabId == 'info' then
    actions = { { id = 'cycle_mode', label = 'Mode' }, { id = 'pause', label = 'Pause' } }
  elseif tabId == 'orders' then
    actions = { { id = 'queue', label = 'Queue' }, { id = 'cancel', label = 'Cancel' } }
  elseif tabId == 'pack' then
    actions = { { id = 'equip', label = 'Equip' }, { id = 'sell', label = 'Sell' },
                { id = 'drop', label = 'Drop' }, { id = 'refresh', label = 'Refresh' } }
  elseif tabId == 'talk' then
    actions = { { id = 'talk_nearest', label = 'Talk' }, { id = 'open_dialogue', label = 'Window' },
                { id = 'open_journal', label = 'Journal' } }
  elseif tabId == 'log' then
    actions = { { id = 'clear_log', label = 'Clear' }, { id = 'open_journal', label = 'Journal' } }
  else
    actions = {}
  end

  actions[#actions + 1] = {
    id = 'toggle_panel',
    label = opts.collapsed and 'Expand' or 'Shrink',
  }
  return actions
end

--- Footer actions that need a selected row to make sense.
M.REQUIRES_SELECTION = { equip = true, sell = true, drop = true }

function M.isKnownTab(id)
  for _, tab in ipairs(M.TABS) do if tab.id == id then return true end end
  return false
end

function M.tabIds() return util.map(M.TABS, function(tab) return tab.id end) end

-- ---------------------------------------------------------------------------
-- modes and tabs
-- ---------------------------------------------------------------------------

--- Cycle manual -> directive -> auto -> manual.
function M.nextMode(mode)
  for i, candidate in ipairs(M.MODES) do
    if candidate == mode then return M.MODES[i % #M.MODES + 1] end
  end
  return M.MODES[1]
end

function M.modeLabel(mode) return M.MODE_LABEL[mode] or 'AUTO' end

--- Next tab id from `id`, stepping by `dir` (+1/-1) and wrapping.
function M.nextTab(id, dir)
  local ids = M.tabIds()
  if #ids == 0 then return nil end
  dir = dir or 1
  for i, candidate in ipairs(ids) do
    if candidate == id then
      local nextIndex = ((i - 1 + dir) % #ids) + 1
      return ids[nextIndex]
    end
  end
  return ids[1]
end

-- ---------------------------------------------------------------------------
-- scrolling and selection
-- ---------------------------------------------------------------------------

--- Clamp a scroll offset so the visible window stays inside the rows.
function M.scroll(offset, delta, total, pageSize)
  offset = (offset or 0) + (delta or 0)
  local maxOffset = math.max(0, (total or 0) - (pageSize or 1))
  return util.clamp(offset, 0, maxOffset)
end

--- The visible slice plus whether we can scroll further either way.
function M.visible(rows, offset, pageSize)
  rows = rows or {}
  pageSize = math.max(1, pageSize or 1)
  offset = M.scroll(offset or 0, 0, #rows, pageSize)
  local slice = {}
  for i = offset + 1, math.min(#rows, offset + pageSize) do
    slice[#slice + 1] = rows[i]
  end
  return {
    rows = slice,
    offset = offset,
    total = #rows,
    canUp = offset > 0,
    canDown = offset + pageSize < #rows,
    pageSize = pageSize,
  }
end

--- Keep a row selection inside bounds (nil when there is nothing to select).
function M.clampSelection(index, rows, offset, pageSize)
  local visible = M.visible(rows, offset, pageSize)
  if #visible.rows == 0 then return nil end
  index = index or 1
  if index < 1 then index = 1 end
  if index > #visible.rows then index = #visible.rows end
  return index
end

--- The selected row table, or nil.
function M.selectedRow(rows, offset, pageSize, index)
  local visible = M.visible(rows, offset, pageSize)
  local clamped = M.clampSelection(index, rows, offset, pageSize)
  if not clamped then return nil end
  return visible.rows[clamped]
end

-- ---------------------------------------------------------------------------
-- row building
-- ---------------------------------------------------------------------------

local function pct(fraction)
  return math.floor((fraction or 0) * 100 + 0.5) .. '%'
end

local function row(spec)
  return spec
end

--- Format a row into the single line the renderer draws.
function M.formatRow(row_)
  if type(row_) ~= 'table' then return '' end
  if row_.detail and row_.detail ~= '' then
    return tostring(row_.label or '') .. '  ' .. tostring(row_.detail)
  end
  return tostring(row_.label or '')
end

--- "rows 3-12 of 40", for the console's readout strip (`uiLayout.listRects.page`).
--- @param state { total?, offset?, pageSize? }
function M.pageText(state)
  state = state or {}
  local total = state.total or 0
  if total <= 0 then return '' end
  local pageSize = math.max(1, state.pageSize or 1)
  local offset = math.max(0, state.offset or 0)
  if total <= pageSize then return ('%d rows'):format(total) end
  local from = math.min(total, offset + 1)
  local to = math.min(total, offset + pageSize)
  return ('rows %d-%d of %d'):format(from, to, total)
end

local function infoRows(panel)
  local rows = {}
  local status = panel.status or {}
  local player = panel.player or {}

  rows[#rows + 1] = row({ id = 'mode', kind = 'info', label = 'Mode',
    detail = ('%s — %s'):format(M.modeLabel(panel.mode), M.MODE_HINT[panel.mode] or '') })

  -- Why the bot may be doing nothing: it is not in the world yet (character
  -- creation, the menu, a load screen) -- see scripts/idle/lifecycle.lua.
  local phase = panel.phase
  if phase and phase.id and phase.id ~= 'world' then
    rows[#rows + 1] = row({ id = 'phase', kind = 'info', label = 'Holding',
      detail = ('%s — %s'):format(tostring(phase.label or phase.id), tostring(phase.note or '')) })
  end
  -- What the engine currently has open (read from ui._getUiModeStack; see
  -- scripts/idle/uiState.lua). This is the "hook into the UI" the player sees.
  local ui = panel.ui
  if ui and ui.mode then
    rows[#rows + 1] = row({ id = 'ui', kind = 'info', label = 'On screen',
      detail = tostring(ui.label or ui.mode) })
  end
  rows[#rows + 1] = row({ id = 'goal', kind = 'info', label = 'Goal',
    detail = ('%s%s'):format(tostring(status.goal or 'idle'),
      status.reason and ('  (' .. status.reason .. ')') or '') })
  if panel.directive then
    rows[#rows + 1] = row({ id = 'directive', kind = 'info', label = 'Order', detail = panel.directive })
  end

  rows[#rows + 1] = row({ id = 'pools', kind = 'info', label = 'Pools',
    detail = ('HP %s  MP %s  FT %s  LOAD %s'):format(
      pct(status.healthFraction), pct(status.magickaFraction),
      pct(status.fatigueFraction), pct(status.encumbranceFraction)) })

  local load = player.encumbrance
  rows[#rows + 1] = row({ id = 'gold', kind = 'info', label = 'Gold',
    detail = ('%s   level %s%s'):format(
      util.formatNumber(player.gold or status.gold or 0),
      tostring(player.level or status.level or '?'),
      load and ('   load %d/%d'):format(load.current or 0, load.max or 0) or '') })

  if status.topGoals and #status.topGoals > 0 then
    rows[#rows + 1] = row({ id = 'rank-header', kind = 'heading', label = 'Considering' })
    for _, entry in ipairs(status.topGoals) do
      rows[#rows + 1] = row({ id = 'rank-' .. entry.id, kind = 'info',
        label = '  ' .. entry.id, detail = tostring(entry.score) })
    end
  end

  if status.counters then
    rows[#rows + 1] = row({ id = 'counters', kind = 'info', label = 'Decisions',
      detail = ('%d (goals changed %d)'):format(
        status.counters.ticks or 0, status.counters.goalChanges or 0) })
  end
  return rows
end

local function orderRows(panel)
  local rows = {}
  for _, order in ipairs(M.ORDERS) do
    rows[#rows + 1] = row({
      id = 'order:' .. order.id,
      kind = 'action',
      label = order.label,
      detail = panel.directive == order.id and 'ACTIVE' or nil,
      action = 'order',
      payload = { id = order.id },
      selectable = false,
    })
  end

  -- Where the nearest travel service can take you. Autonomous travel is off by
  -- default, so this is how the player uses it: tap to walk there and open the
  -- travel window, then pick the destination in the game's own UI.
  local travel = panel.travel
  if type(travel) == 'table' and #travel > 0 then
    local cells = {}
    for _, destination in ipairs(travel) do
      if destination.cell then cells[#cells + 1] = tostring(destination.cell) end
    end
    rows[#rows + 1] = row({
      id = 'travel-service', kind = 'heading',
      label = ('%s can take you to:'):format(tostring(panel.travelService or 'Travel service')),
    })
    rows[#rows + 1] = row({
      id = 'order:travel:go',
      kind = 'action',
      label = 'Go to the travel service',
      detail = table.concat(cells, ', '),
      action = 'order',
      payload = { id = 'travel' },
      -- contextual: this row only exists when a travel service is nearby, so it
      -- is not one of the static M.ORDERS
      contextual = true,
      selectable = false,
    })
  end

  rows[#rows + 1] = row({ id = 'orders-note', kind = 'heading',
    label = 'Queueing an order overrides auto-play for a while' })
  return rows
end

local function setupRows(panel)
  local rows = {}
  rows[#rows + 1] = row({ id = 'setup-note', kind = 'heading',
    label = 'Tap an option to cycle it; changes apply at once' })
  for _, option in ipairs(M.OPTIONS) do
    rows[#rows + 1] = row({
      id = 'option:' .. option.key,
      kind = 'action',
      label = option.label,
      detail = M.formatOptionValue(option, M.optionValue(panel.config, option)),
      action = 'set_option',
      payload = { key = option.key, path = option.path },
      selectable = false,
    })
  end
  return rows
end

local function packRows(panel)
  local rows = {}
  local inventory = panel.inventory or {}
  local cfg = panel.config

  -- --- the "portrait": what is worn, slot by slot (equipment.paperDoll) ---
  local known = false
  for _, item in ipairs(inventory) do
    if item.equipped then known = true break end
  end
  if known then
    rows[#rows + 1] = row({ id = 'worn-header', kind = 'heading', label = 'Worn' })
    for _, entry in ipairs(equipment.paperDoll(inventory)) do
      local item = entry.item
      if item or entry.slot == 'CarriedRight' or entry.slot == 'CarriedLeft' then
        rows[#rows + 1] = row({
          id = 'worn:' .. entry.slot,
          kind = item and 'action' or 'info',
          label = '  ' .. entry.label,
          detail = item and ('%s%s'):format(tostring(item.id),
            (item.count or 1) > 1 and (' x' .. item.count) or '') or '(empty)',
          -- tapping a worn piece selects it, so the footer can swap/sell/drop it
          action = item and 'select' or nil,
          payload = item and { index = entry.index, id = item.id, count = item.count } or nil,
          selectable = false,
        })
      end
    end
    rows[#rows + 1] = row({ id = 'carried-header', kind = 'heading', label = 'Carried' })
  end

  for index, item in ipairs(inventory) do
    local flags = {}
    if item.equipped then flags[#flags + 1] = 'WORN' end
    if item.junk then flags[#flags + 1] = 'junk' end
    -- weightless items have an infinite value/weight ratio: cap it for display
    local ratio = item.valuePerWeight
    local ratioText = ratio and ('%.1f'):format(math.min(ratio, 9999)) or '--'
    local detail = ('x%d  %sg  %sg/w%s'):format(
      item.count or 1, tostring(item.value or 0), ratioText,
      #flags > 0 and ('  [' .. table.concat(flags, ' ') .. ']') or '')
    rows[#rows + 1] = row({
      id = 'item:' .. tostring(item.id),
      kind = 'item',
      label = tostring(item.id),
      detail = detail,
      action = 'select',
      payload = { index = index, id = item.id, count = item.count },
    })
  end
  if #rows == 0 then
    rows[#rows + 1] = row({ id = 'pack-empty', kind = 'heading', label = '(nothing carried)' })
  elseif cfg then
    local summary = economy.summarize(inventory, cfg)
    rows[#rows + 1] = row({ id = 'pack-total', kind = 'heading',
      label = ('%d items   junk worth %sg in %d stacks'):format(
        summary.itemCount, util.formatNumber(summary.junkValue), summary.junkCount) })
  end
  return rows
end

local function talkRows(panel)
  local rows = {}
  local dialogue = panel.dialogue or {}
  rows[#rows + 1] = row({ id = 'talk-header', kind = 'heading', label = 'Recent conversations' })
  if #dialogue == 0 then
    rows[#rows + 1] = row({ id = 'talk-empty', kind = 'info', label = '(nobody has spoken to you yet)' })
  else
    for i = #dialogue, math.max(1, #dialogue - 7), -1 do
      local event = dialogue[i]
      rows[#rows + 1] = row({ id = 'talk:' .. i, kind = 'info',
        label = activityLog.formatTime(event.time or 0),
        detail = ('%s  %s%s'):format(tostring(event.actor or '?'), tostring(event.kind or ''),
          event.recordId and ('  "' .. tostring(event.recordId) .. '"') or '') })
    end
  end

  local topics = panel.topics or {}
  if #topics > 0 then
    rows[#rows + 1] = row({ id = 'topics-header', kind = 'heading', label = 'Topics heard' })
    for i = 1, math.min(6, #topics) do
      rows[#rows + 1] = row({ id = 'topic:' .. tostring(topics[i].topic), kind = 'info',
        label = tostring(topics[i].topic), detail = ('x%d'):format(topics[i].count or 1) })
    end
  end

  -- The topics the player has *unlocked* (types.Player.journal().topics). Tapping
  -- one walks to the nearest NPC and opens the dialogue window; the topic itself
  -- has to be picked in the game's own window -- Lua has no hook for selecting a
  -- dialogue topic (docs/dialogue.md).
  local known = panel.journalTopics or {}
  if #known > 0 then
    rows[#rows + 1] = row({ id = 'known-header', kind = 'heading', label = 'Topics you know' })
    for i = 1, math.min(12, #known) do
      local topic = known[i]
      rows[#rows + 1] = row({
        id = 'known:' .. tostring(topic.topic),
        kind = 'action',
        label = '  ' .. tostring(topic.topic),
        detail = (topic.lines and topic.lines > 0) and ('%d lines'):format(topic.lines) or nil,
        action = 'order',
        payload = { id = 'talk' },
        selectable = false,
      })
    end
    rows[#rows + 1] = row({ id = 'known-note', kind = 'heading',
      label = 'Tap a topic to walk over and open the dialogue' })
  end

  local quests = panel.quests or {}
  if #quests > 0 then
    rows[#rows + 1] = row({ id = 'quests-header', kind = 'heading', label = 'Quests' })
    for i = 1, math.min(8, #quests) do
      local quest = quests[i]
      rows[#rows + 1] = row({ id = 'quest:' .. tostring(quest.id), kind = 'info',
        label = tostring(quest.id),
        detail = ('stage %s%s'):format(tostring(quest.stage or 0),
          quest.finished and '  DONE' or '') })
    end
  end
  return rows
end

local function logRows(panel)
  local rows = {}
  local entries = panel.log or {}
  if #entries == 0 then
    rows[1] = row({ id = 'log-empty', kind = 'info', label = '(no activity yet)' })
    return rows
  end
  for i = #entries, 1, -1 do
    local entry = entries[i]
    rows[#rows + 1] = row({ id = 'log:' .. i, kind = 'log', level = entry.level,
      label = activityLog.formatTime(entry.time or 0), detail = tostring(entry.message or '') })
  end
  return rows
end

local function openRows()
  local rows = {}
  rows[#rows + 1] = row({ id = 'open-header', kind = 'heading',
    label = 'Open a Morrowind window' })
  for _, launcher in ipairs(M.LAUNCHERS) do
    rows[#rows + 1] = row({
      id = launcher.id,
      kind = 'action',
      label = launcher.label,
      detail = launcher.detail,
      action = 'launch',
      payload = { mode = launcher.mode, window = launcher.window, id = launcher.id },
    })
  end
  return rows
end

--- Build the rows for a tab from the panel snapshot.
function M.buildRows(tabId, panel)
  panel = panel or {}
  if tabId == 'info' then return infoRows(panel) end
  if tabId == 'orders' then return orderRows(panel) end
  if tabId == 'pack' then return packRows(panel) end
  if tabId == 'talk' then return talkRows(panel) end
  if tabId == 'log' then return logRows(panel) end
  if tabId == 'open' then return openRows() end
  if tabId == 'setup' then return setupRows(panel) end
  return {}
end

--- Build the whole view model the renderer needs in one pass.
function M.view(state, panel, layout)
  state = state or {}
  local tabId = M.isKnownTab(state.tab) and state.tab or M.TABS[1].id
  local rows = M.buildRows(tabId, panel)
  local pageSize = (layout and layout.pageSize) or 10
  local offset = M.scroll(state.offset or 0, 0, #rows, pageSize)
  local visible = M.visible(rows, offset, pageSize)

  local selection = nil
  if visible.rows and #visible.rows > 0 then
    selection = M.clampSelection(state.selection or 1, rows, offset, pageSize)
  end

  return {
    tab = tabId,
    tabs = M.TABS,
    rows = rows,
    visible = visible,
    offset = offset,
    total = #rows,
    pageSize = pageSize,
    selection = selection,
    selected = M.selectedRow(rows, offset, pageSize, state.selection or 1),
    footer = M.footerFor(tabId, { collapsed = state.collapsed }),
    mode = panel and panel.mode or 'auto',
    directive = panel and panel.directive or nil,
  }
end

return M
