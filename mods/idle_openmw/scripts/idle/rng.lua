-- scripts/idle/rng.lua
-- Deterministic, portable pseudo-random numbers.
--
-- Why not math.random?  Its sequence is implementation-defined and, more
-- importantly, we want *reproducible* simulations: the headless harness must be
-- able to replay the exact same 1000 game-hours on every machine. A seeded
-- Park-Miller LCG gives that with only double arithmetic (so it behaves
-- identically under LuaJIT and PUC Lua).
--
-- 16807 * 2147483646 ~= 3.6e13, comfortably inside the 2^53 exactly-representable
-- integer range of a double, so the modulo is exact.

local M = {}

local A = 16807
local MODULO = 2147483647 -- 2^31 - 1 (Mersenne prime)

local RNG = {}
RNG.__index = RNG

--- Coerce any number into a valid non-zero seed.
function M.coerceSeed(seed)
  seed = tonumber(seed) or 1
  seed = math.floor(math.abs(seed)) % MODULO
  if seed == 0 then seed = 1 end
  return seed
end

--- Create a generator. `seed` may be omitted (defaults to 1).
function M.new(seed)
  return setmetatable({ state = M.coerceSeed(seed) }, RNG)
end

--- Advance the generator; returns an integer in [1, MODULO-1].
function RNG:nextUInt()
  self.state = (A * self.state) % MODULO
  return self.state
end

--- Uniform float in (0, 1).
function RNG:float()
  return self:nextUInt() / MODULO
end

--- Uniform float in [0, 1).
function RNG:float01()
  return (self:nextUInt() - 1) / MODULO
end

--- Uniform integer in [lo, hi] inclusive.
function RNG:range(lo, hi)
  lo, hi = math.floor(lo), math.floor(hi)
  if hi <= lo then return lo end
  return lo + math.floor(self:float01() * (hi - lo + 1))
end

--- Uniform float in [lo, hi).
function RNG:uniform(lo, hi)
  return lo + self:float01() * (hi - lo)
end

--- True with probability `p` (clamped to [0,1]).
function RNG:chance(p)
  if p <= 0 then return false end
  if p >= 1 then return true end
  return self:float01() < p
end

--- Pick one element uniformly (nil for an empty list).
function RNG:choice(list)
  local n = #list
  if n == 0 then return nil end
  return list[self:range(1, n)]
end

--- Fisher-Yates shuffle; returns the same (now shuffled) list.
function RNG:shuffle(list)
  for i = #list, 2, -1 do
    local j = self:range(1, i)
    list[i], list[j] = list[j], list[i]
  end
  return list
end

--- Pick an element with probability proportional to `weightOf(item)`.
--- Items with non-positive weight are skipped. Returns nil if all weights <= 0.
function RNG:weightedChoice(list, weightOf)
  local total = 0
  local weights = {}
  for i, item in ipairs(list) do
    local w = weightOf(item) or 0
    if w < 0 then w = 0 end
    weights[i] = w
    total = total + w
  end
  if total <= 0 then return nil end
  local roll = self:float01() * total
  local acc = 0
  for i, item in ipairs(list) do
    acc = acc + weights[i]
    if roll < acc then return item end
  end
  return list[#list]
end

--- Multiplicative jitter: base * (1 + (2u-1)*fraction). Deterministic per call.
function RNG:jitter(base, fraction)
  if not fraction or fraction == 0 then return base end
  return base * (1 + (self:float01() * 2 - 1) * fraction)
end

--- Serializable state (persist alongside the save).
function RNG:getState() return self.state end

function RNG:setState(state)
  self.state = M.coerceSeed(state)
  return self
end

return M
