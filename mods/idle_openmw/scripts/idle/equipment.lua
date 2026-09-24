-- scripts/idle/equipment.lua
-- Working out which EQUIPMENT_SLOT an item belongs in, from data alone.
--
-- Why this exists: OpenMW's item records expose a NUMERIC `type`, and the
-- numbers do NOT line up with the equipment-slot numbers (armor type 2 is
-- LPauldron, but equipment slot 2 is Greaves). So the only safe route is
--   numeric type -> type NAME (by inverting types.<Kind>.TYPE)
--   type NAME    -> equipment slot NAME (the tables below)
--   slot NAME    -> slot NUMBER (types.Actor.EQUIPMENT_SLOT)
-- Each step is pure, so the whole mapping is unit-testable without the engine.
--
-- Verified sources (see docs/openmw-lua-api.md):
--   types.Armor.TYPE       apps/openmw/mwlua/types/armor.cpp:78
--   types.Clothing.TYPE    apps/openmw/mwlua/types/clothing.cpp:75
--   types.Weapon.TYPE      apps/openmw/mwlua/types/weapon.cpp
--   types.Actor.EQUIPMENT_SLOT  apps/openmw/mwlua/types/actor.cpp:190
--   slot numbering         apps/openmw/mwworld/inventorystore.hpp:33-51

local util = require('scripts.idle.util')

local M = {}

--- type NAME -> equipment slot NAME, per item kind.
M.KIND_SLOT = {
  armor = {
    Helmet = 'Helmet', Cuirass = 'Cuirass', Greaves = 'Greaves',
    LPauldron = 'LeftPauldron', RPauldron = 'RightPauldron',
    LGauntlet = 'LeftGauntlet', RGauntlet = 'RightGauntlet',
    LBracer = 'LeftGauntlet', RBracer = 'RightGauntlet',
    Boots = 'Boots', Shield = 'CarriedLeft',
  },
  clothing = {
    Amulet = 'Amulet', Belt = 'Belt', Robe = 'Robe', Shirt = 'Shirt',
    Pants = 'Pants', Skirt = 'Skirt', Shoes = 'Boots',
    LGlove = 'LeftGauntlet', RGlove = 'RightGauntlet', Ring = 'LeftRing',
  },
  weapon = {
    Arrow = 'Ammunition', Bolt = 'Ammunition',
    Default = 'CarriedRight',
  },
  light = { Default = 'CarriedLeft' },
}

--- Kinds we will equip from the console; everything else falls back to the game's
--- own inventory window (tools like lockpicks/probes are selected, not worn).
M.EQUIPPABLE_KINDS = { armor = true, clothing = true, weapon = true, light = true }

--- The equipment slots in paper-doll order (head to hands to feet). The console's
--- Pack tab draws these around the character as a cheap "portrait": we cannot
--- render the 3D actor, but we can show exactly what is worn where.
M.SLOT_ORDER = {
  'Helmet', 'Amulet', 'Robe', 'Cuirass', 'Shirt',
  'LeftPauldron', 'RightPauldron',
  'LeftGauntlet', 'RightGauntlet',
  'LeftRing', 'RightRing',
  'Belt', 'Pants', 'Skirt',
  'CarriedLeft', 'CarriedRight',
  'Boots', 'Ammunition',
}

--- Human labels for the slots that are not obvious.
M.SLOT_LABEL = {
  LeftPauldron = 'L pauldron', RightPauldron = 'R pauldron',
  LeftGauntlet = 'L gauntlet', RightGauntlet = 'R gauntlet',
  LeftRing = 'L ring', RightRing = 'R ring',
  CarriedLeft = 'Left hand', CarriedRight = 'Right hand',
}

function M.slotLabel(slot) return M.SLOT_LABEL[slot] or slot end

--- Read a paper-doll from a panel inventory: the item worn in each slot, in
--- M.SLOT_ORDER. `items` entries carry { id, count, equipped, equipSlot }.
--- Pure -- the whole doll is unit-tested.
function M.paperDoll(items)
  local worn = {}
  local index = {}
  for i, item in ipairs(items or {}) do
    if util.isObject(item) and item.equipped and item.equipSlot then
      worn[item.equipSlot] = item
      index[item.equipSlot] = i
    end
  end

  local out = {}
  for _, slot in ipairs(M.SLOT_ORDER) do
    out[#out + 1] = {
      slot = slot,
      label = M.slotLabel(slot),
      item = worn[slot],
      index = index[slot],
    }
  end
  return out
end

--- Item kind -> the engine types table that describes it.
M.KIND_TYPE_CLASS = {
  armor = 'Armor', clothing = 'Clothing', weapon = 'Weapon', light = 'Light',
  lockpick = 'Lockpick', probe = 'Probe', repair = 'Repair', apparatus = 'Apparatus',
  potion = 'Potion', ingredient = 'Ingredient', book = 'Book', misc = 'Miscellaneous',
}

function M.isEquippableKind(kind) return M.EQUIPPABLE_KINDS[kind] == true end

--- Invert an engine TYPE table { Name = number } into { number = Name }.
function M.invertTypeTable(typeTable)
  local out = {}
  if type(typeTable) ~= 'table' and type(typeTable) ~= 'userdata' then return out end
  for name, value in pairs(typeTable) do
    if type(name) == 'string' and type(value) == 'number' then out[value] = name end
  end
  return out
end

--- The TYPE table to invert for a given kind (nil when there is none).
function M.typeTableFor(kind, types)
  local className = M.KIND_TYPE_CLASS[kind]
  if not className or not types then return nil end
  local class = types[className]
  return class and class.TYPE or nil
end

--- Determine an item's kind by comparing its type class table against the engine's.
function M.kindOf(objectType, types)
  -- An item's `object.type` is a userdata Type object on the engine, NOT a table, so the old
  -- table-only guard made EVERY item fall through as kind 'other' -- which meant no weapon was
  -- ever recognised as equippable and a character carrying a dagger still reported
  -- fightWith = 'spell'. See AGENTS.md #7 and tests/spec/userdata_spec.lua.
  if not types or not util.isObject(objectType) then return 'other' end
  for kind, className in pairs(M.KIND_TYPE_CLASS) do
    if objectType == types[className] then return kind end
  end
  return 'other'
end

--- The equipment slot NAME for an item kind + type name.
--- @return string|nil
function M.slotFor(kind, typeName)
  local mapping = M.KIND_SLOT[kind]
  if not mapping then return nil end
  if typeName and mapping[typeName] then return mapping[typeName] end
  return mapping.Default or nil
end

--- Full resolution for one item.
--- @param objectType the item's type class table (e.g. types.Weapon)
--- @param record     the item's record (uses `record.type`, a number)
--- @param types      the engine openmw.types module
--- @return { kind, typeName, slot, equippable }
function M.resolve(objectType, record, types)
  local kind = M.kindOf(objectType, types)
  local names = M.invertTypeTable(M.typeTableFor(kind, types))
  local typeName = nil
  if record and type(record.type) == 'number' then typeName = names[record.type] end
  local slot = M.slotFor(kind, typeName)
  return {
    kind = kind,
    typeName = typeName,
    slot = slot,
    equippable = slot ~= nil and M.isEquippableKind(kind),
  }
end

return M
