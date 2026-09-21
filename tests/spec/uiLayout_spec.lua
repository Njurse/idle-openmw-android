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
end)
