-- scripts/idle/util.lua
-- Pure helpers. NO engine dependencies, NO I/O -- everything here is safe to
-- unit-test headlessly and to call from any script type.
--
-- Kept Lua 5.1 / LuaJIT compatible on purpose: OpenMW runs LuaJIT (see
-- docs/openmw-lua-api.md §0). No `goto`, no `//`, no `table.unpack`.

local M = {}

M.EPSILON = 1e-9
M.PI = math.pi
M.TAU = math.pi * 2

--- Clamp `v` into [lo, hi]. Returns `lo` if v is not a number.
function M.clamp(v, lo, hi)
  if type(v) ~= 'number' then return lo end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

--- Linear interpolation; `t` is not clamped (use clamp() if you want that).
function M.lerp(a, b, t) return a + (b - a) * t end

--- Round to `digits` decimal places (default 0).
function M.round(v, digits)
  local mult = 10 ^ (digits or 0)
  return math.floor(v * mult + 0.5) / mult
end

--- Sign as a number: -1, 0 or 1.
function M.sign(v)
  if v > 0 then return 1 elseif v < 0 then return -1 end
  return 0
end

--- Normalize an angle to (-pi, pi].
function M.normalizeAngle(a)
  a = a % M.TAU
  if a > M.PI then a = a - M.TAU end
  return a
end

--- Shortest signed angular delta from `from` to `to`, in (-pi, pi].
function M.angleDelta(from, to)
  return M.normalizeAngle(to - from)
end

--- Rotate `from` toward `to` by at most `maxStep` radians.
function M.approachAngle(from, to, maxStep)
  local d = M.angleDelta(from, to)
  if math.abs(d) <= maxStep then return to end
  return M.normalizeAngle(from + M.sign(d) * maxStep)
end

--- Treat a value as a 3D point. Accepts {x=,y=,z=} or nil.
local function point(v)
  if type(v) ~= 'table' then return nil end
  return { v.x or 0, v.y or 0, v.z or 0 }
end

--- Squared distance between two {x=,y=,z=} points.
function M.dist2(a, b)
  local pa, pb = point(a), point(b)
  if not pa or not pb then return nil end
  local dx, dy, dz = pa[1] - pb[1], pa[2] - pb[2], pa[3] - pb[3]
  return dx * dx + dy * dy + dz * dz
end

--- Distance between two {x=,y=,z=} points.
function M.distance(a, b)
  local d2 = M.dist2(a, b)
  if not d2 then return nil end
  return math.sqrt(d2)
end

--- Horizontal (XY-plane) distance -- the useful metric for walking.
function M.planarDistance(a, b)
  if type(a) ~= 'table' or type(b) ~= 'table' then return nil end
  local dx = (a.x or 0) - (b.x or 0)
  local dy = (a.y or 0) - (b.y or 0)
  return math.sqrt(dx * dx + dy * dy)
end

function M.sum(list)
  local total = 0
  for _, v in ipairs(list) do total = total + v end
  return total
end

--- Apply `fn` over a list, returning a new list.
function M.map(list, fn)
  local out = {}
  for i, v in ipairs(list) do out[i] = fn(v, i) end
  return out
end

--- Keep elements of `list` for which `pred` is truthy.
function M.filter(list, fn)
  local out = {}
  for _, v in ipairs(list) do
    if fn(v) then out[#out + 1] = v end
  end
  return out
end

--- True if any element satisfies `pred`.
function M.any(list, pred)
  for _, v in ipairs(list) do
    if pred(v) then return true end
  end
  return false
end

--- Number of key/value pairs in a table (works for maps and arrays).
function M.count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

--- Sorted list of a table's keys (stable, comparable keys only).
function M.sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta == tb then return a < b end
    return ta < tb
  end)
  return keys
end

--- Shallow copy.
function M.copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

--- Deep copy (tables only; functions/metatables are shared).
function M.deepCopy(v)
  if type(v) ~= 'table' then return v end
  local out = {}
  for k, val in pairs(v) do out[k] = M.deepCopy(val) end
  return out
end

--- Deep-merge `overrides` onto a deep copy of `base`. Arrays are replaced, not merged.
function M.merge(base, overrides)
  local out = M.deepCopy(base)
  if type(overrides) ~= 'table' then return out end
  for k, v in pairs(overrides) do
    if type(v) == 'table' and type(out[k]) == 'table' and not (v[1] ~= nil or out[k][1] ~= nil) then
      out[k] = M.merge(out[k], v)
    else
      out[k] = M.deepCopy(v)
    end
  end
  return out
end

--- Index a list by a key function or field name. Later entries win.
function M.indexBy(list, key)
  local get = type(key) == 'function' and key or function(item) return item[key] end
  local out = {}
  for _, item in ipairs(list or {}) do
    local k = get(item)
    if k ~= nil then out[k] = item end
  end
  return out
end

--- First element satisfying `pred` (or nil).
function M.firstWhere(list, pred)
  for _, v in ipairs(list or {}) do
    if pred(v) then return v end
  end
  return nil
end

--- Compact a list: drop holes/nil entries and re-index in ascending key order.
--- Uses pairs (not ipairs) so it can actually see past a hole.
function M.compact(list)
  local keys = {}
  for k, v in pairs(list or {}) do
    if type(k) == 'number' and v ~= nil then keys[#keys + 1] = k end
  end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = list[k] end
  return out
end

--- Render a number with thin thousands separators: 1234567 -> "1,234,567".
function M.formatNumber(n)
  if type(n) ~= 'number' then return tostring(n) end
  local sign = n < 0 and '-' or ''
  local s = tostring(math.floor(math.abs(n)))
  local out = s:reverse():gsub('(%d%d%d)', '%1,')
  out = out:reverse()
  if out:sub(1, 1) == ',' then out = out:sub(2) end
  return sign .. out
end

--- Round a value to a step (useful for snapping camera/scoring buckets).
function M.quantize(v, step)
  if step <= 0 then return v end
  return math.floor(v / step + 0.5) * step
end

return M
