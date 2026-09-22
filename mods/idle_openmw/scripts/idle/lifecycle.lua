-- scripts/idle/lifecycle.lua
-- Pure classification of *where we are in the game's life*: main menu,
-- loading, character creation, dead, or free in the world.
--
-- WHY THIS EXISTS
-- ---------------
-- The idle director is a PLAYER script, so it starts ticking the moment a game
-- is loaded -- including during character creation, when the engine is asking
-- the human to pick a race, class and birthsign. If the director "helped" then,
-- it would fight the chargen windows and the player would never reach Seyda
-- Neen. The same is true of the main menu and of any load screen.
--
-- The definitive signal is `types.Player.isCharGenFinished(player)`
-- (apps/openmw/mwlua/types/player.cpp:438; it returns
-- `getGlobalFloat("chargenstate") == -1`, set to 1 on a new game and -1
-- afterwards -- apps/openmw/mwworld/worldimp.cpp:290). While that is false the
-- character is still being created. Even without it, seeing a `Chargen*` UI mode
-- (scripts/idle/uiState.lua) is enough to know to hold fire.
--
-- This module is PURE: a few booleans/strings in, a phase table out.

local M = {}

M.PHASES = { 'menu', 'loading', 'chargen', 'dead', 'world' }

-- Only one phase lets the director choose goals and emit commands.
M.ACTING = { world = true }

M.LABEL = {
  menu    = 'Main menu',
  loading = 'Loading',
  chargen = 'Character creation',
  dead    = 'Dead',
  world   = 'In the world',
}

M.NOTE = {
  menu    = 'no character is loaded',
  loading = 'the game is loading',
  chargen = 'finish character creation first',
  dead    = 'the character is dead',
  world   = nil,
}

--- Describe a phase id as a small table.
function M.describe(id)
  id = id or 'world'
  if not M.ACTING[id] and M.LABEL[id] == nil then id = 'world' end
  return {
    id = id,
    label = M.LABEL[id] or id,
    acting = M.ACTING[id] == true,
    note = M.NOTE[id],
  }
end

--- Derive the phase from observable signals.
--- @param input {
---   playerExists?    boolean,   -- is there a player object at all
---   charGenFinished? boolean,   -- types.Player.isCharGenFinished (nil = unknown)
---   uiKind?          string,    -- scripts/idle/uiState.lua kind
---   dead?            boolean,   -- health.current <= 0
--- }
---
--- Precedence, most specific first: no player at all -> menu; an explicit
--- loading/menu UI mode; character creation (flag *or* UI); death; else world.
--- An UNKNOWN char-gen flag resolves to `world`, so an engine that lacks the
--- call cannot accidentally lock the mod out of playing.
function M.phase(input)
  input = input or {}

  if input.playerExists == false then return M.describe('menu') end
  if input.uiKind == 'loading' then return M.describe('loading') end
  if input.uiKind == 'menu' then return M.describe('menu') end
  if input.charGenFinished == false or input.uiKind == 'chargen' then
    return M.describe('chargen')
  end
  if input.dead == true then return M.describe('dead') end
  return M.describe('world')
end

--- True when the director may act on its own initiative in this phase.
function M.mayAct(phase)
  return type(phase) == 'table' and phase.acting == true
end

return M
