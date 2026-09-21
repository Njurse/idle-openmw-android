describe('idle.pathfinder', function()
  local pathfinder = require('scripts.idle.pathfinder')
  local configMod = require('scripts.idle.config')
  local util = require('scripts.idle.util')

  local cfg = configMod.new()

  --- A nav port returning a straight line of interpolated waypoints.
  local function makeNav(step, failAt)
    local nav = {}
    nav.calls = 0
    nav.findPath = function(from, to)
      nav.calls = nav.calls + 1
      if failAt then return false, nil end
      local points = {}
      local dx, dy, dz = (to.x or 0) - (from.x or 0), (to.y or 0) - (from.y or 0), (to.z or 0) - (from.z or 0)
      local total = math.sqrt(dx * dx + dy * dy + dz * dz)
      local count = math.max(1, math.ceil(total / step))
      for i = 1, count do
        local t = i / count
        points[i] = { x = (from.x or 0) + dx * t, y = (from.y or 0) + dy * t, z = (from.z or 0) + dz * t }
      end
      return true, points
    end
    return nav
  end

  describe('helpers', function()
    it('clamps waypoint lists', function()
      local points = {}
      for i = 1, 10 do points[i] = { x = i, y = 0, z = 0 } end
      assert.equals(#pathfinder.clampWaypoints(points, 4), 4)
      assert.equals(#pathfinder.clampWaypoints(points, 100), 10)
    end)

    it('measures polyline length', function()
      local path = { { x = 0, y = 0, z = 0 }, { x = 3, y = 4, z = 0 }, { x = 3, y = 4, z = 12 } }
      expect(pathfinder.pathLength(path)):toBeCloseTo(5 + 12, 1e-9)
      assert.equals(pathfinder.pathLength({}), 0)
    end)
  end)

  describe('steering', function()
    it('faces a target with atan2(dx, dy)', function()
      local from, to = { x = 0, y = 0, z = 0 }, { x = 0, y = 100, z = 0 }
      local s = pathfinder.steering(from, to, 0, { arriveTolerance = 10 })
      assert.equals(s.desiredYaw, 0)
      assert.is_true(s.shouldMove)

      local east = pathfinder.steering(from, { x = 100, y = 0, z = 0 }, 0, { arriveTolerance = 10 })
      expect(east.desiredYaw):toBeCloseTo(math.pi / 2, 1e-9)
      assert.is_false(east.shouldMove) -- must turn first
      assert.is_true(east.shouldTurn)
    end)

    it('reports arrival inside the tolerance', function()
      local s = pathfinder.steering({ x = 0, y = 0 }, { x = 5, y = 0 }, 0, { arriveTolerance = 10 })
      assert.is_true(s.arrived)
      assert.is_false(s.shouldMove)
    end)

    it('clamps the per-call turn', function()
      local s = pathfinder.steering({ x = 0, y = 0 }, { x = 100, y = 0 }, 0, { maxTurn = 0.2 })
      expect(s.yawChange):toBeCloseTo(0.2, 1e-9)
      assert.is_true(s.yawDelta > 0.2)
    end)
  end)

  describe('route', function()
    it('walks waypoints and reports arrival', function()
      local route = pathfinder.newRoute(makeNav(50), cfg)
      local start = { x = 0, y = 0, z = 0 }
      assert.is_true(route:setTarget({ x = 300, y = 0, z = 0 }))
      local position = util.copy(start)
      local status
      for _ = 1, 100 do
        position.x = position.x + 40
        status = route:update(position, 0)
        if status.status == 'arrived' then break end
      end
      assert.equals(status.status, 'arrived')
      assert.is_false(route:isActive())
    end)

    it('ignores a re-target of the same place', function()
      local route = pathfinder.newRoute(makeNav(50), cfg)
      assert.is_true(route:setTarget({ x = 100, y = 0, z = 0 }))
      assert.is_false(route:setTarget({ x = 101, y = 0, z = 0 }))
      assert.is_true(route:setTarget({ x = 5000, y = 0, z = 0 }))
    end)

    it('reports failure when no path exists', function()
      local route = pathfinder.newRoute(makeNav(50, true), cfg)
      route:setTarget({ x = 500, y = 0, z = 0 })
      local status = route:update({ x = 0, y = 0, z = 0 }, 0)
      assert.equals(status.status, 'failed')
    end)

    it('repaths after the cache TTL expires', function()
      local nav = makeNav(50)
      local route = pathfinder.newRoute(nav, cfg)
      route:setTarget({ x = 5000, y = 0, z = 0 })
      route:update({ x = 0, y = 0, z = 0 }, 0)
      local afterFirst = nav.calls
      route:update({ x = 1, y = 0, z = 0 }, cfg.behaviour.pathCacheTtl + 1)
      assert.is_true(nav.calls > afterFirst)
    end)

    it('gives up when the actor is stuck', function()
      local route = pathfinder.newRoute(makeNav(50), cfg)
      route:setTarget({ x = 5000, y = 0, z = 0 })
      local frozen = { x = 0, y = 0, z = 0 }
      local status
      -- the path is cached within the TTL, so no repath hides the lack of progress
      status = route:update(frozen, 0)
      assert.equals(status.status, 'moving')
      status = route:update(frozen, cfg.behaviour.stuckTimeout + 1)
      assert.equals(status.status, 'stuck')
    end)

    it('returns idle with no target', function()
      local route = pathfinder.newRoute(makeNav(50), cfg)
      assert.equals(route:update({ x = 0, y = 0, z = 0 }, 0).status, 'idle')
    end)
  end)
end)
