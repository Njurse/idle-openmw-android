-- tests/spec/jumper_spec.lua
-- The vendored pathfinding library (scripts/vendor/jumper) must LOAD and WORK in our
-- runtime, on every Lua the suite targets.
--
-- Why this spec matters more than it looks: Jumper finds its own submodules from the
-- name it was required as (`_PATH = (...):gsub('%.pathfinder$','')`, pathfinder.lua:12).
-- Under OpenMW our modules are `scripts.vendor.jumper.*`, so if `...` ever stopped being
-- the module name, the internal requires would resolve to nothing and the library would
-- fail at load -- in the game, not here. These tests pin that down, plus the behaviour we
-- actually depend on (a route exists, walls are respected, unreachable means nil).
--
-- The library is vendored unmodified; see scripts/vendor/README.md.
describe('vendor.jumper', function()
  local Grid = require('scripts.vendor.jumper.grid')
  local Pathfinder = require('scripts.vendor.jumper.pathfinder')

  local WALKABLE, WALL = 0, 1

  --- An all-walkable w x h map, as map[y][x].
  local function open(w, h)
    local map = {}
    for y = 1, h do
      map[y] = {}
      for x = 1, w do map[y][x] = WALKABLE end
    end
    return map
  end

  it('resolves its own submodules under our module prefix', function()
    assert.is_not_nil(Grid)
    assert.is_not_nil(Pathfinder)
    -- and the deeper pieces, which are required transitively from it
    assert.is_not_nil(require('scripts.vendor.jumper.core.bheap'))
    assert.is_not_nil(require('scripts.vendor.jumper.core.path'))
    assert.is_not_nil(require('scripts.vendor.jumper.search.astar'))
  end)

  it('finds a route across an open grid', function()
    local finder = Pathfinder(Grid(open(6, 4)), 'ASTAR', WALKABLE)
    local path = finder:getPath(1, 1, 6, 4)
    assert.is_not_nil(path, 'expected a route across an open grid')

    local nodes = {}
    for node in path:iter() do nodes[#nodes + 1] = node end
    assert.is_true(#nodes >= 2, 'a route should have at least two nodes')

    -- It should start where we asked and end where we asked. Checked against the
    -- coordinates we PASSED IN rather than a hard-coded direction, so this holds
    -- whatever x/y order the library uses internally.
    assert.equals(1, nodes[1]:getX())
    assert.equals(1, nodes[1]:getY())
    assert.equals(6, nodes[#nodes]:getX())
    assert.equals(4, nodes[#nodes]:getY())
  end)

  it('never routes through a wall', function()
    local map = open(7, 5)
    -- a full-height wall at x=4, with a single gap at y=1
    for y = 2, 5 do map[y][4] = WALL end

    local finder = Pathfinder(Grid(map), 'ASTAR', WALKABLE)
    local path = finder:getPath(1, 1, 7, 5)
    assert.is_not_nil(path, 'expected a route around the wall')

    for node in path:iter() do
      local x, y = node:getX(), node:getY()
      assert.equals(WALKABLE, map[y] and map[y][x], ('node (%d,%d) is a wall'):format(x, y))
    end
  end)

  it('returns nil when the goal cannot be reached', function()
    local map = open(5, 5)
    for y = 1, 5 do map[y][3] = WALL end   -- a wall with no gap

    local finder = Pathfinder(Grid(map), 'ASTAR', WALKABLE)
    assert.is_nil(finder:getPath(1, 1, 5, 5), 'a sealed goal must not report a route')
  end)

  it('carries the search modes the router may want', function()
    local grid = Grid(open(3, 3))
    for _, mode in ipairs({ 'ASTAR', 'DIJKSTRA', 'BFS', 'DFS' }) do
      local finder = Pathfinder(grid, mode, WALKABLE)
      assert.is_not_nil(finder:getPath(1, 1, 3, 3), mode .. ' found no route')
    end
  end)

  it('is loadable with the same call the router will use', function()
    -- A tiny end-to-end: two "cells" joined by one edge, searched as a graph-like grid.
    -- This is the shape scripts/idle/router.lua will rely on.
    local map = {
      { WALKABLE, WALKABLE },
      { WALKABLE, WALKABLE },
    }
    local path = Pathfinder(Grid(map), 'ASTAR', WALKABLE):getPath(1, 1, 2, 2)
    assert.is_not_nil(path)

    -- NB `getLength()` is the euclidean DISTANCE along the path (core/path.lua:72),
    -- not a node count -- a diagonal step between two nodes is ~1.414, not 2. Do not
    -- read it as "number of waypoints".
    assert.is_true(path:getLength() >= 1.4,
      ('expected at least one diagonal step of distance, got %s'):format(path:getLength()))

    local steps = 0
    for _ in path:iter() do steps = steps + 1 end
    assert.equals(2, steps, 'a 1x1 diagonal should be two nodes')
  end)
end)
