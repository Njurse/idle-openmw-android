describe('idle.director', function()
  local directorMod = require('scripts.idle.director')
  local configMod = require('scripts.idle.config')
  local util = require('scripts.idle.util')
  local classes = require('tests.fixtures.classes')
  local states = require('tests.fixtures.states')
  local worlds = require('tests.fixtures.worlds')

  local cfg = configMod.new()

  local function snapshot(state, world) return { player = state, world = world } end

  local function newDirector(opts)
    return directorMod.new(util.merge({ classDef = classes.warrior }, opts or {}))
  end

  local function view(state, classDef)
    return require('scripts.idle.statCrunch').compute(state, classDef or classes.warrior)
  end

  describe('construction', function()
    it('derives preference weights from the class', function()
      local d = newDirector()
      assert.is_not_nil(d.weights)
      assert.is_true(d.weights.combat > d.weights.economy)
    end)

    it('falls back to neutral weights without a class', function()
      local d = directorMod.new({})
      assert.is_true(d.weights.combat > 0)
      assert.is_true(d.weights.social > 0)
    end)

    it('re-derives weights when the class changes', function()
      local d = newDirector()
      local warriorCombat = d.weights.combat
      d:setClass(classes.mage)
      assert.is_true(d.weights.magic > d.weights.combat)  -- the mage is magic-dominant
      assert.is_true(d.weights.combat < warriorCombat)    -- and less combat-oriented than the warrior
    end)
  end)

  describe('tick', function()
    it('returns a goal, commands and status', function()
      local d = newDirector()
      local result = d:tick(0.1, snapshot(states.warrior(), worlds.town()))
      assert.is_not_nil(result.goal)
      assert.is_table(result.commands)
      assert.is_true(#result.commands >= 1)
      assert.equals(result.status.goal, result.goal)
    end)

    it('chooses survive and plans healing when health is critical', function()
      local d = newDirector()
      local state = states.warrior({ health = { current = 5, base = 120, max = 120 }, position = { x = 0, y = 0, z = 0 } })
      local result = d:tick(0.1, snapshot(state, worlds.town()))
      assert.equals(result.goal, 'survive')
      -- no healer in town fixture -> potion + wait
      assert.equals(result.commands[1].type, 'useItem')
    end)

    it('walks to a healer when one is nearby', function()
      local d = newDirector()
      local state = states.warrior({ health = { current = 5, base = 120, max = 120 }, position = { x = 0, y = 0, z = 0 } })
      local world = worlds.town()
      world.nearest.healer = { name = 'Healer', position = { x = 120, y = 0, z = 0 }, distance = 120 }
      local result = d:tick(0.1, snapshot(state, world))
      assert.equals(result.goal, 'survive')
      assert.equals(result.commands[1].type, 'move')
      assert.equals(result.commands[2].type, 'activate')
      assert.equals(result.commands[2].kind, 'healer')
    end)

    it('flees away from the nearest threat', function()
      local d = newDirector()
      local state = states.warrior({ position = { x = 0, y = 0, z = 0 } })
      local result = d:tick(0.1, snapshot(state, worlds.dangerous()))
      assert.equals(result.goal, 'flee')
      assert.equals(result.commands[1].type, 'flee')
      assert.is_not_nil(result.commands[1].dest)
    end)

    it('logs the goal change', function()
      local d = newDirector()
      d:tick(0.1, snapshot(states.warrior(), worlds.town()))
      assert.equals(d.log:count(), 1)
      assert.is_true(d.log:lastMessage():find('→', 1, true) ~= nil)
    end)

    it('throttles re-decisions but always reacts to emergencies', function()
      local d = newDirector()
      local healthy = states.warrior({ position = { x = 0, y = 0, z = 0 } })
      local world = worlds.town()
      d:tick(0.1, snapshot(healthy, world))
      assert.equals(d.counters.goalChanges, 1)

      -- still healthy, tiny dt: the goal must not be re-decided
      d:tick(0.01, snapshot(healthy, world))
      assert.equals(d.counters.goalChanges, 1)

      -- emergency overrides the throttle
      local dying = states.warrior({ health = { current = 3, base = 120, max = 120 }, position = { x = 0, y = 0, z = 0 } })
      local result = d:tick(0.01, snapshot(dying, world))
      assert.equals(result.goal, 'survive')
      assert.equals(d.counters.goalChanges, 2)
    end)

    it('is deterministic for the same inputs', function()
      local a, b = newDirector(), newDirector()
      local snap = snapshot(states.warrior(), worlds.town())
      local ra = a:tick(0.1, snap)
      local rb = b:tick(0.1, snap)
      assert.equals(ra.goal, rb.goal)
    end)

    it('tolerates an empty snapshot', function()
      local d = newDirector()
      local result = d:tick(0.1, {})
      assert.equals(result.goal, 'idle')
      assert.equals(result.commands[1].type, 'stop')
    end)
  end)

  describe('planCommands', function()
    local ctx = { classDef = classes.warrior }

    local function plan(goalId, world, state)
      state = state or states.warrior({ position = { x = 0, y = 0, z = 0 } })
      return directorMod.planCommands(goalId, view(state), world, snapshot(state, world), cfg, ctx)
    end

    it('walks into reach of the nearest enemy and attacks it', function()
      -- An attack at a creature thousands of units away is a goal that cannot act wearing a
      -- command: the character stands still and swings at air (measured live in Seyda Neen).
      local commands = plan('fight', worlds.wilderness())
      assert.equals(#commands, 2)
      assert.equals(commands[1].type, 'move')
      assert.equals(commands[1].dest.x, 60)
      assert.equals(commands[2].type, 'activate')
      assert.equals(commands[2].kind, 'attack')
      assert.equals(commands[2].target.name, 'Rat')
    end)

    it('plans nothing for fight when the character has nothing to DRAW', function()
      -- `attack` does NOTHING with the hands empty, so fight is a goal that cannot act; emitting
      -- nothing is what lets Director:tick hand over to a goal that can.
      local unarmed = states.warrior({ position = { x = 0, y = 0, z = 0 } })
      unarmed.canFight = false
      assert.equals(#plan('fight', worlds.wilderness(), unarmed), 0)

      local armed = states.warrior({ position = { x = 0, y = 0, z = 0 } })
      armed.canFight = true
      assert.is_true(#plan('fight', worlds.wilderness(), armed) > 0)
    end)

    it('plans nothing for a goal whose target is absent, so tick can fall through', function()
      -- 'talk' with nobody to talk to must emit NO command rather than an activation with a nil
      -- target: the director uses "planned nothing" as the signal to hand over.
      assert.equals(#plan('talk', worlds.empty()), 0)
      assert.equals(#plan('fight', worlds.empty()), 0)
      -- and an interaction goal WITH a target still plans it
      assert.is_true(#plan('talk', worlds.town()) > 0)
    end)

    it('rests for the configured number of hours', function()
      local commands = plan('rest', worlds.withOnly('rest'))
      local rest = commands[#commands]
      assert.equals(rest.type, 'rest')
      assert.equals(rest.hours, cfg.thresholds.restHours)
    end)

    it('sells junk then restocks at a merchant', function()
      local state = states.warrior({
        position = { x = 0, y = 0, z = 0 },
        inventory = { { id = 'chitin dagger', count = 5, value = 8, weight = 4 } },
      })
      local commands = plan('sell_junk', worlds.merchantTrip(), state)
      local types = util.map(commands, function(c) return c.type end)
      assert.is_true(util.any(types, function(t) return t == 'sell' end))
      assert.is_true(util.any(types, function(t) return t == 'buy' end))
    end)

    it('trains the lowest major skill', function()
      local commands = plan('train', worlds.withOnly('trainer'))
      local train = commands[#commands]
      assert.equals(train.type, 'train')
      assert.is_not_nil(train.skill)
      assert.equals(train.skill, 'armorer') -- lowest warrior major (41)
    end)

    it('wanders for explore and stops for idle', function()
      assert.equals(plan('explore', worlds.wilderness())[1].type, 'wander')
      assert.equals(plan('idle', worlds.empty())[1].type, 'stop')
    end)

    it('produces an activate for every interaction goal', function()
      for _, goalId in ipairs({ 'shop', 'talk', 'quest' }) do
        local commands = plan(goalId, worlds.town())
        assert.is_true(util.any(commands, function(c) return c.type == 'activate' end))
      end
    end)

    it('sends you to a travel service for go_town when one is near', function()
      local world = worlds.town()
      world.nearest.travel = { name = 'Silt Strider', position = { x = 400, y = 0, z = 0 } }
      local commands = plan('go_town', world)
      assert.is_true(util.any(commands, function(c)
        return c.type == 'activate' and c.kind == 'travel'
      end))
    end)

    it('walks to town on foot when there is no travel service', function()
      local commands = plan('go_town', worlds.town())
      assert.is_true(util.any(commands, function(c)
        return c.type == 'activate' and c.kind == 'shop'
      end))
    end)

    it('wanders for go_town in the middle of nowhere', function()
      local commands = plan('go_town', worlds.empty())
      assert.equals(commands[1].type, 'wander')
    end)

    it('walks where you tapped, and activates what you tapped on', function()
      local state = states.warrior({ position = { x = 0, y = 0, z = 0 } })
      local world = worlds.empty()
      local intent = { kind = 'enter', dest = { x = 100, y = 0, z = 0 }, target = { name = 'door' } }
      local commands = directorMod.planCommands('walk_to', view(state), world,
        snapshot(state, world), cfg,
        { classDef = classes.warrior, directive = { payload = intent } })
      assert.equals(commands[1].type, 'move')
      assert.equals(commands[1].dest.x, 100)
      assert.equals(commands[2].type, 'activate')
      assert.equals(commands[2].kind, 'enter')
    end)

    it('stops when a walk_to directive carries no destination', function()
      local state = states.warrior({ position = { x = 0, y = 0, z = 0 } })
      local world = worlds.empty()
      local commands = directorMod.planCommands('walk_to', view(state), world,
        snapshot(state, world), cfg, { classDef = classes.warrior, directive = { payload = nil } })
      assert.equals(commands[1].type, 'stop')
    end)
  end)

  describe('goal hysteresis', function()
    local ranked = {
      { id = 'quest', score = 0.10, need = 0.5 },
      { id = 'fight', score = 0.11, need = 0.5 },
      { id = 'shop', score = 0.40, need = 1.0 },
    }
    local on = { behaviour = { hysteresis = 0.25 } }

    it('stays on the current goal when the challenger only edges ahead', function()
      -- quest 0.12 vs fight 0.11: within the 25% margin, so we stay on fight
      local goal = directorMod.applyHysteresis('quest', { score = 0.12 }, 'fight', ranked, on)
      assert.equals(goal, 'fight')
    end)

    it('switches when the challenger clearly wins', function()
      -- quest 0.30 vs fight 0.11: no contest
      local goal = directorMod.applyHysteresis('quest', { score = 0.30 }, 'fight', ranked, on)
      assert.equals(goal, 'quest')
    end)

    it('does nothing at all when the margin is 0 (the default)', function()
      local goal = directorMod.applyHysteresis('shop', { score = 0.4 }, 'fight', ranked, {})
      assert.equals(goal, 'shop')
    end)

    it('never blocks an emergency', function()
      assert.equals(directorMod.applyHysteresis('flee', { score = 0.2 }, 'quest', ranked, on), 'flee')
      assert.equals(directorMod.applyHysteresis('survive', { score = 0.2 }, 'quest', ranked, on), 'survive')
      -- and never keeps you stuck on one
      assert.equals(directorMod.applyHysteresis('shop', { score = 0.4 }, 'flee', ranked, on), 'shop')
    end)

    it('drops the current goal the moment it stops being viable', function()
      local dead = { { id = 'quest', score = 0, need = 0 }, { id = 'shop', score = 0.4, need = 1 } }
      assert.equals(directorMod.applyHysteresis('shop', { score = 0.4 }, 'quest', dead, on), 'shop')
    end)

    it('is a no-op when there is no current goal', function()
      assert.equals(directorMod.applyHysteresis('shop', { score = 0.4 }, nil, ranked, on), 'shop')
    end)
  end)

  describe('helpers', function()
    it('finds the lowest major skill', function()
      local state = states.warrior()
      assert.equals(directorMod.lowestMajorSkill(classes.warrior, snapshot(state, {})), 'armorer')
      assert.is_nil(directorMod.lowestMajorSkill({ majorSkills = {} }, snapshot(state, {})))
    end)

    it('computes a flee point directly away from the threat', function()
      local point = directorMod.fleePoint({ x = 0, y = 0, z = 0 }, { x = 0, y = 10, z = 0 }, 800)
      expect(point.x):toBeCloseTo(0, 1e-6)
      expect(point.y):toBeCloseTo(-800, 1e-6)
      assert.is_nil(directorMod.fleePoint(nil, { x = 1, y = 1 }))
    end)
  end)

  describe('user directives', function()
    it('overrides the director\'s own choice', function()
      local d = newDirector()
      local snap = snapshot(states.warrior(), worlds.town())
      d:tick(0.1, snap)
      assert.not_equals(d.goal, 'rest')

      d:pushDirective('rest')
      local result = d:tick(0.1, snap)
      assert.equals(result.goal, 'rest')
      assert.equals(result.status.directive, 'rest')
      -- the push itself must be announced, even though the goal-change line is newer
      local announced = false
      for _, entry in ipairs(d.log:all()) do
        if entry.message:find('Directive: rest', 1, true) then announced = true end
      end
      assert.is_true(announced)
    end)

    it('yields to an emergency', function()
      local d = newDirector()
      d:pushDirective('shop')
      local dying = states.warrior({ health = { current = 3, base = 120, max = 120 }, position = { x = 0, y = 0, z = 0 } })
      local result = d:tick(0.1, snapshot(dying, worlds.town()))
      assert.equals(result.goal, 'survive')
      -- the directive is still queued for when the danger passes
      assert.equals(d:currentDirective().id, 'shop')
    end)

    it('expires a directive after its TTL', function()
      local d = newDirector()
      local snap = snapshot(states.warrior(), worlds.town())
      d:pushDirective('explore')
      assert.equals(d:tick(0.1, snap).goal, 'explore')
      assert.equals(d:tick(d.cfg.behaviour.directiveTtl + 1, snap).goal ~= 'explore', true)
    end)

    it('cancels directives on demand', function()
      local d = newDirector()
      d:pushDirective('rest')
      d:clearDirectives()
      assert.is_nil(d:currentDirective())
      local snap = snapshot(states.warrior(), worlds.town())
      assert.not_equals(d:tick(0.1, snap).goal, 'rest')
    end)

    it('ignores unknown directive ids', function()
      local d = newDirector()
      assert.is_nil(d:pushDirective('take-over-the-world'))
      assert.is_nil(d:currentDirective())
    end)
  end)

  describe('dialogue and persistence', function()
    it('observes dialogue events', function()
      local d = newDirector()
      local action = d:onDialogue({ actor = { recordId = 'arrille' }, type = 'greeting' })
      assert.equals(action.intent, 'greet')
      assert.equals(d.memory.actors.arrille.greetings, 1)
      assert.is_nil(d:onDialogue(nil))
    end)

    it('round-trips through serialize/load', function()
      local d = newDirector()
      d:tick(0.1, snapshot(states.warrior(), worlds.town()))
      d:onDialogue({ actor = { recordId = 'a' }, type = 'topic', recordId = 't' })
      local saved = d:serialize(1000)

      local restored = newDirector()
      restored:load(saved)
      assert.equals(restored.time, d.time)
      assert.equals(restored.goal, d.goal)
      assert.equals(restored.memory.events, 1)
      assert.equals(restored.rng:getState(), d.rng:getState())
    end)

    it('awards offline progress and logs it', function()
      local d = newDirector()
      local before = d.log:count()
      local award = d:applyOffline(2 * 3600)
      assert.is_true(award.applied)
      assert.is_true(d.log:count() > before)
      assert.is_true(d.log:lastMessage():find('Offline', 1, true) ~= nil)
      assert.is_true(d.gold > 0)
    end)

    it('does not log a trivial absence', function()
      local d = newDirector()
      local award = d:applyOffline(10)
      assert.is_false(award.applied)
    end)
  end)

  describe('play modes', function()
    it('starts in auto', function()
      local d = newDirector()
      assert.equals(d.mode, 'auto')
      assert.is_false(d:isManual())
    end)

    it('honours the configured start mode', function()
      local d = directorMod.new({ classDef = classes.warrior,
                                  config = { ui = { startMode = 'manual' } } })
      assert.equals(d.mode, 'manual')
      assert.is_true(d:isManual())
    end)

    it('rejects an unknown mode and keeps the current one', function()
      local d = newDirector()
      assert.equals(d:setMode('nonsense'), 'auto')
      assert.equals(d.mode, 'auto')
    end)

    it('cycles through every mode and back', function()
      local d = newDirector()
      assert.equals(d.mode, 'auto')
      assert.equals(d:nextMode(), 'manual')
      assert.equals(d:nextMode(), 'directive')
      assert.equals(d:nextMode(), 'auto')
    end)

    it('emits nothing at all in manual mode', function()
      local d = newDirector()
      d:setMode('manual')
      local result = d:tick(0.1, snapshot(states.warrior(), worlds.town()))
      assert.equals(result.goal, 'manual')
      assert.equals(result.status.mode, 'manual')
      expect(result.commands):toEqualDeep({})
    end)

    it('still emits nothing in manual mode when the character is dying', function()
      local d = newDirector()
      d:setMode('manual')
      local dying = states.warrior({ health = { current = 1, base = 120, max = 120 } })
      local result = d:tick(0.1, snapshot(dying, worlds.dangerous()))
      assert.equals(result.goal, 'manual')
      expect(result.commands):toEqualDeep({})
    end)

    it('acts normally again once out of manual', function()
      local d = newDirector()
      d:setMode('manual')
      d:tick(0.1, snapshot(states.warrior(), worlds.town()))
      d:setMode('auto')
      local result = d:tick(0.1, snapshot(states.warrior(), worlds.town()))
      assert.not_equals(result.goal, 'manual')
      assert.is_true(#result.commands >= 1)
      assert.equals(result.status.mode, 'auto')
    end)

    it('survives a serialize/load round trip', function()
      local d = newDirector()
      d:setMode('directive')
      local saved = d:serialize(1000)
      local restored = newDirector()
      restored:load(saved)
      assert.equals(restored.mode, 'directive')
    end)
  end)

  describe('panelData', function()
    it('carries everything the console needs', function()
      local d = newDirector()
      d:tick(0.1, snapshot(states.warrior(), worlds.town()))
      d:onDialogue({ actor = { recordId = 'arrille' }, type = 'topic', recordId = 'little secret' })
      local data = d:panelData()

      assert.equals(data.mode, 'auto')
      assert.is_not_nil(data.status)
      assert.is_not_nil(data.log)
      assert.equals(#data.dialogue, 1)
      assert.equals(data.dialogue[1].actor, 'arrille')
      assert.equals(data.topics[1].topic, 'little secret')
    end)

    it('caps the dialogue transcript', function()
      local d = newDirector()
      for i = 1, 40 do
        d:onDialogue({ actor = { recordId = 'npc' .. i }, type = 'greeting' })
      end
      assert.is_true(#d:panelData().dialogue <= 20)
    end)
  end)
end)
