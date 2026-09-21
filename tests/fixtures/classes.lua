-- tests/fixtures/classes.lua
-- Class definitions used across specs, and a couple of synthetic ones.
local classPriorities = require('scripts.idle.classPriorities')

local M = {}

M.warrior = classPriorities.presets.warrior
M.mage = classPriorities.presets.mage
M.thief = classPriorities.presets.thief
M.healer = classPriorities.presets.healer

-- A class with no skills at all: all-specialization-less, used to prove the
-- derivation degrades gracefully.
M.blank = {
  id = 'blank', name = 'Blank', specialization = 'combat',
  majorSkills = {}, minorSkills = {},
}

-- A synthetic hybrid to check affinity handling (mercantile -> economy+social).
M.peddler = {
  id = 'peddler', name = 'Peddler', specialization = 'stealth',
  majorSkills = { 'mercantile', 'speechcraft', 'security', 'sneak', 'lightarmor' },
  minorSkills = { 'shortblade', 'acrobatics', 'illusion', 'alchemy', 'athletics' },
}

return M
