-- tests/spec/camera_spec.lua
-- "Should the idle camera lock to an isometric view this tick?" --
-- scripts/idle/camera.lua.
describe('idle.camera', function()
  local camera = require('scripts.idle.camera')

  describe('plan', function()
    it('does nothing when the isometric camera is off', function()
      local plan = camera.plan({ cfg = { isometric = false }, phase = 'world' })
      assert.is_false(plan.apply)
      assert.is_string(plan.reason)
    end)

    it('does nothing when there is no config at all', function()
      assert.is_false(camera.plan({}).apply)
    end)

    it('never touches the camera outside the world', function()
      -- character creation and the load screen drive the camera themselves
      local plan = camera.plan({ cfg = { isometric = true }, phase = 'chargen' })
      assert.is_false(plan.apply)
    end)

    it('yields the camera to the human in manual play', function()
      local plan = camera.plan({ cfg = { isometric = true }, phase = 'world', manual = true })
      assert.is_false(plan.apply)
    end)

    it('keeps the lock in manual play when the player asked it to', function()
      local plan = camera.plan({
        cfg = { isometric = true, inManual = true }, phase = 'world', manual = true,
      })
      assert.is_true(plan.apply)
    end)

    it('locks in the world with a downward tilt and a third-person distance', function()
      local plan = camera.plan({ cfg = { isometric = true }, phase = 'world' })
      assert.is_true(plan.apply)
      assert.is_true(plan.pitch < 0)                 -- looking down
      assert.is_true(plan.distance > 0)
      assert.equals(plan.pitch, camera.DEFAULT_PITCH)
      assert.equals(plan.distance, camera.DEFAULT_DISTANCE)
    end)

    it('honours the configured angle and distance', function()
      local plan = camera.plan({
        cfg = { isometric = true, pitch = -0.5, distance = 900 }, phase = 'world',
      })
      assert.equals(plan.pitch, -0.5)
      assert.equals(plan.distance, 900)
    end)

    it('clamps the distance to a sane range', function()
      assert.equals(camera.plan({ cfg = { isometric = true, distance = 1 }, phase = 'world' }).distance,
        camera.MIN_DISTANCE)
      assert.equals(camera.plan({ cfg = { isometric = true, distance = 1e9 }, phase = 'world' }).distance,
        camera.MAX_DISTANCE)
    end)

    it('falls back to the default distance on a non-number', function()
      local plan = camera.plan({ cfg = { isometric = true, distance = 'far' }, phase = 'world' })
      assert.equals(plan.distance, camera.DEFAULT_DISTANCE)
    end)

    it('only passes a yaw through when one is configured', function()
      assert.is_nil(camera.plan({ cfg = { isometric = true }, phase = 'world' }).yaw)
      assert.equals(camera.plan({ cfg = { isometric = true, yaw = 1.0 }, phase = 'world' }).yaw, 1.0)
    end)
  end)
end)
