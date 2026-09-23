-- scripts/idle/config.lua
-- All tunables in one place, with validation. Pure (no engine, no I/O) so the
-- whole config surface is unit-tested. The OpenMW layer reads user overrides
-- from `storage.playerSection('IdleOpenMW')` and merges them here.

local util = require('scripts.idle.util')

local M = {}

M.SECTION_NAME = 'IdleOpenMW'

M.defaults = {
  -- version of the config schema; bump when a migration is needed
  version = 1,

  tick = {
    interval = 2.0,   -- simulation seconds between director decisions
    minInterval = 0.5,
    maxInterval = 10.0,
    logLimit = 200,   -- activity-log ring-buffer size
  },

  -- Multipliers applied on top of the class-derived weight vector.
  -- 1.0 = "as the class naturally is".
  weightOverrides = {
    combat = 1.0,
    magic = 1.0,
    stealth = 1.0,
    social = 1.0,
    economy = 1.0,
    train = 1.0,
  },

  thresholds = {
    criticalHealth = 0.25,   -- health fraction below which SURVIVE dominates
    lowHealth = 0.50,
    lowMagicka = 0.20,
    lowFatigue = 0.15,
    encumbranceHigh = 0.85,  -- encumbrance fraction that forces a sell trip
    junkValuePerWeight = 20, -- items below this gold/weight ratio are junk
    keepItemCount = 1,       -- keep at least this many of a valuable item
    minGoldReserve = 100,    -- never spend below this
    restHours = 8,           -- hours per rest action
    trainMinGold = 50,       -- minimum gold to consider training
    fleeHealthFraction = 0.20,
    dangerFlee = 0.70,       -- danger level at which fleeing is preferred
    dangerEngage = 0.35,     -- danger level below which fighting is fine
  },

  -- Relative desirability of each goal, on top of category weights.
  goalBias = {
    survive = 2.0,
    flee = 1.5,
    heal = 1.3,
    rest = 1.0,
    train = 1.0,
    fight = 1.0,
    shop = 1.0,
    sell_junk = 1.1,
    talk = 0.9,
    quest = 1.2,
    explore = 0.6,
    idle = 0.05,
  },

  -- Level scaling: score *= 1 + levelScaling * level. Rewards growth a little.
  levelScaling = 0.02,

  offline = {
    enabled = true,
    maxRealHours = 8,          -- cap catch-up to avoid exploitation
    gameHoursPerRealMinute = 1, -- project plan: 1 real minute == 1 game hour
    goldPerGameHour = 10,
    skillProgressPerGameHour = 2,
    itemsPerGameHour = 0.5,
    riskOccupancy = 0.85,      -- fraction of the window assumed productive
  },

  behaviour = {
    arriveTolerance = 96,      -- engine units; close enough to "arrived"
    repathDistance = 256,      -- re-path when the target drifts this far
    pathCacheTtl = 30,         -- simulation seconds before a cached path expires
    maxPathWaypoints = 64,
    stuckTimeout = 45,         -- sim seconds without progress -> give up on a move
    restWhenFatigued = true,

    -- OpenMW's Lua API exposes no way to drive the barter/rest/training UI
    -- (see docs/openmw-lua-api.md §4). When true, the runtime performs those
    -- actions directly instead -- moving items/gold between inventories with
    -- world.createObject + GameObject:remove, and restoring pools with
    -- types.Actor.stats -- so the idle loop is actually functional.
    -- Set to false to make the mod purely advisory (it will only navigate and
    -- open the relevant UI) if you prefer no "simulated" actions.
    simulateActions = true,
    barterRatio = 0.8,         -- merchant pays this fraction of book value
    trainGoldPerLevel = 20,    -- simulated training cost, per character level

    -- How long a user directive ("go shop", "rest") stays in force, in
    -- simulation seconds, before the director resumes choosing for itself.
    directiveTtl = 120,

    -- Let the director use travel services (silt strider / boat / guild guide)
    -- on its own initiative. OFF by default: it relocates the player without
    -- being asked, and the 1000-hour simulation showed an unbounded travel goal
    -- starves training and trading. The console lists destinations so you can
    -- order a journey deliberately; this only controls the autonomous case.
    autoTravel = false,

    -- Autonomous roaming: when nothing more pressing needs doing, wander the
    -- area instead of standing still. OFF by default (like autoTravel): it moves
    -- the character without being asked. Turn it on from the console's Setup tab
    -- to let the bot explore on its own between orders.
    roam = false,

    -- Goal hysteresis: keep the current goal unless another beats it by this
    -- fraction (0 = off). MEASURED, and DEFAULT OFF because it does not pay:
    -- over the 1000-hour sim a margin of 0.25 cut goal changes 48741 -> 45855
    -- (-6%) and gold 2721 -> 1994 (-27%); 0.6 gave -11% changes / -21% gold. It
    -- entrenches cheap goals instead of cycling on to the profitable ones. Kept
    -- as a tested knob; see docs/observability.md. Emergencies ignore it.
    hysteresis = 0.0,
  },

  -- "Don't let them die at work." Policy is in scripts/idle/guardian.lua; the
  -- acting half lives in scripts/idleWarden.lua, a GLOBAL script, because
  -- GameObject:teleport and menu.loadGame are global-only (docs/openmw-lua-api.md
  -- §10). Detection happens in our PLAYER script and is passed over by event.
  guardian = {
    enabled = true,

    -- Cheating, but the only thing that reliably keeps an unattended run alive:
    -- top the pool up before it can reach zero. Set false for an honest run.
    preventDeath = true,
    criticalHealthFraction = 0.15,   -- intervene at or below this
    retreatHealthFraction = 0.35,    -- stop fighting and withdraw at or below this
    healTo = 0.75,                   -- restored to this fraction of maximum
    cooldown = 30,                   -- sim seconds between interventions (anti-thrash)

    -- What to do if death happens anyway (a one-shot, a trap, a fall).
    --   'respawn' (default) -- teleport back into the last settlement we were
    --                         safe in and revive, then keep playing
    --   'reload'            -- menu.loadGame(saveDir, saveSlot)
    --   'none'              -- do nothing; let the engine do what it does
    onDeath = 'respawn',
    saveSlot = nil,                  -- required for onDeath = 'reload'
    safeHealthFraction = 0.6,        -- only remember a town as "safe" while above this

    -- In MANUAL mode the human is present and the game should behave like
    -- vanilla, death included. Set true to be rescued even while you are driving.
    activeInManual = false,

    -- for onDeath = 'reload': menu.loadGame(directory, slotName) -- both strings
    saveDir = nil,
  },

  sensing = {
    scanRadius = 4096,          -- engine units within which actors are considered

    -- OpenMW exposes NO "is at war with the player" flag (see
    -- docs/openmw-lua-api.md §9), so hostility is a documented heuristic
    -- (scripts/idle/worldsense.lua). Essential actors and anyone offering a
    -- service are never enemies, whatever else says otherwise.
    creaturesAreHostile = true,

    -- NPC hostility is OFF by default, on purpose. The engine's AI Fight
    -- disposition cannot distinguish a town guard (Fight 100) from a bandit
    -- (Fight 95), and a mod that attacks a guard ruins a save irreversibly.
    -- Turn this on to farm bandits; creatures are still handled above.
    npcFightHostility = false,
    hostileFightThreshold = 80,

    -- Record ids that are never hostile, whatever the heuristics say. Use this
    -- to protect a specific NPC you care about.
    ignoreRecords = {},

    -- How strongly a service-less "talker" counts as a quest opportunity.
    questingWeight = 0.6,
  },

  -- Settlements: how the director decides it is in a town, and what it does there.
  settlement = {
    -- Exterior cells whose name contains none of this and is not listed in
    -- wildernessNames are treated as settlements (Morrowind names town cells
    -- plainly: "Balmora", not "Ascadian Isles Region"). See settlement.lua.
    crowdThreshold = 3,        -- friendly people nearby that imply a town

    -- Names that must never count as a settlement, whatever the heuristic says.
    -- The escape hatch for a named cell that is not really a town.
    wildernessNames = {},

    -- Settle in when we arrive: switch to the 'settled' stance so the character
    -- potters about locally instead of wandering off, and tell the player.
    settleOnArrival = true,
    notifyOnArrival = true,

    -- How long a settled stance lasts before the director resumes adventuring,
    -- in simulation seconds. 0 means "until told otherwise", which is what you
    -- want for set-and-forget: it will roam the town all day.
    settledFor = 0,
  },

  debug = {
    verbose = false,
    seed = 1337,
  },

  ui = {
    enabled = true,
    refresh = 0.5,      -- seconds between HUD text refreshes
    -- Safe-area insets in UI units, for the notch / gesture bar in portrait.
    topInset = 24,
    bottomInset = 24,
    textScale = 1.0,
    -- 'manual'  -- you drive; the game's own touch controls are active
    -- 'directive' -- auto-play, but your orders take precedence
    -- 'auto'    -- fully self-playing (default)
    startMode = 'auto',

    -- The console palette (scripts/idle/theme.lua). 'morrowind' uses the game's
    -- own GMST font colours (tan 202,165,96 / parchment 223,201,159 / health red
    -- 200,60,30 …); 'plain' is a high-contrast alternative for a bright screen.
    theme = 'morrowind',

    -- Tap the world to walk there, enter a door, or talk to an NPC. The renderer
    -- forwards the screen point; the runtime raycasts (docs/tap-to-move.md).
    tapToMove = true,
    -- The key that activates things, for the HUD hints. OpenMW's Lua exposes no
    -- action->key lookup (input.getKeyName takes a key code, not an action), so this is the
    -- engine's default rather than something we can read. (local)
    activateKey = 'Space',
    tapReach = 4096,   -- engine units a tap can reach
    -- How many entities the mod remembers so a host can name one in a later request
    -- (scripts/idle/registry.lua). Identity, not state: enough to find the thing again, plus
    -- the place we last saw it. Bounded because the alternative grows forever.
    registryCap = 200,
  },

  -- The idle camera. An isometric lock is possible from Lua alone
  -- (openmw.camera is exposed to PLAYER scripts -- see scripts/idle/camera.lua),
  -- so this is a runtime feature, not an engine patch.
  --
  -- OFF by default: a forced pitch/yaw latches and is not something to spring on
  -- a first run, and the exact angle is a taste that wants a real screen to
  -- judge. Flip `isometric` in the console's Setup tab (or here) to try it.
  camera = {
    isometric = false,
    pitch = -0.6109,    -- radians; ~ -35 deg, the classic 2:1 iso tilt
    distance = 640,     -- third-person distance in engine units
    yaw = nil,          -- radians for a fully-fixed heading; nil = follow the actor
    inManual = false,   -- keep the lock even while the human is driving
  },
}

--- Deep-merge user overrides over the defaults.
function M.new(overrides)
  local cfg = util.merge(M.defaults, overrides)
  return cfg
end

local function clampProblem(problems, path, value, lo, hi)
  if type(value) ~= 'number' then
    problems[#problems + 1] = path .. ' must be a number'
  elseif value < lo or value > hi then
    problems[#problems + 1] = ('%s (%s) out of range [%s, %s]'):format(path, tostring(value), tostring(lo), tostring(hi))
  end
end

--- The parts of `cfg` that differ from the shipped defaults, as a nested table.
--- Persisting only the player's actual changes means later default changes still
--- reach existing saves (which is why the whole config is not just dumped).
function M.overridesOf(cfg)
  local function walk(defaults, values)
    local out = nil
    for key, default in pairs(defaults or {}) do
      -- NOT `(type(values) == 'table') and values[key] or nil`: that idiom turns a
      -- legitimate `false` into `nil`, so "turn this feature off" would never persist.
      local value
      if type(values) == 'table' then value = values[key] end
      if type(default) == 'table' then
        local nested = walk(default, value)
        if nested then
          out = out or {}
          out[key] = nested
        end
      elseif value ~= nil and value ~= default then
        out = out or {}
        out[key] = value
      end
    end
    return out
  end
  return walk(M.defaults, cfg) or {}
end

--- Validate a config in place, clamping where sensible.
--- Returns the config and a list of human-readable problems (empty == clean).
function M.validate(cfg)
  local problems = {}
  if type(cfg) ~= 'table' then
    return M.new(), { 'config must be a table' }
  end

  cfg.tick = cfg.tick or util.deepCopy(M.defaults.tick)
  clampProblem(problems, 'tick.interval', cfg.tick.interval, 0.05, 60)
  cfg.tick.interval = util.clamp(cfg.tick.interval, 0.05, 60)

  cfg.thresholds = cfg.thresholds or util.deepCopy(M.defaults.thresholds)
  for _, key in ipairs({ 'criticalHealth', 'lowHealth', 'lowMagicka', 'lowFatigue',
                         'encumbranceHigh', 'dangerFlee', 'dangerEngage', 'fleeHealthFraction' }) do
    if cfg.thresholds[key] ~= nil then
      clampProblem(problems, 'thresholds.' .. key, cfg.thresholds[key], 0, 1)
      cfg.thresholds[key] = util.clamp(cfg.thresholds[key], 0, 1)
    end
  end

  cfg.offline = cfg.offline or util.deepCopy(M.defaults.offline)
  if cfg.offline.maxRealHours ~= nil then
    clampProblem(problems, 'offline.maxRealHours', cfg.offline.maxRealHours, 0, 24 * 7)
    cfg.offline.maxRealHours = util.clamp(cfg.offline.maxRealHours, 0, 24 * 7)
  end

  cfg.behaviour = cfg.behaviour or util.deepCopy(M.defaults.behaviour)
  if cfg.behaviour.arriveTolerance ~= nil then
    clampProblem(problems, 'behaviour.arriveTolerance', cfg.behaviour.arriveTolerance, 1, 4096)
    cfg.behaviour.arriveTolerance = util.clamp(cfg.behaviour.arriveTolerance, 1, 4096)
  end

  cfg.sensing = cfg.sensing or util.deepCopy(M.defaults.sensing)
  if cfg.sensing.scanRadius ~= nil then
    clampProblem(problems, 'sensing.scanRadius', cfg.sensing.scanRadius, 128, 65536)
    cfg.sensing.scanRadius = util.clamp(cfg.sensing.scanRadius, 128, 65536)
  end
  if cfg.sensing.hostileFightThreshold ~= nil then
    clampProblem(problems, 'sensing.hostileFightThreshold', cfg.sensing.hostileFightThreshold, 0, 100)
    cfg.sensing.hostileFightThreshold = util.clamp(cfg.sensing.hostileFightThreshold, 0, 100)
  end
  if cfg.sensing.questingWeight ~= nil then
    clampProblem(problems, 'sensing.questingWeight', cfg.sensing.questingWeight, 0, 1)
    cfg.sensing.questingWeight = util.clamp(cfg.sensing.questingWeight, 0, 1)
  end

  cfg.camera = cfg.camera or util.deepCopy(M.defaults.camera)
  if cfg.camera.pitch ~= nil then
    clampProblem(problems, 'camera.pitch', cfg.camera.pitch, -1.5707, 1.5707)
    cfg.camera.pitch = util.clamp(cfg.camera.pitch, -1.5707, 1.5707)
  end
  if cfg.camera.distance ~= nil then
    clampProblem(problems, 'camera.distance', cfg.camera.distance, 64, 8192)
    cfg.camera.distance = util.clamp(cfg.camera.distance, 64, 8192)
  end

  cfg.weightOverrides = cfg.weightOverrides or util.deepCopy(M.defaults.weightOverrides)
  if cfg.behaviour and cfg.behaviour.hysteresis ~= nil then
    clampProblem(problems, 'behaviour.hysteresis', cfg.behaviour.hysteresis, 0, 5)
    cfg.behaviour.hysteresis = util.clamp(cfg.behaviour.hysteresis, 0, 5)
  end
  for key, value in pairs(cfg.weightOverrides) do
    if type(value) ~= 'number' or value < 0 then
      problems[#problems + 1] = 'weightOverrides.' .. tostring(key) .. ' must be a non-negative number'
      cfg.weightOverrides[key] = 1.0
    end
  end

  return cfg, problems
end

return M
