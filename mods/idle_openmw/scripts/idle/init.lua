-- scripts/idle/init.lua
-- Namespace for the engine-agnostic idle director core.
--
-- Everything reachable from here is pure Lua with no `openmw.*` dependency, so
-- it can be exercised headlessly (see tests/). The only place the engine is
-- touched is scripts/runtime/* and the two PLAYER scripts.
--
-- Require individual modules in production code to keep load cost low:
--   local director = require('scripts.idle.director')

local M = {}

M.VERSION = '0.1.0'

M.util = require('scripts.idle.util')
M.rng = require('scripts.idle.rng')
M.config = require('scripts.idle.config')
M.classPriorities = require('scripts.idle.classPriorities')
M.statCrunch = require('scripts.idle.statCrunch')
M.goalScoring = require('scripts.idle.goalScoring')
M.economy = require('scripts.idle.economy')
M.offlineProgress = require('scripts.idle.offlineProgress')
M.activityLog = require('scripts.idle.activityLog')
M.pathfinder = require('scripts.idle.pathfinder')
M.combat = require('scripts.idle.combat')
M.dialogue = require('scripts.idle.dialogue')
M.directive = require('scripts.idle.directive')
M.equipment = require('scripts.idle.equipment')
M.uiLayout = require('scripts.idle.uiLayout')
M.uiModel = require('scripts.idle.uiModel')
M.director = require('scripts.idle.director')

return M
