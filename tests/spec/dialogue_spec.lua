describe('idle.dialogue', function()
  local dialogue = require('scripts.idle.dialogue')

  it('parses a well-formed DialogueResponse', function()
    local parsed = dialogue.parse({ actor = { recordId = 'arrille' }, type = 'greeting', recordId = 'greet1', infoId = 'info1' })
    assert.equals(parsed.kind, 'greeting')
    assert.is_true(parsed.knownType)
    assert.equals(parsed.recordId, 'greet1')
    assert.equals(dialogue.actorId(parsed.actor), 'arrille')
  end)

  it('degrades gracefully on bad input', function()
    assert.is_nil(dialogue.parse(nil))
    assert.is_nil(dialogue.parse('nope'))
    local parsed = dialogue.parse({ actor = { id = 'x' }, type = 'weird' })
    assert.equals(parsed.kind, 'unknown')
    assert.is_false(parsed.knownType)
  end)

  it('maps every documented type to an intent', function()
    local cases = {
      greeting = 'greet',
      topic = 'note_topic',
      journal = 'log_journal',
      persuasion = 'note_refusal',
      voice = 'ignore',
    }
    for kind, intent in pairs(cases) do
      local action = dialogue.interpret(dialogue.parse({ actor = { id = 'a' }, type = kind, recordId = 'r' }))
      assert.equals(action.intent, intent)
    end
    assert.equals(dialogue.interpret(nil).intent, 'ignore')
  end)

  it('describes events for the activity log', function()
    local topic = dialogue.parse({ actor = { recordId = 'arrille' }, type = 'topic', recordId = 'little secret' })
    assert.is_true(dialogue.describe(topic):find('little secret', 1, true) ~= nil)
    local greeting = dialogue.parse({ actor = { recordId = 'arrille' }, type = 'greeting' })
    assert.is_true(dialogue.describe(greeting):find('greeted', 1, true) ~= nil)
  end)

  describe('memory', function()
    it('counts greetings, topics and refusals per actor', function()
      local memory = dialogue.newMemory()
      memory:observe(dialogue.parse({ actor = { recordId = 'a' }, type = 'greeting' }), 5)
      memory:observe(dialogue.parse({ actor = { recordId = 'a' }, type = 'topic', recordId = 't1' }), 6)
      memory:observe(dialogue.parse({ actor = { recordId = 'a' }, type = 'persuasion' }), 7)
      memory:observe(dialogue.parse({ actor = { recordId = 'b' }, type = 'greeting' }), 8)

      assert.equals(memory.actors.a.greetings, 1)
      assert.equals(memory.actors.a.topics, 1)
      assert.equals(memory:refusalsFor('a'), 1)
      assert.equals(memory.events, 4)
      expect(memory:actorIds()):toEqualDeep({ 'a', 'b' })
    end)

    it('tracks known topics by frequency', function()
      local memory = dialogue.newMemory()
      memory:observe(dialogue.parse({ actor = { id = 'a' }, type = 'topic', recordId = 'rumours' }), 1)
      memory:observe(dialogue.parse({ actor = { id = 'a' }, type = 'topic', recordId = 'rumours' }), 2)
      memory:observe(dialogue.parse({ actor = { id = 'a' }, type = 'topic', recordId = 'corprus' }), 3)
      local topics = memory:knownTopics()
      assert.equals(topics[1].topic, 'rumours')
      assert.equals(topics[1].count, 2)
    end)

    it('round-trips through serialize/load', function()
      local memory = dialogue.newMemory()
      memory:observe(dialogue.parse({ actor = { recordId = 'a' }, type = 'topic', recordId = 't' }), 1)
      local restored = dialogue.newMemory():load(memory:serialize())
      assert.equals(restored.events, 1)
      assert.equals(restored.actors.a.topics, 1)
      assert.equals(restored.topics.t, 1)
    end)

    it('ignores bad observations', function()
      local memory = dialogue.newMemory()
      memory:observe(nil, 1)
      assert.equals(memory.events, 0)
      memory:reset()
      assert.equals(#memory:knownTopics(), 0)
    end)
  end)
end)
