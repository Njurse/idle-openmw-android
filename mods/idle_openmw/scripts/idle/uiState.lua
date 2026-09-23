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
  local copy = {}
  if util.isObject(stack) then
    for i = 1, #stack do
      if type(stack[i]) == 'string' and stack[i] ~= '' then copy[#copy + 1] = stack[i] end
    end
  end

  local top = copy[#copy]
  if not top and type(fallback) == 'string' and fallback ~= '' then top = fallback end

  local out = M.classify(top)
  out.stack = copy
  return out
end

return M
