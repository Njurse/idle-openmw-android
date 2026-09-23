describe('runtime.openmw adapter', function()
  local mocks = require('tests.mocks.openmw')
  local observer = require('scripts.runtime.observer')
  local executorMod = require('scripts.runtime.executor')
  local configMod = require('scripts.idle.config')
  local statCrunch = require('scripts.idle.statCrunch')
  local directorMod = require('scripts.idle.director')
  local worldsense = require('scripts.idle.worldsense')

  local cfg = configMod.new()

  local function withEnv(spec, fn)
    local env = mocks.install(spec)
    local ok, err = pcall(fn, env)
    mocks.uninstall()
    if not ok then error(err, 0) end
  end

  --- The economy requests the executor sent to the GLOBAL warden this run.
  --- A player script cannot remove items or create gold (openmw.world is global-only and
  --- GameObject:remove/moveInto are GObject-only), so the request IS the observable effect.
  local function economyEvents(env)
    local out = {}
    for _, event in ipairs(env._globalEvents or {}) do
      if event.name == 'IdleOpenMW_Economy' then out[#out + 1] = event.data end
    end
    return out
  end

  local function findEconomy(env, op)
    for _, data in ipairs(economyEvents(env)) do
      if data.op == op then return data end
    end
    return nil
  end

  local WARRIOR_SPEC = {
    classId = 'warrior',
    recordId = 'player',
    level = 5,
    position = { x = 0, y = 0, z = 0 },
    rotation = 0,
    cell = { name = 'Balmora', isExterior = true },
    gold = 300,
    capacity = 400,
    health = { current = 120, base = 120 },
    magicka = { current = 40, base = 40 },
    fatigue = { current = 140, base = 140 },
    skills = { longblade = 64, heavyarmor = 58, block = 52, armorer = 41, athletics = 46 },
    attributes = { strength = 62, endurance = 58, agility = 42 },
    inventory = {
      { id = 'longsword', count = 1, value = 100, weight = 15, equipped = true },
      { id = 'chitin dagger', count = 5, value = 8, weight = 4 },
    },
  }

  describe('engine facade', function()
    it('resolves mocked engine modules', function()
      withEnv({}, function(env)
        local engine = require('scripts.runtime.engine')
        assert.equals(engine.types(), env.types)
        assert.equals(engine.self(), env.self)
        assert.equals(engine.nearby(), env.nearby)
        assert.is_not_nil(engine.playerStorage('IdleOpenMW'))
        assert.is_not_nil(engine.wallClock()) -- os.time exists in the host Lua
      end)
    end)
  end)

  describe('observer.readPlayer', function()
    it('reads the documented stat surface', function()
      withEnv(WARRIOR_SPEC, function(env)
        local player = observer.readPlayer(env, {})
        assert.equals(player.level, 5)
        assert.equals(player.health.current, 120)
        assert.equals(player.health.base, 120)
        assert.equals(player.magicka.base, 40)
        assert.equals(player.fatigue.current, 140)
        assert.equals(player.gold, 300)
        assert.equals(player.position.x, 0)
        assert.equals(player.yaw, 0)
        assert.equals(player.cell.name, 'Balmora')
        assert.equals(player.skills.longblade.modified, 64)
        assert.equals(player.attributes.strength.base, 62)
        assert.equals(player.encumbrance.max, 400)
      end)
    end)

    it('sorts inventory deterministically and marks equipment', function()
      withEnv(WARRIOR_SPEC, function(env)
        local player = observer.readPlayer(env, {})
        assert.equals(player.inventory[1].id, 'chitin dagger')
        assert.equals(player.inventory[2].id, 'longsword')
        assert.is_true(player.inventory[2].equipped)
        assert.is_false(player.inventory[1].equipped)
        -- carried weight = 5*4 + 1*15
        assert.equals(player.encumbrance.current, 35)
      end)
    end)

    it('resolves the class from the NPC record', function()
      withEnv(WARRIOR_SPEC, function(env)
        local class = observer.readClass(env, env.self.object)
        assert.equals(class.id, 'warrior')
        assert.equals(class.specialization, 'combat')
        assert.is_true(#class.majorSkills > 0)
      end)
    end)

    it('defaults missing stats instead of throwing', function()
      withEnv({}, function(env)
        local player = observer.readPlayer(env, {})
        assert.equals(player.level, 1)
        assert.is_true(player.health.current >= 0)
        assert.equals(player.gold, 0)
      end)
    end)
  end)

  describe('observer.scanWorld', function()
    it('reads the real servicesOffered record into opportunities', function()
      withEnv({
        position = { x = 0, y = 0, z = 0 },
        cell = { name = 'Balmora', isExterior = true },
        actors = {
          { recordId = 'arrille', position = { x = 100, y = 0, z = 0 },
            servicesOffered = { Barter = true, Misc = true } },
          { recordId = 'trainer', position = { x = 2000, y = 0, z = 0 },
            servicesOffered = { Training = true } },
        },
      }, function(env)
        local player = observer.readPlayer(env, {})
        local world = observer.scanWorld(env, { cfg = cfg, capability = {} }, player)
        assert.is_true(world.opportunities.shop > 0.9)        -- 100/4096 away
        assert.is_true(world.opportunities.trainer > 0)
        assert.is_true(world.opportunities.shop > world.opportunities.trainer)
        assert.equals(world.nearest.shop.name, 'arrille')
        assert.equals(world.opportunities.talk > 0, true)
        -- both are friendly: a merchant must never be classified as an enemy
        assert.equals(world.enemies, 0)
      end)
    end)

    it('treats creatures as enemies and records their level', function()
      withEnv({
        position = { x = 0, y = 0, z = 0 },
        actors = {
          { recordId = 'rat', position = { x = 50, y = 0, z = 0 }, level = 2, creature = true },
          { recordId = 'dremora', position = { x = 60, y = 0, z = 0 }, level = 40, creature = true },
        },
      }, function(env)
        local player = observer.readPlayer(env, {})
        local weak = { combat = 0.5, magic = 0.1 }
        local world = observer.scanWorld(env, { cfg = cfg, capability = weak }, player)
        assert.equals(world.enemies, 2)
        assert.equals(world.nearest.enemy.name, 'rat')
        assert.equals(world.enemies_nearby[2].level, 40)
        assert.is_true(world.danger > 0)
      end)
    end)

    it('leaves NPCs alone by default, even belligerent ones', function()
      withEnv({
        position = { x = 0, y = 0, z = 0 },
        actors = {
          { recordId = 'bandit', position = { x = 100, y = 0, z = 0 }, fight = 95 },
          { recordId = 'guard', position = { x = 100, y = 0, z = 0 }, fight = 100 },
        },
      }, function(env)
        local player = observer.readPlayer(env, {})
        local world = observer.scanWorld(env, { cfg = cfg, capability = {} }, player)
        assert.equals(world.enemies, 0)
      end)
    end)

    it('turns aggressive NPCs hostile when opted in, sparing merchants', function()
      local aggressive = configMod.new({ sensing = { npcFightHostility = true } })
      withEnv({
        position = { x = 0, y = 0, z = 0 },
        actors = {
          { recordId = 'bandit', position = { x = 100, y = 0, z = 0 }, fight = 95 },
          { recordId = 'townsfolk', position = { x = 100, y = 0, z = 0 }, fight = 30 },
          { recordId = 'merchant', position = { x = 100, y = 0, z = 0 }, fight = 100,
            servicesOffered = { Barter = true } },
        },
      }, function(env)
        local player = observer.readPlayer(env, {})
        local world = observer.scanWorld(env, { cfg = aggressive, capability = {} }, player)
        assert.equals(world.enemies, 1)
        assert.equals(world.enemies_nearby[1].name, 'bandit')
      end)
    end)

    it('never treats an essential actor as an enemy', function()
      withEnv({
        position = { x = 0, y = 0, z = 0 },
        actors = { { recordId = 'caius', position = { x = 10, y = 0, z = 0 }, fight = 100, isEssential = true } },
      }, function(env)
        local player = observer.readPlayer(env, {})
        local world = observer.scanWorld(env, { cfg = cfg, capability = {} }, player)
        assert.equals(world.enemies, 0)
      end)
    end)

    it('surfaces travel services and their destinations', function()
      withEnv({
        position = { x = 0, y = 0, z = 0 },
        actors = {
          { recordId = 'silt strider', position = { x = 300, y = 0, z = 0 },
            travelDestinations = { { cell = 'Balmora' }, { cell = 'Seyda Neen' } } },
        },
      }, function(env)
        local player = observer.readPlayer(env, {})
        local world = observer.scanWorld(env, { cfg = cfg, capability = {} }, player)
        assert.is_true(world.opportunities.travel > 0)
        assert.equals(world.nearest.travel.name, 'silt strider')
        local destinations = worldsense.destinationsOf(world.nearest.travel)
        assert.equals(#destinations, 2)
        assert.equals(destinations[2].cell, 'Seyda Neen')
      end)
    end)

    it('only rests indoors', function()
      withEnv({ cell = { name = 'Balmora', isExterior = true } }, function(env)
        local player = observer.readPlayer(env, {})
        local outside = observer.scanWorld(env, { cfg = cfg }, player)
        assert.is_true(outside.opportunities.rest <= 0.2)

        env.self.cell.isExterior = false
        local inside = observer.scanWorld(env, { cfg = cfg }, observer.readPlayer(env, {}))
        assert.is_true(inside.opportunities.rest > outside.opportunities.rest)
      end)
    end)

    it('uses visited-cell memory for exploration', function()
      withEnv({ cell = { name = 'Balmora', isExterior = false } }, function(env)
        local player = observer.readPlayer(env, {})
        local fresh = observer.scanWorld(env, { cfg = cfg, visitedCells = { Balmora = true } }, player)
        local unknown = observer.scanWorld(env, { cfg = cfg, visitedCells = {} }, player)
        assert.is_true(unknown.opportunities.unexplored > fresh.opportunities.unexplored)
      end)
    end)
  end)

  describe('observer.build', function()
    it('produces a snapshot the director can consume', function()
      withEnv(WARRIOR_SPEC, function(env)
        local snapshot = observer.build(env, { cfg = cfg })
        assert.is_not_nil(snapshot.player)
        assert.is_not_nil(snapshot.world)
        assert.equals(snapshot.player.gold, 300)
        local director = directorMod.new({ classDef = observer.readClass(env, env.self.object), config = cfg })
        local result = director:tick(0.1, snapshot)
        assert.is_not_nil(result.goal)
        assert.is_table(result.commands)
      end)
    end)
  end)

  describe('executor', function()
    local function newExecutor(env, opts)
      return executorMod.new(env, cfg, opts or {})
    end

    it('moves toward a blocking move command and steers controls', function()
      withEnv({ position = { x = 0, y = 0, z = 0 }, rotation = 0 }, function(env)
        local ex = newExecutor(env, { nav = mocks.nav(50) })
        ex:submit({ { type = 'move', dest = { x = 0, y = 300, z = 0 }, run = true } })
        ex:update(0.1, 0)
        assert.is_true(ex:isMoving())
        assert.equals(env.self.controls.movement, 1) -- already facing north
        assert.is_true(env.self.controls.run)
      end)
    end)

    it('stops steering once it arrives', function()
      withEnv({ position = { x = 0, y = 0, z = 0 } }, function(env)
        local ex = newExecutor(env, { nav = mocks.nav(50) })
        ex:submit({ { type = 'move', dest = { x = 0, y = 100, z = 0 } } })
        ex:update(0.1, 0)
        env.self.position.y = 100
        ex:update(0.1, 0.2)
        assert.is_false(ex:isMoving())
        assert.equals(ex:pending(), 0)
        assert.equals(env.self.controls.movement, 0)
      end)
    end)

    it('reports a failure when there is no route', function()
      withEnv({ position = { x = 0, y = 0, z = 0 } }, function(env)
        local ex = newExecutor(env, { nav = mocks.nav(50, true) })
        ex:submit({ { type = 'move', dest = { x = 0, y = 300, z = 0 } } })
        ex:update(0.1, 0)
        assert.is_false(ex:isMoving())
        assert.is_true(#ex.actions > 0)
      end)
    end)

    it('activates a target object', function()
      withEnv(WARRIOR_SPEC, function(env)
        local ex = newExecutor(env)
        -- note: `npc` must be declared before the closure, or the inner
        -- reference would resolve to a (nil) global and pcall would hide it
        local npc = {}
        npc.activateBy = function() npc.activated = true end
        ex:submit({ { type = 'activate', kind = 'shop', target = { object = npc } } })
        ex:update(0, 0)
        assert.is_true(npc.activated)
      end)
    end)

    it('opens a door it is about to walk into', function()
      -- A path can route THROUGH a door (the navmesh default includes OpenDoor) but the actor
      -- still has to OPEN it; without this the actor walks into a closed door and only the stuck
      -- timer gives up, which is why "leave the shop" could never work.
      local door = { id = 'd1', position = { x = 0, y = 60, z = 0 } }
      local spec = {
        classId = 'warrior', recordId = 'player', level = 5,
        position = { x = 0, y = 0, z = 0 }, rotation = 0,
        cell = { name = 'Balmora', isExterior = true },
        health = { current = 120, base = 120 },
        doors = { door },
      }
      withEnv(spec, function(env)
        local ex = newExecutor(env, { nav = mocks.nav(50) })
        ex:submit({ { type = 'move', dest = { x = 0, y = 300, z = 0 } } })
        ex:update(0.1, 0)
        assert.is_true(ex:isMoving())
        assert.equals(door.activated, 1)
      end)
    end)

    it('sells junk by asking the warden to move the items and the gold', function()
      withEnv(WARRIOR_SPEC, function(env)
        local ex = newExecutor(env)
        ex:submit({ { type = 'sell', plan = { { id = 'chitin dagger', count = 5, unitValue = 8 } } } })
        ex:update(0, 0)
        -- a PLAYER script cannot remove items or create gold: world is global-only and
        -- GameObject:remove/moveInto are GObject-only (objectbindings.cpp:399-400)
        local take = findEconomy(env, 'take')
        assert.is_true(take ~= nil)
        assert.equals('chitin dagger', take.recordId)
        assert.equals(5, take.count)
        local gold = findEconomy(env, 'gold')
        assert.is_true(gold ~= nil)
        -- 5 * 8 * 0.8 barter ratio
        assert.equals(32, gold.amount)
        assert.equals(ex.applied.sales, 1)
      end)
    end)

    it('buys supplies by asking the warden for the gold and the goods', function()
      withEnv(WARRIOR_SPEC, function(env)
        local ex = newExecutor(env)
        ex:submit({ { type = 'buy', plan = { { id = 'cure potion', count = 2, unitValue = 50 } } } })
        ex:update(0, 0)
        local take = findEconomy(env, 'take')
        assert.is_true(take ~= nil)
        assert.equals('gold_001', take.recordId)
        assert.equals(100, take.count)
        local give = findEconomy(env, 'give')
        assert.is_true(give ~= nil)
        assert.equals('cure potion', give.recordId)
        assert.equals(2, give.count)
        assert.equals(ex.applied.purchases, 1)
      end)
    end)

    it('restores pools when resting', function()
      withEnv({ health = { current = 10, base = 100 }, fatigue = { current = 5, base = 100 } }, function(env)
        local ex = newExecutor(env)
        ex:submit({ { type = 'rest', hours = 8 } })
        ex:update(0, 0)
        assert.equals(env.types.Actor.stats.dynamic.health(env.self.object).current, 100)
        assert.equals(env.types.Actor.stats.dynamic.fatigue(env.self.object).current, 100)
        assert.equals(ex.applied.rests, 1)
      end)
    end)

    it('advances a trained skill', function()
      withEnv(WARRIOR_SPEC, function(env)
        local ex = newExecutor(env)
        ex:submit({ { type = 'train', skill = 'armorer' } })
        ex:update(0, 0)
        assert.is_true(env.types.NPC.stats.skills.armorer(env.self.object).progress > 0)
        assert.equals(ex.applied.trains, 1)
      end)
    end)

    it('queues a move for wander', function()
      withEnv({ position = { x = 0, y = 0, z = 0 } }, function(env)
        local ex = newExecutor(env, { nav = mocks.nav(50) })
        ex:submit({ { type = 'wander', radius = 1000 } })
        ex:update(0.1, 0)
        assert.is_true(ex:isMoving())
      end)
    end)

    it('is purely advisory when simulated actions are disabled', function()
      withEnv(WARRIOR_SPEC, function(env)
        local advisory = configMod.new({ behaviour = { simulateActions = false } })
        local ex = executorMod.new(env, advisory, {})
        local inventory = env.types.Actor.inventory(env.self.object)
        local before = inventory:countOf('gold_001')
        ex:submit({ { type = 'sell', plan = { { id = 'chitin dagger', count = 5, unitValue = 8 } } } })
        ex:update(0, 0)
        assert.equals(inventory:countOf('gold_001'), before)
        assert.is_true(ex.actions[#ex.actions].level == 'warn')
      end)
    end)

    it('runs a full decision -> execution cycle', function()
      withEnv({
        classId = 'warrior', position = { x = 0, y = 0, z = 0 }, rotation = 0,
        cell = { name = 'Balmora', isExterior = true }, gold = 300,
        skills = { longblade = 64 },
        actors = {
          { recordId = 'arrille', position = { x = 200, y = 0, z = 0 }, servicesOffered = { Barter = true } },
        },
      }, function(env)
        local classDef = observer.readClass(env, env.self.object)
        local snapshot = observer.build(env, { cfg = cfg })
        local capability = statCrunch.compute(snapshot.player, classDef).capability
        local director = directorMod.new({ classDef = classDef, config = cfg })
        local ex = newExecutor(env, { nav = mocks.nav(50) })

        local result = director:tick(0.1, snapshot)
        -- the director must emit at least one command for every goal
        assert.is_true(#result.commands >= 1)
        ex:submit(result.commands)
        ex:update(0.1, 0)
        assert.is_not_nil(capability.combat)
      end)
    end)
  end)

  describe('observer.readPanel', function()
    local PANEL_SPEC = {
      classId = 'warrior',
      level = 7,
      gold = 900,
      capacity = 300,
      position = { x = 0, y = 0, z = 0 },
      cell = { name = 'Balmora', isExterior = true },
      inventory = {
        { id = 'cuirass', count = 1, value = 300, weight = 40, class = 'Armor', recordType = 1 },
        { id = 'chitin dagger', count = 5, value = 8, weight = 4, class = 'Weapon', recordType = 0 },
        { id = 'lockpick', count = 12, value = 5, weight = 0.1, class = 'Lockpick' },
        { id = 'healing potion', count = 3, value = 25, weight = 0.5, class = 'Potion' },
      },
      journal = { { text = 'You arrived in Balmora.', questId = 'q1', day = 3 } },
      quests = {
        q1 = { id = 'q1', stage = 5, started = true, finished = false },
        q2 = { id = 'q2', stage = 90, started = true, finished = true },
      },
    }

    it('reports the player summary', function()
      withEnv(PANEL_SPEC, function(env)
        local panel = observer.readPanel(env, { cfg = cfg })
        assert.equals(panel.player.gold, 900)
        assert.equals(panel.player.level, 7)
        assert.equals(panel.player.encumbrance.max, 300)
        assert.equals(panel.player.cell.name, 'Balmora')
      end)
    end)

    it('annotates items for the pack tab', function()
      withEnv(PANEL_SPEC, function(env)
        local panel = observer.readPanel(env, { cfg = cfg })
        local byId = {}
        for _, item in ipairs(panel.inventory) do byId[item.id] = item end

        assert.equals(byId.cuirass.equipSlot, 'Cuirass')
        assert.is_true(byId.cuirass.junk)          -- 7.5 gold/weight
        assert.is_true(byId['chitin dagger'].junk) -- 2.0 gold/weight
        assert.is_false(byId.lockpick.junk)        -- 50 gold/weight, and a tool
        assert.is_false(byId['healing potion'].junk)
        assert.equals(byId.lockpick.valuePerWeight, 50)
      end)
    end)

    it('reads the journal and only unfinished quests', function()
      withEnv(PANEL_SPEC, function(env)
        local panel = observer.readPanel(env, { cfg = cfg })
        assert.equals(#panel.journal, 1)
        assert.equals(panel.journal[1].questId, 'q1')
        assert.equals(#panel.quests, 1)
        assert.equals(panel.quests[1].id, 'q1')
      end)
    end)

    it('degrades gracefully with no Player type', function()
      withEnv({}, function(env)
        env.types.Player = nil
        local panel = observer.readPanel(env, {})
        expect(panel.journal):toEqualDeep({})
        expect(panel.quests):toEqualDeep({})
        expect(panel.journalTopics):toEqualDeep({})
      end)
    end)

    it('reads the unlocked dialogue topics, sorted, with line counts', function()
      withEnv({
        journalTopics = {
          Background = { entries = { 'a', 'b', 'c' } },
          ['my trade'] = { entries = {} },
          Vivec = { entries = { 'x' } },
        },
      }, function(env)
        local panel = observer.readPanel(env, {})
        assert.equals(#panel.journalTopics, 3)
        assert.equals(panel.journalTopics[1].topic, 'Background')
        assert.equals(panel.journalTopics[1].lines, 3)
        assert.equals(panel.journalTopics[2].topic, 'Vivec')
        assert.equals(panel.journalTopics[3].topic, 'my trade')
        assert.equals(panel.journalTopics[3].lines, 0)
      end)
    end)
  end)

  describe('executor actions', function()
    local ACTION_SPEC = {
      classId = 'warrior',
      position = { x = 0, y = 0, z = 0 },
      gold = 500,
      inventory = {
        { id = 'cuirass', count = 1, value = 300, weight = 40, class = 'Armor', recordType = 1 },
        { id = 'chitin dagger', count = 5, value = 8, weight = 4, class = 'Weapon', recordType = 0 },
        { id = 'lockpick', count = 12, value = 5, weight = 0.1, class = 'Lockpick' },
      },
    }

    it('equips armour into the slot the type mapping chose', function()
      withEnv(ACTION_SPEC, function(env)
        local ex = executorMod.new(env, cfg, {})
        local ok = ex:equip('cuirass')
        assert.is_true(ok)
        assert.equals(#env._equipCalls, 1)
        local slots = env.types.Actor.EQUIPMENT_SLOT
        assert.equals(env._equipmentBySlot()[slots.Cuirass], 'cuirass')
        assert.equals(ex.applied.equips, 1)
      end)
    end)

    it('refuses to guess for tools, and says why', function()
      withEnv(ACTION_SPEC, function(env)
        local ex = executorMod.new(env, cfg, {})
        local ok, message = ex:equip('lockpick')
        assert.is_false(ok)
        assert.is_true(tostring(message):find('inventory window', 1, true) ~= nil)
        assert.equals(#env._equipCalls, 0)
      end)
    end)

    it('reports an item that is not carried', function()
      withEnv(ACTION_SPEC, function(env)
        local ex = executorMod.new(env, cfg, {})
        local ok, message = ex:equip('nothing')
        assert.is_false(ok)
        assert.is_true(tostring(message):find('not carried', 1, true) ~= nil)
      end)
    end)

    it('survives the engine refusing to equip', function()
      withEnv({
        inventory = { { id = 'cuirass', count = 1, value = 300, weight = 40, class = 'Armor', recordType = 1 } },
        refuseEquip = true,
      }, function(env)
        local ex = executorMod.new(env, cfg, {})
        local ok, message = ex:equip('cuirass')
        assert.is_false(ok)
        assert.is_true(tostring(message):find('refused', 1, true) ~= nil)
      end)
    end)

    it('sells one stack by asking the warden to move it and pay for it', function()
      withEnv(ACTION_SPEC, function(env)
        local ex = executorMod.new(env, cfg, {})
        local gold = ex:sellOne('chitin dagger', 5)
        -- the return is the REQUESTED price; the engine applies the move on the next tick, and
        -- the warden reports back (IdleOpenMW_EconomyApplied)
        assert.equals(gold, 32)
        assert.equals('chitin dagger', findEconomy(env, 'take').recordId)
        assert.equals(5, findEconomy(env, 'take').count)
        assert.equals(32, findEconomy(env, 'gold').amount)
      end)
    end)

    it('drops items by asking the warden to take them out', function()
      withEnv(ACTION_SPEC, function(env)
        local ex = executorMod.new(env, cfg, {})
        assert.is_true(ex:dropOne('lockpick', 4))
        assert.equals('lockpick', findEconomy(env, 'take').recordId)
        assert.equals(4, findEconomy(env, 'take').count)
      end)
    end)

    it('is advisory only when simulated actions are off', function()
      withEnv(ACTION_SPEC, function(env)
        local advisory = configMod.new({ behaviour = { simulateActions = false } })
        local ex = executorMod.new(env, advisory, {})
        local inventory = env.types.Actor.inventory(env.self.object)
        assert.equals(ex:sellOne('chitin dagger', 5), 0)
        assert.equals(inventory:countOf('chitin dagger'), 5)
      end)
    end)
  end)
end)
