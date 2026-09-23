-- scripts/idle/schema.lua
-- The data model, declared once. Everything the API can say about the game is described
-- here, and every response is validated against it before it is sent.
--
-- WHY ONE DECLARATION
-- -------------------
-- The Android layer will be written against these field names. If the mod is free to rename
-- `postition` or start returning a number for `distance`, the app breaks at runtime in a way
-- nothing catches. So the field names, types and units live in ONE table, the bridge serves
-- that table from its `schema` method, specs pin it, and `M.validate` re-checks every value
-- on the way out.
--
-- UNITS AND ABSENCES
-- ------------------
-- Numbers are Morrowind's own units (metres-ish for distance, 1..100 for skills, 0..100 for
-- the AI dispositions). `nil` means UNKNOWN, never zero: a field is omitted when the engine
-- could not tell us, and a reader must treat that as "not known" rather than "none".
--
-- PURE. No engine access: the runtime hands in plain values (or engine userdata, which the
-- permissive position check accepts).
--
-- See docs/api-schema.md for the prose version and scripts/idle/bridge.lua for the methods.

local M = {}

--- Bump when a FIELD changes meaning. Adding a new optional field does not need a bump.
M.VERSION = 1

-- ---------------------------------------------------------------------------
-- field types
-- ---------------------------------------------------------------------------

--- Each checker returns true when the value is acceptable for that type.
--- `position` and `vector` deliberately accept engine userdata as well as plain tables:
--- engine values are userdata in 0.51, and demanding a table rejected every real reading
--- once already.
--- True when a value is a plain table with NO engine value anywhere inside it.
---
--- A `map`/`list` used to be `type(v) == 'table'` and nothing more, so an engine STAT WRAPPER
--- nested inside one passed validation and then serialised as the literal string
--- `"<userdata>"`. A host asking for the AI dispositions -- the one field that says how likely an
--- actor is to attack -- received confident nonsense, and nothing complained. Positions are the
--- documented exception: they may BE userdata, since that is how the engine hands them over.
---
--- Declared BEFORE M.TYPE uses it: a local is not in scope until its own statement completes
--- (AGENTS.md #4), and a forward reference here resolves to a nil global instead.
local function noEngineValues(v, depth)
  if type(v) == 'userdata' then return false end
  if type(v) == 'table' then
    if (depth or 0) > 6 then return true end -- deep/shared graphs: do not walk forever
    for _, item in pairs(v) do
      if not noEngineValues(item, (depth or 0) + 1) then return false end
    end
    return true
  end
  return type(v) ~= 'function' and type(v) ~= 'thread'
end

M.TYPE = {
  string = function(v) return type(v) == 'string' end,
  number = function(v) return type(v) == 'number' end,
  integer = function(v)
    return type(v) == 'number' and v == math.floor(v)
  end,
  boolean = function(v) return type(v) == 'boolean' end,
  position = function(v)
    if type(v) == 'table' then
      return type(v.x) == 'number' and type(v.y) == 'number' and type(v.z) == 'number'
    end
    if type(v) == 'userdata' then
      -- a Vector3 from the engine: accepting it is the whole point
      local ok, x = pcall(function() return v.x end)
      return ok and type(x) == 'number'
    end
    return false
  end,
  list = function(v) return noEngineValues(v) end,
  map = function(v) return noEngineValues(v) end,
  any = function() return true end,
}

--- Field constructors, so the tables below read as prose.
--- The recordId warning, in one place: three bandits share one record, so a host that
--- keys anything on recordId has a bug that will only show up with two of them nearby.
local RECORD_ID = 'the record TEMPLATE id -- NOT unique per instance (use id or formId)'

local function field(name, kind, note, options)
  local entry = { name = name, type = kind, note = note }
  for key, value in pairs(options or {}) do entry[key] = value end
  return entry
end

local function required(name, kind, note) return field(name, kind, note, { required = true }) end

-- ---------------------------------------------------------------------------
-- shared field groups
-- ---------------------------------------------------------------------------

--- Identity and place: what every object-backed entity carries.
---
--- `id` is the engine's own per-instance key (core.lua:163, "The unique id of this object
--- (not record id), can be used as a key in a table"). `recordId` is the TEMPLATE (core.lua:177)
--- and is never unique -- three bandits share one. `formId` is the deterministic cross-save
--- address of a placed reference (core.getFormId, core.lua:143-150).
local IDENTITY = {
  required('id', 'string', 'engine GameObject.id: unique per instance, stable as a table key'),
  required('kind', 'string', 'one of M.KINDS'),
  field('formId', 'string', 'core.getFormId(contentFile, index); nil for dynamically created objects'),
  field('recordId', 'string', RECORD_ID),
  field('contentFile', 'string', 'lowercase defining plugin; nil for dynamically created objects'),
  field('name', 'string', 'display name from the record'),
  field('cell', 'string', 'cell name; nil while loading or when inside an inventory/container'),
  field('cellId', 'string', 'cell id (interiors usually), when known'),
  field('position', 'position', 'world position in engine units'),
  field('distance', 'number', 'engine units from the player; nil when either side is unknown'),
  field('vertical', 'string', "'above' | 'below' | 'level' relative to the player's eye"),
  field('enabled', 'boolean', 'false for objects created but not yet placed'),
  -- Which nearby list the row came from ('actors', 'doors', 'items', ...). `entities.nearby`
  -- has always set this (runtime/entities.lua:612) but the schema did not declare it, so the
  -- validator rejected EVERY row of every list -- `entities.nearby` answered
  -- `{"ok":false,"error":"schema violation: actors [1] undeclared field: list"}` and returned
  -- nothing at all, while the raw lists plainly held 41 actors and 26 doors.
  field('list', 'string', "the nearby list this row came from: 'actors', 'doors', 'items', ..."),
}

--- Dynamic pools, as the engine actually models them (types.lua:450-453).
local POOLS = {
  field('health', 'map', 'DynamicStat {base, current, modifier}'),
  field('magicka', 'map', 'DynamicStat {base, current, modifier}'),
  field('fatigue', 'map', 'DynamicStat {base, current, modifier}'),
}

--- AI dispositions. NOT a hostility flag: 0..100 how likely the actor is to fight you
--- (types.lua:506-524). 0.51 has no isInCombat or "hostile" query at all.
local AI = {
  field('alarm', 'number', '0..100 disposition, not a boolean'),
  field('fight', 'number', '0..100 disposition'),
  field('flee', 'number', '0..100 disposition'),
  field('hello', 'number', '0..100 disposition'),
}

--- The eight attributes and twenty-seven skills, as DATA.
---
--- A host building a character sheet needs the canonical names, and hard-coding them in two
--- places is how a typo becomes a missing column. These are the engine's own getter names
--- (types.lua AttributeStats/SkillStats), so they can be used verbatim to ask for a value.
M.ATTRIBUTES = {
  'strength', 'intelligence', 'willpower', 'agility',
  'speed', 'endurance', 'personality', 'luck',
}

M.SKILLS = {
  -- combat
  'block', 'armorer', 'mediumarmor', 'heavyarmor', 'bluntweapon', 'longblade', 'axe', 'spear',
  -- magic
  'destruction', 'alteration', 'illusion', 'conjuration', 'mysticism', 'restoration', 'enchant',
  -- stealth
  'alchemy', 'unarmored', 'security', 'sneak', 'acrobatics', 'lightarmor', 'shortblade',
  'marksman', 'mercantile', 'speechcraft', 'handtohand',
  -- misc
  'athletics',
}

--- Actor KINDS are the shared identity plus these. Composed rather than re-listed: a kind
--- that re-lists its fields is a kind that can silently omit one, which is exactly how
--- actors lost `name` until the response validator caught it.
local ACTOR_EXTRA = {
  field('level', 'integer', 'types.Actor.stats.level'),
  -- DERIVED, not an engine field: Morrowind has no gold stat, money is the item Gold_001,
  -- so this is the total of that item held. nil when it has not been computed.
  field('gold', 'integer', 'DERIVED: total Gold_001 held (Morrowind has no gold stat)'),
  field('dead', 'boolean', 'types.Actor.isDead'),
  field('health', 'map', 'DynamicStat {base, current, modifier}'),
  field('magicka', 'map', 'DynamicStat {base, current, modifier}'),
  field('fatigue', 'map', 'DynamicStat {base, current, modifier}'),
  field('ai', 'map', 'AI dispositions alarm/fight/flee/hello (0..100) -- NOT a hostility flag'),
  field('disposition', 'number', 'NPC.getDisposition against the player; nil for creatures'),
  field('race', 'string', 'npc and player'),
  field('class', 'string', 'npc and player'),
  field('faction', 'string', 'primary faction, when any'),
  field('factionRank', 'integer', 'rank within that faction'),
  field('equipment', 'map', 'slot name -> equipped entity'),
  field('inventory', 'list', 'item stacks held'),
  field('services', 'map', 'servicesOffered: service name -> boolean'),
  field('travelDestinations', 'list', 'travel offers: {cellId, name?, position}'),

  -- THE CHARACTER SHEET. NpcStats carries skills and reputation (types.lua:760-763), and the
  -- player's stats ARE NpcStats, so all of this is available for the character we care about.
  field('attributes', 'map', 'attribute name -> {base, damage, modified, modifier}; names in M.ATTRIBUTES'),
  field('skills', 'map', 'skill name -> {base, damage, modified, modifier, progress}; names in M.SKILLS'),
  field('levelProgress', 'number', 'LevelStat.progress, 0..1 towards the next level'),
  field('reputation', 'number', 'NpcStats.reputation'),
  field('spells', 'list', 'known spells, powers and abilities: {id, type}'),
  field('activeSpells', 'list', 'spells currently affecting the actor: {id, temporary}'),
  field('selectedSpell', 'string', 'the spell readied for casting'),
  field('runSpeed', 'number', 'Actor.getRunSpeed'),
  field('walkSpeed', 'number', 'Actor.getWalkSpeed'),
  field('currentSpeed', 'number', 'Actor.getCurrentSpeed'),
  field('stance', 'string', 'Actor.getStance'),
  field('swimming', 'boolean', 'Actor.isSwimming'),
  field('onGround', 'boolean', 'Actor.isOnGround'),
  field('encumbrance', 'number', 'Actor.getEncumbrance'),
  field('capacity', 'number', 'Actor.getCapacity'),
  field('canMove', 'boolean', 'Actor.canMove'),
  field('factions', 'map', 'faction id -> rank, for every faction the actor belongs to'),
  field('werewolf', 'boolean', 'NPC.isWerewolf -- the one transformation state the engine exposes'),
}

local DOOR_EXTRA = {
  field('destCell', 'string', 'destination cell name, when it leads somewhere'),
  field('destPosition', 'position', 'destination position'),
  field('isTeleport', 'boolean', 'types.Door.isTeleport: a travel link rather than a walk-through'),
  field('locked', 'boolean', 'locked, when the engine will say (nil = unknown)'),
}

local CONTAINER_EXTRA = {
  field('capacity', 'number', 'types.Container.getCapacity'),
  field('inventory', 'list', 'contents as item stacks'),
  field('locked', 'boolean', 'locked, when known'),
}

local ITEM_EXTRA = {
  field('count', 'integer', 'size of the stack'),
  field('weight', 'number', 'per unit'),
  field('value', 'number', 'per unit'),
  field('condition', 'number', 'itemData.condition, when applicable'),
  field('enchantmentCharge', 'number', 'itemData.enchantmentCharge, when applicable'),
  field('soul', 'string', 'captured soul, when applicable'),
}

--- Compose field lists: shared identity first, then the kind's own, with no duplicates.
local function compose(...)
  local out, seen = {}, {}
  for _, group in ipairs({ ... }) do
    for _, entry in ipairs(group) do
      if not seen[entry.name] then
        seen[entry.name] = true
        out[#out + 1] = entry
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- the kinds
-- ---------------------------------------------------------------------------

M.KINDS = {
  player = {
    description = 'The player character. Available in player and global scripts.',
    context = 'player',
    fields = compose(IDENTITY, ACTOR_EXTRA),
  },

  npc = {
    description = 'A humanoid actor. Disposition is a number, never a hostility flag.',
    context = 'global|player|local',
    fields = compose(IDENTITY, ACTOR_EXTRA),
  },

  creature = {
    description = 'A non-humanoid actor. Has no disposition and no class.',
    context = 'global|player|local',
    fields = compose(IDENTITY, ACTOR_EXTRA),
  },

  door = {
    description = 'A door or hatch. Carries the link to its destination cell.',
    context = 'global|player|local',
    fields = compose(IDENTITY, DOOR_EXTRA),
  },

  container = {
    description = 'A chest, crate, corpse or other container.',
    context = 'global|player|local',
    fields = compose(IDENTITY, CONTAINER_EXTRA),
  },

  item = {
    description = 'Anything derived from types.Item: weapon, book, ingredient, gold...',
    context = 'global|player|local',
    fields = compose(IDENTITY, ITEM_EXTRA),
  },

  activator = {
    description = 'A lever, a shrine, a sign -- something you use rather than take.',
    context = 'global|player|local',
    fields = compose(IDENTITY),
  },

  --- Cell METADATA only. Contents are a separate, expensive request: fetching them calls
  --- cell:getAll(), which force-loads the cell (core.lua:337-346, global scripts only).
  cell = {
    description = 'A cell. Metadata is cheap; contents require a deliberate request.',
    context = 'global',
    fields = compose({
      required('id', 'string', 'cell id'),
      required('kind', 'string', "'cell'"),
    }, {
      field('name', 'string', 'cell name'),
      field('displayName', 'string', 'display name, when it differs'),
      field('region', 'string', 'region name; nil for interiors'),
      field('isExterior', 'boolean', 'true for the open world'),
      field('gridX', 'integer', 'exterior only'),
      field('gridY', 'integer', 'exterior only'),
      field('hasWater', 'boolean', ''),
      field('waterLevel', 'number', 'nil when there is none'),
      field('hasSky', 'boolean', ''),
      field('worldSpaceId', 'string', 'nil in most content'),
      field('contentsFetched', 'boolean', 'whether object lists are included in THIS response'),
      field('objects', 'list', 'only present when contentsFetched is true'),
      field('doors', 'list', 'door entities in this cell, when contents are fetched'),
    }),
  },

  --- A record (the template behind instances). Reads are per-type: there is no generic
  --- world.getRecord (types.lua: record accessors per type).
  record = {
    description = 'A record template, read via types.<T>.record or types.<T>.records.',
    context = 'global|player|local',
    fields = compose({
      required('id', 'string', 'record id'),
      required('kind', 'string', "'record'"),
    }, {
      field('recordType', 'string', 'npc | weapon | door | ... the type module it came from'),
      field('name', 'string', 'display name'),
      field('value', 'number', 'item value, when applicable'),
      field('weight', 'number', 'item weight, when applicable'),
      field('fields', 'map', 'the remaining type-specific fields, as read'),
    }),
  },
}

-- ---------------------------------------------------------------------------
-- availability: what this engine cannot tell us
-- ---------------------------------------------------------------------------

--- Declared, so a host sees "unavailable in this engine" rather than an empty result it
--- might mistake for "nothing there". Each entry is a fact about OpenMW 0.51, verified.
M.AVAILABILITY = {
  projectiles = {
    available = false,
    reason = 'No API. 0.51 has no nearby.projectiles, no types.Projectile, and no Projectile '
      .. 'type; the only projectile-related member is the COLLISION_TYPE.Projectile bit used '
      .. 'as a castRay filter (nearby.lua:49,52). A later engine adds an _onProjectileHit '
      .. 'handler, which is a hit event, not an enumeration.',
  },
  aiPackage = {
    available = false,
    reason = 'No read API. 0.51 exposes interfaces.AI.startPackage (to SET a package) but no '
      .. 'getPackage. Current AI behaviour is only inferable from the ai dispositions, '
      .. 'position and movement.',
  },
  hostile = {
    available = false,
    reason = 'No isInCombat and no hostile flag anywhere in the 0.51 API. Proxies instead: '
      .. 'disposition (NPC.getDisposition), the ai fight/flee/alarm/hello dispositions, '
      .. 'isDead, and creature-vs-npc identity.',
  },
  statsOfOthers = {
    available = false,
    reason = 'types.Actor.stats assignment is self-only, so a GLOBAL script cannot set '
      .. 'another actor\'s pools. Use the ModifyStat event, which the actor handles itself.',
  },
  dialogueTopics = {
    available = false,
    reason = 'Dialogue can be OPENED (interfaces.UI.setMode) but no topic can be selected: '
      .. 'the dialogue window callbacks are internal C++ and not bound to Lua.',
  },
  bounty = {
    available = false,
    reason = 'The player\'s bounty is not a readable stat in 0.51. It appears only as'
      .. ' PcCrimeLevel in a DIALOGUE RESPONSE context (core.lua:1268, "The player\'s bounty"),'
      .. ' which is the speaker\'s view during a conversation, not a value we can query.',
  },
  birthsign = {
    available = false,
    reason = 'Not stored as a readable field. It is inferable: Morrowind grants a birthsign as'
      .. ' an ability, so the birthsign shows up in the actor\'s spells list -- look for the'
      .. ' known birthsign ability ids there rather than expecting a birthsign field.',
  },
  playerName = {
    available = false,
    reason = 'The PLAYER has no record, so no name is readable: types.getRecordName(player) is'
      .. ' nil, and there is no Player name accessor in the 0.51 API. A named character can'
      .. ' therefore only come from the save it was created in.',
  },
  cellsInLocal = {
    available = false,
    reason = 'world.cells, cell:getAll() and world.activeActors are global-context only, so '
      .. 'the survey is served by the global script (runtime/warden) and not the player one.',
  },
}

-- ---------------------------------------------------------------------------
-- validation
-- ---------------------------------------------------------------------------

local function fieldByName(kind)
  local lookup = {}
  for _, entry in ipairs(M.KINDS[kind].fields) do lookup[entry.name] = entry end
  return lookup
end

--- Check a value against its kind. Returns `true` or `false, problems`, where problems is a
--- list of human-readable strings -- never throws, because a validator that dies on bad data
--- cannot be used to check bad data.
---
--- Checks three things deliberately:
---   * a declared field whose value has the wrong type (the app would mis-parse it),
---   * a field that is NOT declared (drift: someone added a field without schema),
---   * a missing REQUIRED field (the app cannot even identify the entity).
function M.validate(kind, value)
  local definition = M.KINDS[kind]
  if not definition then return false, { 'unknown kind: ' .. tostring(kind) } end
  if type(value) ~= 'table' then
    return false, { 'expected a table for kind ' .. kind .. ', got ' .. type(value) }
  end

  local lookup = fieldByName(kind)
  local problems = {}

  for _, entry in ipairs(definition.fields) do
    if entry.required and value[entry.name] == nil then
      problems[#problems + 1] = 'missing required field: ' .. entry.name
    end
  end

  for name, fieldValue in pairs(value) do
    local entry = lookup[name]
    if not entry then
      problems[#problems + 1] = 'undeclared field: ' .. tostring(name)
    elseif fieldValue ~= nil then
      local checker = M.TYPE[entry.type]
      if checker and not checker(fieldValue) then
        problems[#problems + 1] = ('field %s should be %s, got %s')
          :format(name, entry.type, type(fieldValue))
      end
    end
  end

  if #problems > 0 then return false, problems end
  return true
end

--- Validate a list of entities of one kind, reporting which index failed.
function M.validateList(kind, list)
  if type(list) ~= 'table' then
    return false, { 'expected a list for kind ' .. kind .. ', got ' .. type(list) }
  end
  local problems = {}
  for index, value in ipairs(list) do
    local ok, issues = M.validate(kind, value)
    if not ok then
      for _, issue in ipairs(issues) do
        problems[#problems + 1] = ('[%d] %s'):format(index, issue)
      end
    end
  end
  if #problems > 0 then return false, problems end
  return true
end

--- The schema as data, for the bridge's `schema` method and the host's codegen.
function M.describe()
  local kinds = {}
  local names = {}
  for kind in pairs(M.KINDS) do names[#names + 1] = kind end
  table.sort(names)                      -- deterministic, so two descriptions are diffable
  for _, kind in ipairs(names) do
    local definition = M.KINDS[kind]
    local fields = {}
    for _, entry in ipairs(definition.fields) do
      fields[#fields + 1] = {
        name = entry.name, type = entry.type, note = entry.note,
        required = entry.required or false,
      }
    end
    kinds[#kinds + 1] = {
      kind = kind, description = definition.description,
      context = definition.context, fields = fields,
    }
  end

  local gaps = {}
  local gapNames = {}
  for name in pairs(M.AVAILABILITY) do gapNames[#gapNames + 1] = name end
  table.sort(gapNames)
  for _, name in ipairs(gapNames) do
    gaps[#gaps + 1] = { name = name, available = M.AVAILABILITY[name].available,
                        reason = M.AVAILABILITY[name].reason }
  end

  return { version = M.VERSION, kinds = kinds, unavailable = gaps }
end

--- The field names for a kind, for callers that build entities.
function M.fieldsOf(kind)
  local definition = M.KINDS[kind]
  if not definition then return nil end
  local names = {}
  for _, entry in ipairs(definition.fields) do names[#names + 1] = entry.name end
  return names
end

return M
