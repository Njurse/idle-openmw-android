describe('idle.uiModel', function()
  local uiModel = require('scripts.idle.uiModel')
  local directive = require('scripts.idle.directive')
  local panels = require('tests.fixtures.panel')

  describe('modes', function()
    it('cycles manual -> directive -> auto -> manual', function()
      assert.equals(uiModel.nextMode('manual'), 'directive')
      assert.equals(uiModel.nextMode('directive'), 'auto')
      assert.equals(uiModel.nextMode('auto'), 'manual')
      assert.equals(uiModel.nextMode('nonsense'), 'manual')
    end)

    it('labels every mode', function()
      for _, mode in ipairs(uiModel.MODES) do
        assert.is_not_nil(uiModel.modeLabel(mode))
        assert.is_not_nil(uiModel.MODE_HINT[mode])
      end
      assert.equals(uiModel.modeLabel('manual'), 'MANUAL')
    end)
  end)

  describe('tabs', function()
    it('has the six console tabs', function()
      expect(uiModel.tabIds()):toEqualDeep({ 'info', 'orders', 'pack', 'talk', 'log', 'open' })
      assert.is_true(uiModel.isKnownTab('pack'))
      assert.is_false(uiModel.isKnownTab('nope'))
    end)

    it('steps and wraps', function()
      assert.equals(uiModel.nextTab('info', 1), 'orders')
      assert.equals(uiModel.nextTab('info', -1), 'open')
      assert.equals(uiModel.nextTab('open', 1), 'info')
    end)
  end)

  describe('footers', function()
    it('is contextual per tab', function()
      assert.is_true(#uiModel.footerFor('info') > 0)
      assert.is_true(#uiModel.footerFor('pack') >= 3)
      expect(uiModel.footerFor('open')):toEqualDeep({})
      expect(uiModel.footerFor('nonsense')):toEqualDeep({})
    end)

    it('marks the actions that need a selection', function()
      assert.is_true(uiModel.REQUIRES_SELECTION.equip)
      assert.is_true(uiModel.REQUIRES_SELECTION.sell)
      assert.is_true(uiModel.REQUIRES_SELECTION.drop)
      assert.is_nil(uiModel.REQUIRES_SELECTION.cycle_mode)
    end)
  end)

  describe('scrolling', function()
    it('clamps to the row count', function()
      assert.equals(uiModel.scroll(0, -5, 30, 10), 0)
      assert.equals(uiModel.scroll(0, 5, 30, 10), 5)
      assert.equals(uiModel.scroll(18, 99, 30, 10), 20)
      assert.equals(uiModel.scroll(0, 4, 3, 10), 0) -- fewer rows than a page
    end)

    it('slices the visible window and reports the edges', function()
      local rows = {}
      for i = 1, 25 do rows[i] = { label = 'row ' .. i } end
      local first = uiModel.visible(rows, 0, 10)
      assert.equals(#first.rows, 10)
      assert.equals(first.rows[1].label, 'row 1')
      assert.is_false(first.canUp)
      assert.is_true(first.canDown)

      -- asking past the end clamps to the last full page
      local last = uiModel.visible(rows, 20, 10)
      assert.equals(last.offset, 15)
      assert.equals(#last.rows, 10)
      assert.equals(last.rows[1].label, 'row 16')
      assert.is_true(last.canUp)
      assert.is_false(last.canDown)

      -- a ragged final page when the count is not a multiple of the page size
      local ragged = uiModel.visible(rows, 15, 20)
      assert.equals(ragged.offset, 5)
      assert.equals(#ragged.rows, 20)
    end)

    it('handles an empty list', function()
      local visible = uiModel.visible({}, 0, 10)
      assert.equals(#visible.rows, 0)
      assert.is_false(visible.canUp)
      assert.is_false(visible.canDown)
      assert.is_nil(uiModel.clampSelection(3, {}, 0, 10))
    end)
  end)

  describe('rows', function()
    it('formats label and detail', function()
      assert.equals(uiModel.formatRow({ label = 'Gold', detail = '1,240' }), 'Gold  1,240')
      assert.equals(uiModel.formatRow({ label = 'Gold' }), 'Gold')
      assert.equals(uiModel.formatRow(nil), '')
    end)

    it('lists every order as a directive the director understands', function()
      local rows = uiModel.buildRows('orders', panels.panel())
      local orderRows = {}
      for _, row in ipairs(rows) do
        -- contextual rows (e.g. the travel service) are not static orders
        if row.action == 'order' and not row.contextual then orderRows[#orderRows + 1] = row end
      end
      assert.equals(#orderRows, #uiModel.ORDERS)
      for _, row in ipairs(orderRows) do
        -- cross-module guard: an order that the director cannot honour is a bug
        assert.is_true(directive.isKnown(row.payload.id),
          ('order %s is not a known directive'):format(tostring(row.payload.id)))
      end
    end)

    describe('travel orders', function()
      it('offers travel as a queueable order', function()
        assert.is_true(directive.isKnown('travel'))
      end)

      it('adds nothing when no travel service is nearby', function()
        local rows = uiModel.buildRows('orders', panels.panel())
        for _, row in ipairs(rows) do
          assert.not_equals(row.id, 'travel-service')
        end
      end)

      it('lists the destinations of the nearest travel service', function()
        local panel = panels.panel({
          travelService = 'Silt strider',
          travel = { { cell = 'Balmora', price = 30 }, { cell = 'Vivec', price = 50 } },
        })
        local rows = uiModel.buildRows('orders', panel)
        local service, go
        for _, row in ipairs(rows) do
          if row.id == 'travel-service' then service = row end
          if row.id == 'order:travel:go' then go = row end
        end
        assert.is_not_nil(service)
        assert.is_not_nil(go)
        assert.is_true(service.label:find('Silt strider', 1, true) ~= nil)
        assert.equals(go.detail, 'Balmora, Vivec')
        assert.equals(go.payload.id, 'travel')
        assert.is_true(directive.isKnown(go.payload.id))
      end)
    end)

    it('summarises status on the info tab', function()      local rows = uiModel.buildRows('info', panels.panel())
      local text = {}
      for _, row in ipairs(rows) do text[#text + 1] = uiModel.formatRow(row) end
      local joined = table.concat(text, '\n')
      assert.is_true(joined:find('AUTO', 1, true) ~= nil)
      assert.is_true(joined:find('fight', 1, true) ~= nil)
      assert.is_true(joined:find('1,240', 1, true) ~= nil)
      assert.is_true(joined:find('HP 84%', 1, true) ~= nil)
    end)

    it('lists pack items with junk and worn flags', function()
      local rows = uiModel.buildRows('pack', panels.panel())
      local byId = {}
      for _, row in ipairs(rows) do byId[row.id] = row end

      assert.is_true(uiModel.formatRow(byId['item:heavy cuirass']):find('junk', 1, true) ~= nil)
      assert.is_true(uiModel.formatRow(byId['item:longsword']):find('WORN', 1, true) ~= nil)
      assert.equals(byId['item:chitin dagger'].payload.count, 5)
      assert.equals(byId['item:heavy cuirass'].action, 'select')
    end)

    it('says so when the pack is empty', function()
      local rows = uiModel.buildRows('pack', panels.empty())
      assert.is_true(uiModel.formatRow(rows[1]):find('nothing carried', 1, true) ~= nil)
    end)

    it('shows conversations, topics and quests on the talk tab', function()
      local rows = uiModel.buildRows('talk', panels.panel())
      local joined = ''
      for _, row in ipairs(rows) do joined = joined .. uiModel.formatRow(row) .. '\n' end
      assert.is_true(joined:find('little secret', 1, true) ~= nil)
      assert.is_true(joined:find('ms_fargothring', 1, true) ~= nil)
      assert.is_true(joined:find('arrille', 1, true) ~= nil)
    end)

    it('puts the newest log entry first', function()
      local rows = uiModel.buildRows('log', panels.panel())
      assert.is_true(uiModel.formatRow(rows[1]):find('Sold junk', 1, true) ~= nil)
      assert.is_true(uiModel.formatRow(rows[2]):find('Walked', 1, true) ~= nil)
    end)

    it('offers every launcher as a launch action with a real UI mode', function()
      local rows = uiModel.buildRows('open', panels.panel())
      local launchers = {}
      for _, row in ipairs(rows) do
        if row.action == 'launch' then launchers[#launchers + 1] = row end
      end
      assert.equals(#launchers, #uiModel.LAUNCHERS)
      for _, row in ipairs(launchers) do
        assert.is_true(type(row.payload.mode) == 'string' and #row.payload.mode > 0)
      end
    end)

    it('returns nothing for an unknown tab', function()
      expect(uiModel.buildRows('nope', panels.panel())):toEqualDeep({})
    end)
  end)

  describe('view', function()
    it('resolves the tab, page and selection', function()
      local view = uiModel.view({ tab = 'pack', offset = 0, selection = 2 },
        panels.panel(), { pageSize = 10 })
      assert.equals(view.tab, 'pack')
      assert.equals(view.mode, 'auto')
      assert.equals(#view.visible.rows, 5) -- 4 items + the summary line
      assert.equals(view.selection, 2)
      assert.equals(view.selected.id, 'item:chitin dagger')
      assert.is_true(#view.footer > 0)
    end)

    it('falls back to a valid tab', function()
      local view = uiModel.view({ tab = 'nope' }, panels.panel(), { pageSize = 5 })
      assert.equals(view.tab, 'info')
    end)

    it('reports the active order', function()      local view = uiModel.view({ tab = 'orders' }, panels.panel({ directive = 'rest' }), { pageSize = 5 })
      assert.equals(view.directive, 'rest')
    end)

    it('survives a nil panel', function()
      local view = uiModel.view({}, nil, { pageSize = 4 })
      assert.equals(view.tab, 'info')
      assert.equals(view.mode, 'auto')
    end)
  end)
end)
