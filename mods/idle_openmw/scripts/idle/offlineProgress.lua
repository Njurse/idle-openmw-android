-- scripts/idle/offlineProgress.lua
-- Time-based catch-up for time spent with the game closed.
--
-- OpenMW does not simulate a single-player world while the app is shut (see the
-- plan's "Option A"), so we award a bounded, deterministic catch-up instead.
-- ALL of the maths lives here, pure; the runtime adapter only supplies the
-- wall-clock timestamp (`os.time()` at save, diffed at load) and applies the
-- returned deltas.
--
-- Pure: no engine, no I/O.

local util = require('scripts.idle.util')

local M = {}

--- Below this, an absence is not worth reporting.
M.MIN_ELAPSED_SECONDS = 60

--- Real seconds between `stored.lastSeen` and `now` (never negative).
function M.elapsedFromLastSeen(stored, now)
  local last = stored and stored.lastSeen
  if type(last) ~= 'number' or type(now) ~= 'number' then return 0 end
  return math.max(0, now - last)
end

--- Should a catch-up be awarded for this absence?
function M.shouldApply(elapsedSeconds, cfg)
  if not cfg.offline.enabled then return false end
  if type(elapsedSeconds) ~= 'number' or elapsedSeconds < M.MIN_ELAPSED_SECONDS then return false end
  return true
end

--- Compute a catch-up award. Pure: returns the deltas, applies nothing.
--- @param elapsedSeconds real seconds since last seen
--- @param cfg            config table
--- @return table award { applied, capped, elapsedSeconds, effectiveSeconds,
---                       gameHours, gold, skillProgress, itemValue }
function M.compute(elapsedSeconds, cfg)
  elapsedSeconds = elapsedSeconds or 0
  local award = {
    applied = false, capped = false,
    elapsedSeconds = elapsedSeconds, effectiveSeconds = 0,
    gameHours = 0, gold = 0, skillProgress = 0, itemValue = 0,
  }
  if not M.shouldApply(elapsedSeconds, cfg) then return award end

  local offline = cfg.offline
  local maxSeconds = (offline.maxRealHours or 0) * 3600
  local effective = math.min(elapsedSeconds, maxSeconds)
  award.capped = elapsedSeconds > maxSeconds
  award.effectiveSeconds = effective

  -- 1 real minute == `gameHoursPerRealMinute` game hours, scaled by how
  -- productive we assume the time to have been.
  local gameHours = (effective / 60) * (offline.gameHoursPerRealMinute or 0)
  gameHours = gameHours * util.clamp(offline.riskOccupancy or 0, 0, 1)
  award.gameHours = gameHours

  award.gold = math.floor(gameHours * (offline.goldPerGameHour or 0))
  award.skillProgress = gameHours * (offline.skillProgressPerGameHour or 0)
  award.itemValue = math.floor(gameHours * (offline.itemsPerGameHour or 0))
  award.applied = award.gold > 0 or award.skillProgress > 0 or award.itemValue > 0
  return award
end

--- Apply an award to a stored state, returning a NEW table plus the award.
--- @param stored { gold = n, totalOfflineGold = n, ... }
function M.apply(stored, elapsedSeconds, cfg)
  local out = util.deepCopy(stored or {})
  out.gold = out.gold or 0
  local award = M.compute(elapsedSeconds, cfg)
  out.gold = out.gold + award.gold
  out.totalOfflineGold = (out.totalOfflineGold or 0) + award.gold
  out.lastAward = award
  return out, award
end

--- Convenience: apply using a stored `lastSeen` and a current timestamp.
function M.applySince(stored, now, cfg)
  return M.apply(stored, M.elapsedFromLastSeen(stored, now), cfg)
end

--- Human-readable summary, e.g. "8h 00m away (capped): +4,800 gold, +96 skill progress".
function M.describe(award)
  local seconds = award.effectiveSeconds or 0
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local capped = award.capped and ' (capped)' or ''
  return ('%dh %02dm away%s: +%s gold, +%.0f skill progress')
    :format(hours, minutes, capped, util.formatNumber(award.gold or 0), award.skillProgress or 0)
end

return M
