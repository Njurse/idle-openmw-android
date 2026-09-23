# Vendored third-party code

Code here is **not ours**. It is copied verbatim, so it can be updated by re-copying,
and so a bug in it is never confused with a bug in the mod.

Rule for this directory: **do not edit vendored files.** If a change is genuinely needed,
patch it in a wrapper of our own and record that here, because a local edit is a local
edit that nobody will remember to re-apply on the next update.

## jumper/ — graph and grid search

| | |
| --- | --- |
| Upstream | <https://github.com/Yonaba/Jumper> |
| Pinned commit | `441176b33536f5cc0e915b93c9ab1aa3632aa2a0` (2019-10-13) |
| Licence | MIT — see `jumper/LICENSE.txt` |
| Files | `grid.lua`, `pathfinder.lua`, `core/*.lua`, `search/*.lua` (the whole library) |
| Modified | **No.** Copied as-is. |

### Why we use it, and where

The mod needs to answer two very different "how do I get there" questions:

1. **Local motion** — across the floor of one cell, around furniture, through a doorway.
   That is the engine's job: `nearby.findPath` walks the cell's navmesh. No library
   helps here, and ours would be worse than the engine's.
2. **Global routing** — which *cells* to pass through to reach another town, and which
   doors connect them. Morrowind's world is a graph: exterior cells adjoin on a grid,
   interiors hang off doors via `destCell`. **No grid library knows this**; the graph has
   to be surveyed from the game (`scripts/idle/router.lua`).

So Jumper is vendored for the **graph search over that surveyed world** (and for any
local grid work we ever need), not as a replacement for `nearby.findPath`. It is a
well-tested A*/Dijkstra/BFS/JPS implementation, which is better than hand-rolling a
priority queue and an A* and hoping.

### Why it works unmodified under our module path

Jumper discovers its own submodules from the name it was loaded as:

```lua
local _PATH = (...):gsub('%.pathfinder$','')   -- pathfinder.lua:12
local Utils = require(_PATH .. '.core.utils')
```

So requiring `scripts.vendor.jumper.pathfinder` makes `_PATH` = `scripts.vendor.jumper`,
and every internal `require` resolves inside our own tree. That is why there is no
find-and-replace of `require` strings in this directory — the upstream files are
untouched, and `tests/spec/jumper_spec.lua` proves the resolution works on LuaJIT,
Lua 5.1 and Lua 5.4.

### Usage

```lua
local Grid = require('scripts.vendor.jumper.grid')
local Pathfinder = require('scripts.vendor.jumper.pathfinder')

local grid = Grid(map)                       -- map[y][x]; any values you like
local finder = Pathfinder(grid, 'ASTAR', 0)  -- 0 is the walkable value
local path = finder:getPath(1, 1, 4, 3)      -- returns nil when there is no route
for node in path:iter() do
  local x, y = node:getX(), node:getY()
end
```

`Pathfinder(grid, name, walkable)` also accepts `'DIJKSTRA'`, `'BFS'`, `'DFS'`,
`'JPS'` and `'THETASTAR'`; `walkable` may be a value or a predicate function.

### Updating

```bash
B=https://raw.githubusercontent.com/Yonaba/Jumper/<new-commit>
for f in grid.lua pathfinder.lua core/assert.lua core/bheap.lua core/heuristics.lua \
         core/lookuptable.lua core/node.lua core/path.lua core/utils.lua \
         search/astar.lua search/bfs.lua search/dfs.lua search/dijkstra.lua \
         search/jps.lua search/thetastar.lua LICENSE.txt; do
  curl -sSL -o "mods/idle_openmw/scripts/vendor/jumper/$f" "$B/jumper/$f"
done
```

Then update the pinned commit above, re-run `python tools/run_tests.py --all`, and check
`grep -rnE "\bgoto\b|table\.unpack"` comes back clean (the suite targets Lua 5.1).
