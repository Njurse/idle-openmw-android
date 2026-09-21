-- scripts/idle/combat.lua
-- Threat assessment. Pure: no engine, no I/O.
--
-- The runtime supplies a list of nearby hostiles (from `nearby.actors`, filtered
-- by hostility) with an approximate level/threat; this module turns that into a
-- single 0..1 "danger" number plus a verdict the goal scorer uses.

local util = require('scripts.idle.util')

local M = {}

--- Threat contributed by one hostile.
--- @param enemy { level = n, threat = n?, count = n? }
function M.threatOf(enemy)
  enemy = enemy or {}
  local level = enemy.level or 1
  local base = enemy.threat or (level / 10)
  return util.clamp(base * (enemy.count or 1), 0, 3)
end

--- How much fight the character can bring, 0..1, from its capability scores.
function M.power(playerCapability)
  playerCapability = playerCapability or {}
  return util.clamp(
    0.35 * (playerCapability.combat or 0)
    + 0.20 * (playerCapability.magic or 0)
    + 0.15, 0, 1)
end

--- Aggregate assessment for a set of hostiles.
--- @param enemies list of { level, threat?, count?, name? }
--- @return { danger, count, threat, power, ratio, verdict }
function M.assess(enemies, playerCapability, cfg)
  local count, threat = 0, 0
  for _, enemy in ipairs(enemies or {}) do
    count = count + 1
    threat = threat + M.threatOf(enemy)
  end
  if count == 0 then
    return { danger = 0, count = 0, threat = 0, power = M.power(playerCapability), ratio = 0, verdict = 'safe' }
  end

  local power = M.power(playerCapability)
  -- ratio == 1 means "evenly matched"; > 1 means the mob outguns you.
  local ratio = threat / math.max(0.05, power * 3)
  local danger = util.clamp(ratio / 2.5, 0, 1)

  local verdict
  if danger >= cfg.thresholds.dangerFlee then
    verdict = 'flee'
  elseif danger <= cfg.thresholds.dangerEngage then
    verdict = 'engage'
  else
    verdict = 'caution'
  end
  return { danger = danger, count = count, threat = threat, power = power, ratio = ratio, verdict = verdict }
end

--- Pick an engagement stance for a class: how much danger it tolerates.
--- Warriors wade in; mages and thieves prefer the shadows.
function M.stanceFor(weights)
  weights = weights or {}
  local combat = weights.combat or 1
  local stealth = weights.stealth or 1
  local magic = weights.magic or 1
  local aggression = util.clamp(combat / math.max(0.05, (combat + stealth + magic) / 3), 0, 2)
  return {
    aggression = aggression,
    -- tolerated danger before preferring to disengage
    engageUpTo = util.clamp(0.3 * aggression, 0.05, 0.9),
  }
end

return M
