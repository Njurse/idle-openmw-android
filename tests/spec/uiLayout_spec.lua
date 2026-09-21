describe('idle.uiLayout', function()
  local layout = require('scripts.idle.uiLayout')
  local configMod = require('scripts.idle.config')

  local cfg = configMod.new()

  -- The Samsung Galaxy S23+ in portrait, expressed in UI units.
  local PHONE = { x = 1080, y = 2340 }
  local SMALL = { x = 720, y = 1280 }
  local BIG = { x = 1440, y = 3120 }

  it('scales with screen height, within bounds', function()
    assert.equals(layout.compute({ x = 720, y = 1000 }, cfg).scale, layout.MIN_SCALE)
    assert.is_true(layout.compute(PHONE, cfg).scale > 1.5)
    assert.equals(layout.compute({ x = 4000, y = 9000 }, cfg).scale, layout.MAX_SCALE)
  end)

  it('keeps everything inside the screen', function()
    for _, screen in ipairs({ PHONE, SMALL, BIG }) do
      local l = layout.compute(screen, cfg)
      assert.is_true(l.status.x >= 0)
      assert.is_true(l.status.x + l.status.width <= screen.x)
      assert.is_true(l.bar.x >= 0)
      assert.is_true(l.bar.x + l.bar.width <= screen.x)
      assert.is_true(l.bar.y + l.bar.height <= screen.y)
      assert.is_true(l.status.y >= 0)
    end
  end)

  it('reserves the notch and gesture-bar safe areas', function()
    local l = layout.compute(PHONE, cfg)
    assert.is_true(l.safeTop >= PHONE.y * 0.03)
    assert.is_true(l.safeBottom >= PHONE.y * 0.055)
    assert.is_true(l.status.y >= l.safeTop)
    assert.is_true(l.bar.y + l.bar.height + l.safeBottom <= PHONE.y + 1)
  end)

  it('gives the bar a real touch-target height', function()
    local l = layout.compute(PHONE, cfg)
    assert.is_true(l.touchHeight >= layout.TOUCH_TARGET)
    -- and a taller one on a bigger screen
    assert.is_true(layout.compute(BIG, cfg).touchHeight >= l.touchHeight)
  end)

  it('leaves a viewport between the status panel and the bar', function()
    local l = layout.compute(PHONE, cfg)
    assert.is_true(l.viewport.top > l.status.y)
    assert.is_true(l.viewport.bottom > l.viewport.top)
    assert.is_true(l.viewport.bottom < l.bar.y)
  end)

  it('honours a larger configured top inset', function()
    local padded = configMod.new()
    local l = layout.compute(PHONE, padded)
    local shallow = configMod.new({ ui = { topInset = 0 } })
    local l2 = layout.compute(PHONE, shallow)
    assert.is_true(l.status.y >= l2.status.y)
  end)

  it('fits the default buttons into whole rows', function()
    local l = layout.compute(PHONE, cfg)
    local buttons = layout.defaultButtons()
    local rows, perRow = layout.buttonRows(buttons, l.bar, l.scale)
    assert.is_true(perRow >= 1)
    local total = 0
    for _, row in ipairs(rows) do total = total + #row end
    assert.equals(total, #buttons)
    assert.equals(layout.rowCount(layout.defaultButtons(), l.bar, l.scale), #rows)
  end)

  it('gives every button a usable rectangle that fits the bar', function()
    local l = layout.compute(PHONE, cfg)
    local rows = layout.buttonRows(layout.defaultButtons(), l.bar, l.scale)
    for rowIndex, row in ipairs(rows) do
      for _, button in ipairs(row) do
        assert.is_true(button.width >= 80)
        assert.is_true(button.height >= layout.TOUCH_TARGET)
        assert.is_true(button.x >= l.bar.x)
        assert.is_true(button.x + button.width <= l.bar.x + l.bar.width)
        -- row 1 is the bar; later rows stack upward
        assert.equals(button.y, l.bar.y - (rowIndex - 1) * (l.bar.height + layout.BUTTON_GAP))
      end
    end
  end)

  it('wraps to more rows on a narrow screen than a wide one', function()
    local narrow = layout.compute({ x = 480, y = 1280 }, cfg)
    local wide = layout.compute({ x = 2400, y = 1280 }, cfg)
    local _, narrowPerRow = layout.buttonRows(layout.defaultButtons(), narrow.bar, narrow.scale)
    local _, widePerRow = layout.buttonRows(layout.defaultButtons(), wide.bar, wide.scale)
    assert.is_true(narrowPerRow <= widePerRow)
    assert.is_true(layout.rowCount(layout.defaultButtons(), narrow.bar, narrow.scale)
                 >= layout.rowCount(layout.defaultButtons(), wide.bar, wide.scale))
  end)

  it('stacks upward from the bar without going negative', function()
    local l = layout.compute(PHONE, cfg)
    local top = layout.stackTop(layout.defaultButtons(), l.bar, l.scale)
    assert.is_true(top <= l.bar.y)
    assert.is_true(top > 0)
  end)

  it('labels the auto-play toggle by state', function()
    assert.equals(layout.toggleLabel(true), 'AUTO')
    assert.equals(layout.toggleLabel(false), 'PAUSED')
    assert.equals(layout.compute(PHONE, cfg).touchHeight >= 56, true)
  end)

  it('survives a missing screen or config', function()
    local l = layout.compute(nil, nil)
    assert.is_true(l.width > 0 and l.height > 0 and l.scale >= 1)
    assert.is_true(l.status.width > 0)
  end)

  describe('console panel', function()
    local tabs = require('scripts.idle.uiModel').TABS

    local function rectOverlaps(a, b)
      if not a or not b then return false end
      return a.x < b.x + b.width and b.x < a.x + a.width
        and a.y < b.y + b.height and b.y < a.y + a.height
    end

    it('reserves more screen for the game in manual mode', function()
      local manual = layout.split(layout.compute(PHONE, cfg), 'manual')
      local auto = layout.split(layout.compute(PHONE, cfg), 'auto')
      assert.is_true(manual.panel.height < auto.panel.height)
      assert.is_true(manual.viewport.height > auto.viewport.height)
      assert.equals(layout.viewportBottom({ viewport = manual.viewport }), manual.panel.y)
    end)

    it('never lets the panel reach into the notch', function()
      for _, screen in ipairs({ PHONE, SMALL, BIG }) do
        for _, mode in ipairs(layout.MODES) do
          local base = layout.compute(screen, cfg)
          local parts = layout.split(base, mode)
          assert.is_true(parts.panel.y >= base.safeTop - 1)
          assert.equals(parts.viewport.y + parts.viewport.height, parts.panel.y)
          assert.equals(parts.panel.y + parts.panel.height, screen.y)
        end
      end
    end)

    it('lays the tabs across the full panel width without gaps', function()
      local parts = layout.split(layout.compute(PHONE, cfg), 'auto')
      local rects = layout.tabRects(parts.panel, tabs, 1.95)
      assert.equals(#rects, #tabs)
      assert.equals(rects[1].x, parts.panel.x)
      local expectedEnd = parts.panel.x + parts.panel.width
      assert.equals(rects[#rects].x + rects[#rects].width, expectedEnd)
      for i = 2, #rects do
        assert.equals(rects[i].x, rects[i - 1].x + rects[i - 1].width)
      end
    end)

    it('models the basic shapes', function()
      -- smoke: the console builds with real inputs
      local l = layout.compute(PHONE, cfg)
      assert.is_true(l.height > 0)
    end)

    it('fits list rows between the tabs and the footer', function()
      local parts = layout.split(layout.compute(PHONE, cfg), 'auto')
      local rects = layout.tabRects(parts.panel, tabs, 1.95)
      local list = layout.listRects(parts.panel, rects[1].height, 1.95, { footerRows = 2 })
      assert.is_true(list.pageSize >= 1)
      assert.equals(list.rows[1].y, rects[1].y + rects[1].height)
      local last = list.rows[#list.rows]
      assert.is_true(last.y + last.height <= parts.panel.y + parts.panel.height)
      assert.is_true(list.up.y >= parts.panel.y)
      assert.is_true(list.down.y + list.down.height <= parts.panel.y + parts.panel.height)
      assert.equals(list.up.x, list.x + list.width)
    end)

    it('builds a whole console with regions that never overlap', function()
      local console = layout.console(PHONE, cfg, {
        mode = 'auto', tabs = tabs,
        footer = { { id = 'a' }, { id = 'b' }, { id = 'c' } },
        footerRows = 2,
      })
      assert.is_true(console.pageSize >= 1)
      assert.equals(console.footerIds[1], 'a')
      assert.equals(#console.footer, 3)

      local regions = layout.regions(console)
      assert.is_true(#regions >= #tabs + console.pageSize + 2 + 3)
      for i = 1, #regions do
        for j = i + 1, #regions do
          assert.is_false(rectOverlaps(regions[i], regions[j]),
            ('regions overlap: %s and %s'):format(regions[i].name, regions[j].name))
        end
      end
    end)

    it('hit-tests tabs, rows and footer buttons', function()
      local console = layout.console(PHONE, cfg, {
        mode = 'auto', tabs = tabs, footer = { { id = 'equip' }, { id = 'sell' } },
      })
      local regions = layout.regions(console)

      local firstTab = console.tabs[1]
      assert.equals(layout.hitTest(regions, { x = firstTab.x + 2, y = firstTab.y + 2 }), 'tab:info')

      local row = console.list.rows[1]
      assert.equals(layout.hitTest(regions, { x = row.x + 2, y = row.y + 2 }), 'row:1')

      local footer = console.footer[1]
      assert.equals(layout.hitTest(regions, { x = footer.x + 2, y = footer.y + 2 }), 'footer:equip')

      assert.is_nil(layout.hitTest(regions, nil))
      assert.is_nil(layout.hitTest(regions, { x = -5, y = -5 }))
    end)

    it('queues more rows on a tall screen than a short one', function()
      local tall = layout.console(BIG, cfg, { mode = 'auto', tabs = tabs, footer = {} })
      local short = layout.console({ x = 720, y = 1100 }, cfg, { mode = 'manual', tabs = tabs, footer = {} })
      assert.is_true(tall.pageSize >= short.pageSize)
    end)
  end)

  describe('collapsing the console', function()
    local function console(over)
      local model = { mode = 'auto', tabs = tabs, footer = { { id = 'a' }, { id = 'b' } }, footerRows = 1 }
      for key, value in pairs(over or {}) do model[key] = value end
      return layout.console(PHONE, cfg, model)
    end

    it('gives the game back most of the screen', function()
      local expanded = console({ collapsed = false })
      local collapsed = console({ collapsed = true })
      assert.is_true(collapsed.panel.height < expanded.panel.height)
      assert.is_true(collapsed.viewport.height > expanded.viewport.height)
      assert.equals(collapsed.collapsed, true)
      assert.equals(expanded.collapsed, false)
      -- and it must stay a real panel, not a sliver
      assert.is_true(collapsed.panel.height > collapsed.tabsHeight)
      assert.is_true(collapsed.pageSize >= 1)
    end)

    it('drops the page readout strip when collapsed', function()
      assert.is_nil(console({ collapsed = true }).page)
      assert.is_not_nil(console({ collapsed = false }).page)
    end)

    it('never collapses into the notch', function()
      for _, screen in ipairs({ PHONE, SMALL, BIG }) do
        local collapsed = console({ collapsed = true })
        local base = layout.compute(screen, cfg)
        assert.is_true(collapsed.panel.y >= base.safeTop - 1)
        assert.equals(collapsed.viewport.y + collapsed.viewport.height, collapsed.panel.y)
      end
    end)
  end)

  describe('the page readout', function()
    it('sits above the first row and inside the list width', function()
      local console = layout.console(PHONE, cfg, { mode = 'auto', tabs = tabs, footer = {} })
      assert.is_not_nil(console.page)
      local firstRow = console.list.rows[1]
      assert.is_true(console.page.y + console.page.height <= firstRow.y)
      -- it must not steal taps from the scroll column
      assert.is_true(console.page.x + console.page.width <= console.list.up.x)
    end)

    it('is part of the touch regions and hit-testable', function()
      local console = layout.console(PHONE, cfg, { mode = 'auto', tabs = tabs, footer = {} })
      local regions = layout.regions(console)
      assert.equals(layout.hitTest(regions, { x = console.page.x + 2, y = console.page.y + 2 }),
        'page:readout')
    end)

    it('costs at most one row of list capacity', function()
      local withPage = layout.console(PHONE, cfg, { mode = 'auto', tabs = tabs, footer = {}, showPage = true })
      local without = layout.console(PHONE, cfg, { mode = 'auto', tabs = tabs, footer = {}, showPage = false })
      assert.is_true(withPage.pageSize <= without.pageSize)
      assert.is_true(without.pageSize - withPage.pageSize <= 1)
    end)
  end)
end)
