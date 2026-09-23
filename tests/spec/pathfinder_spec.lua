describe('idle.pathfinder', function()
  local pathfinder = require('scripts.idle.pathfinder')
  local configMod = require('scripts.idle.config')
  local util = require('scripts.idle.util')

  local cfg = configMod.new()

  --- A nav port returning a straight line of interpolated waypoints.
  local function makeNav(step, failAt)
    local nav = {}
    nav.calls = 0
    nav.findPath = function(from, to, opts)
      nav.calls = nav.calls + 1
      nav.lastOpts = opts
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

    it('ignores a re-target of the same place', function()      local route = pathfinder.newRoute(makeNav(50), cfg)
      assert.is_true(route:setTarget({ x = 100, y = 0, z = 0 }))
      assert.is_false(route:setTarget({ x = 101, y = 0, z = 0 }))
      assert.is_true(route:setTarget({ x = 5000, y = 0, z = 0 }))
    end)

    it('asks the nav port to allow doors', function()
      -- The direction of travel is the pure layer's to state; the engine port turns it into the
      -- includeFlags bitmask. A port that ignores the third argument still works, but the intent
      -- is at least on the wire and testable.
      local nav = makeNav(50)
      local route = pathfinder.newRoute(nav, cfg)
      route:setTarget({ x = 500, y = 0, z = 0 })
      route:update({ x = 0, y = 0, z = 0 }, 0)
      assert.is_true(nav.lastOpts ~= nil)
      assert.is_true(nav.lastOpts.doors ~= false)
    end)

    it('snaps an off-navmesh target onto walkable ground', function()
      -- A target can sit off the navmesh (an item on a table, a shopkeeper behind a counter).
      -- The port exposes `snap`; the route uses it ONCE rather than failing the move outright.
      local function navWith(snapFn)
        return {
          findPath = function(_, to)
            if to.x == 90 then return true, { { x = 90, y = 0, z = 0 } } end
            return false, nil
          end,
          snap = snapFn,
        }
      end

      -- without snap, the move simply fails
      local plain = pathfinder.newRoute(navWith(nil), cfg)
      plain:setTarget({ x = 1000, y = 0, z = 0 })
      assert.equals(plain:update({ x = 90, y = 0, z = 0 }, 0).status, 'failed')

      -- with snap, the same target is walked to at the nearest walkable point instead
      local route = pathfinder.newRoute(navWith(function() return { x = 90, y = 0, z = 0 } end), cfg)
      route:setTarget({ x = 1000, y = 0, z = 0 })
      assert.equals(route:update({ x = 90, y = 0, z = 0 }, 0).status, 'arrived')
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

    it('does not call a path that ends short an arrival', function()
      -- An UNREACHABLE target (off the navmesh, behind a wall) gives a path that stops at the
      -- nearest walkable point. Reporting 'arrived' there is how a move could "succeed" hundreds
      -- of units from its target and then fire an activation out of range.
      local nav = {
        findPath = function(_, to)
          -- a path whose only point is 400 units short of the target
          return true, { { x = (to.x or 0) - 400, y = 0, z = 0 } }
        end,
      }
      local route = pathfinder.newRoute(nav, cfg)
      route:setTarget({ x = 1000, y = 0, z = 0 })
      -- stand on the last waypoint: the path is spent, but we are far from the target
      local status = route:update({ x = 600, y = 0, z = 0 }, 0)
      assert.equals(status.status, 'short')
      assert.is_number(status.distance)
      assert.is_true(status.distance > cfg.behaviour.arriveTolerance)
      assert.is_false(route:isActive())
    end)

    it('honours a per-target arrival tolerance', function()
      -- Being 80 units out is inside the DEFAULT 96 but outside a requested 60 -- so an order
      -- like "get within interaction range of that shopkeeper" is not silently loosened.
      local loose = pathfinder.newRoute(makeNav(10), cfg)
      loose:setTarget({ x = 1000, y = 0, z = 0 })
      assert.equals(loose:update({ x = 920, y = 0, z = 0 }, 0).status, 'arrived')

      local tight = pathfinder.newRoute(makeNav(10), cfg)
      tight:setTarget({ x = 1000, y = 0, z = 0 }, { arriveTolerance = 60 })
      assert.equals(tight.arriveTolerance, 60)
      assert.equals(tight:update({ x = 920, y = 0, z = 0 }, 0).status, 'moving')
    end)
  end)

  describe('doorAhead', function()
    -- The engine's navmesh ROUTES THROUGH doors (includeFlags includes OpenDoor), but the actor
    -- still has to open them. This is the decision half: which door is worth opening right now.
    it('picks the close door that is in front', function()
      local doors = {
        { id = 'behind', position = { x = 0, y = -100, z = 0 } },
        { id = 'far',    position = { x = 0, y = 400, z = 0 } },
        { id = 'ahead',  position = { x = 0, y = 80, z = 0 } },
      }
      -- heading 0 faces +y (atan2(dx, dy)), so only 'ahead' is in the cone and in range
      local door = pathfinder.doorAhead({ x = 0, y = 0, z = 0 }, 0, doors, { radius = 128 })
      assert.is_true(door ~= nil)
      assert.equals(door.id, 'ahead')
    end)

    it('ignores a door behind the actor', function()
      local doors = { { id = 'behind', position = { x = 0, y = -50, z = 0 } } }
      assert.is_nil(pathfinder.doorAhead({ x = 0, y = 0, z = 0 }, 0, doors, { radius = 128 }))
    end)

    it('returns nothing with no doors', function()
      assert.is_nil(pathfinder.doorAhead({ x = 0, y = 0, z = 0 }, 0, {}))
    end)
  end)
end)
