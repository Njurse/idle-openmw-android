-- scripts/idle/uiState.lua
-- Pure classification of the ENGINE's *live* UI state.
--
-- WHY THIS EXISTS
-- ---------------
-- "Hooking into the UI" cannot mean reading the engine's widgets from Lua:
-- `openmw.ui.getElements` is documented as returning only Elements created with
-- `ui.create`, never native engine widgets (docs/openmw-lua-api.md §11). What
-- Lua *can* read is which UI **modes** are currently open, via
-- `openmw.ui._getUiModeStack()`, which returns the live `GuiMode` stack from the
-- window manager (apps/openmw/mwlua/uibindings.cpp:276; the names are the
-- `modeToName` table at uibindings.cpp:33). That is the real hook: it tells us
-- whether the player is in the main menu, in character creation, talking to
-- someone, looking at their pack, and so on -- without pretending to read the
-- pixels.
--
-- This module turns that raw stack into a small, stable vocabulary
-- (`kind`) that the brain, the console and the guardian can reason about. It is
-- PURE: strings in, a plain table out, no engine and no clock.
--
-- See also scripts/idle/lifecycle.lua, which folds this together with the
-- character-generation flag to decide whether the director may act at all.

local util = require('scripts.idle.util')

local M = {}

-- GuiMode name -> our `kind`. Every name the engine can put on the stack is
-- listed, so an unrecognised name is a genuine engine novelty and shows as
-- 'other' rather than silently masquerading as 'world'.
M.KIND = {
  MainMenu         = 'menu',
  Loading          = 'loading',
  LoadingWallpaper = 'loading',

  Dialogue         = 'dialogue',

  Interface        = 'inventory',
  Container        = 'container',
  Companion        = 'companion',

  Journal          = 'journal',
  Book             = 'book',
  Scroll           = 'book',

  Barter           = 'barter',
  Training         = 'training',
  Rest             = 'rest',
  Travel           = 'travel',
  Jail             = 'jail',
  LevelUp          = 'levelup',
  QuickKeysMenu    = 'quickkeys',

  SpellBuying      = 'spellbuying',
  SpellCreation    = 'spellmaking',
  Enchanting       = 'enchanting',
  Recharge         = 'recharge',
  Alchemy          = 'alchemy',
  Repair           = 'repair',
  MerchantRepair   = 'repair',
}

-- Character creation is a *family* of modes (ChargenName, ChargenRace,
-- ChargenBirth, ChargenClass, ChargenClassGenerate, ChargenClassPick,
-- ChargenClassCreate, ChargenClassReview -- uibindings.cpp:33), so it is matched
-- by prefix rather than enumerated one by one.
M.CHARGEN_PREFIX = 'Chargen'

-- Kinds during which the mod must NOT drive the character: the engine is asking
-- the *player* a question, and steering them would be both rude and a bug.
M.BLOCKING = { menu = true, chargen = true, loading = true }

M.LABEL = {
  menu       = 'Main menu',
  chargen    = 'Character creation',
  loading    = 'Loading',
  dialogue   = 'Talking',
  inventory  = 'Your pack',
  container  = 'A container',
  companion  = 'Companion',
  journal    = 'Journal',
  book       = 'Reading',
  barter     = 'Bartering',
  training   = 'Training',
  rest       = 'Resting',
  travel     = 'Travel service',
  jail       = 'Jail',
  levelup    = 'Level up',
  quickkeys  = 'Quick keys',
  spellbuying = 'Buying spells',
  spellmaking = 'Spellmaking',
  enchanting = 'Enchanting',
  recharge   = 'Recharging',
  alchemy    = 'Alchemy',
  repair     = 'Repair',
  other      = 'Something else',
  world      = 'The world',
}

--- The `kind` for a single engine mode name, or nil when there is no mode.
function M.kindOf(mode)
  if type(mode) ~= 'string' or mode == '' then return nil end
  if mode:sub(1, #M.CHARGEN_PREFIX) == M.CHARGEN_PREFIX then return 'chargen' end
  return M.KIND[mode] or 'other'
end

--- The human label for a mode (used by the console's "On screen" row).
function M.label(mode, kind)
  kind = kind or M.kindOf(mode) or 'world'
  if kind == 'other' then return mode or M.LABEL.other end
  return M.LABEL[kind] or mode or M.LABEL.world
end

--- Copy an engine mode stack into a plain list of strings.
---
--- The stack comes back as engine USERDATA, not a Lua table (measured on 0.51), so
--- `type(stack) == 'table'` is FALSE for a perfectly good stack -- and a caller that checks it
--- reports "nothing is open" while a window is open and the world is paused. One reader, used
--- by the observer, the report and the trace, so that mistake can only be made once.
--- @param raw any the return of ui._getUiModeStack()
--- @return table list of mode names (empty when there is none)
function M.stackOf(raw)
  local out = {}
  if not util.isObject(raw) then return out end
  local ok = pcall(function()
    for index = 1, #raw do
      local mode = raw[index]
      if type(mode) == 'string' and mode ~= '' then out[#out + 1] = mode end
    end
  end)
  if not ok then return {} end
  return out
end

--- Why is the world stopped?
---
--- TWO distinct causes, and they need different remedies, which is why "the world is paused"
--- was so hard to act on:
---
---   * `cause = 'menu'` -- a mode IS open. Visible on the stack, and the mod can close it
---     itself (`interfaces.UI.removeMode`/`setMode`, the game's own Lua module).
---   * `cause = 'messageBox'` -- the stack is EMPTY and the world is still paused. Morrowind's
---     messages are not UI modes, so the stack cannot see them, and Lua cannot click a native
---     widget: the HOST has to dismiss it (tools/dev/desktop/dismiss.py).
---
--- @param paused boolean|nil from core.isWorldPaused()
--- @param stack table the list from M.stackOf
--- @return table { blocked, cause, mode?, hint? }
function M.blocking(paused, stack)
  if paused ~= true then return { blocked = false } end
  local list = type(stack) == 'table' and stack or {}

  if #list == 0 then
    -- NOT necessarily a message box, and saying so was a lie the mod told for a whole session:
    -- a paused world with an empty mode stack can equally be a cinematic, a loading screen, the
    -- game's own chargen, or the in-game CONSOLE. Only the pause TAGS name the owner, and only a
    -- global script can read those (scripts/idleWarden.lua, bridge method `world.pauseTags`).
    --
    -- The console used to be claimed here as a positively-detectable cause ("the mod can close
    -- it itself"). That was wrong twice over and the branch is gone: the pause cause is
    -- `WindowManager::isConsoleMode()`, which is `mConsole->isVisible()`
    -- (apps/openmw/mwgui/windowmanagerimp.cpp:1746) and is NOT exposed to Lua at all, while
    -- `ui.getConsoleMode()` is a different thing -- the console's input-routing mode
    -- (apps/openmw/mwgui/console.hpp:72). So Lua can neither see nor close the console; only the
    -- host can, with the console key.
    return {
      blocked = true,
      cause = 'unknown',
      hint = 'paused with no window open. Could be a message box (needs the host: Lua cannot '
        .. 'click a widget), the in-game console (also the host: Lua cannot see or close it), a '
        .. 'cinematic, or a loading pause. Ask the warden for the pause tags '
        .. '(bridge method "world.pauseTags") to find out which.',
    }
  end

  local top = list[#list]
  return {
    blocked = true,
    cause = 'menu',
    mode = top,
    hint = 'paused by an open window: ' .. tostring(top)
      .. '. The mod can close it, or set it not to pause the game.',
  }
end

--- Classify a single mode name. `nil` means "nothing is open" == the world.
function M.classify(mode)
  local kind = M.kindOf(mode)
  if not kind then
    return { mode = nil, kind = 'world', blocking = false, label = M.LABEL.world }
  end
  return {
    mode = mode,
    kind = kind,
    blocking = M.BLOCKING[kind] == true,
    label = M.label(mode, kind),
  }
end

--- Classify a mode *stack* (`ui._getUiModeStack()`), newest mode last.
--- `fallback` is used only when the stack is empty -- the older
--- `interfaces.UI.getMode()` string on an engine whose internal hook is missing.
function M.fromStack(stack, fallback)
  -- a plain list may be handed in, or the raw engine value; M.stackOf copes with both
  local copy = M.stackOf(stack)

  local top = copy[#copy]
  if not top and type(fallback) == 'string' and fallback ~= '' then top = fallback end

  local out = M.classify(top)
  out.stack = copy
  return out
end

return M
