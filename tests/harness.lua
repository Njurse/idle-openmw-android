-- tests/harness.lua
-- A dependency-free, Lua 5.1 / LuaJIT-compatible test harness.
--
-- Why not busted/luaunit?  The target runs on OpenMW's LuaJIT *and* must be
-- runnable headlessly on a dev box and (eventually) on-device with zero
-- luarocks.  This harness needs nothing but the standard library.
--
-- Usage (from tests/run.lua):
--   local harness = require('tests.harness')
--   harness.install()            -- exposes describe/it/expect/assert globally
--   harness.run()                -- executes collected tests
--   harness.report()             -- prints results, returns true if green

local H = {}

-- ---------------------------------------------------------------------------
-- tiny helpers
-- ---------------------------------------------------------------------------

local function isCallable(v) return type(v) == 'function' end

local function deepEqual(a, b, seen)
  if a == b then return true end
  local ta, tb = type(a), type(b)
  if ta ~= tb then return false end
  if ta ~= 'table' then return false end

  seen = seen or {}
  if seen[a] and seen[a][b] then return true end
  seen[a] = seen[a] or {}
  seen[a][b] = true

  for k, v in pairs(a) do
    if not deepEqual(v, b[k], seen) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function serialize(v, depth)
  depth = depth or 0
  local t = type(v)
  if t == 'string' then return string.format('%q', v) end
  if t ~= 'table' then return tostring(v) end
  if depth > 4 then return '{...}' end
  local parts = {}
  local n = 0
  for k, val in pairs(v) do
    n = n + 1
    if n > 24 then parts[#parts + 1] = '...' break end
    parts[#parts + 1] = tostring(k) .. '=' .. serialize(val, depth + 1)
  end
  return '{' .. table.concat(parts, ', ') .. '}'
end

H.serialize = serialize
H.deepEqual = deepEqual

-- ---------------------------------------------------------------------------
-- assertion error
-- ---------------------------------------------------------------------------

local AssertionError = {}
AssertionError.__index = AssertionError
function AssertionError:__tostring() return self.message end

local function fail(message, level)
  error(setmetatable({ isAssertion = true, message = message,
                       traceback = debug.traceback('', (level or 3) + 1) }, AssertionError), 0)
end

H.fail = fail

-- ---------------------------------------------------------------------------
-- expect() matchers
-- ---------------------------------------------------------------------------

local Matchers = {}
local matcherMeta

local function matcherFail(self, msg)
  fail(msg, 4)
end

function Matchers:toBe(expected)
  if self.value ~= expected then
    matcherFail(self, ('expected %s to be %s'):format(serialize(self.value), serialize(expected)))
  end
  return self
end
Matchers.equals = Matchers.toBe
Matchers.toEqual = Matchers.toBe

function Matchers:toEqualDeep(expected)
  if not deepEqual(self.value, expected) then
    matcherFail(self, ('expected %s to deeply equal %s'):format(serialize(self.value), serialize(expected)))
  end
  return self
end

function Matchers:toBeTrue()
  if self.value ~= true then
    matcherFail(self, ('expected %s to be true'):format(serialize(self.value)))
  end
  return self
end

function Matchers:toBeFalse()
  if self.value ~= false then
    matcherFail(self, ('expected %s to be false'):format(serialize(self.value)))
  end
  return self
end

function Matchers:toBeNil()
  if self.value ~= nil then
    matcherFail(self, ('expected %s to be nil'):format(serialize(self.value)))
  end
  return self
end

function Matchers:toBeTruthy()
  if not self.value then
    matcherFail(self, ('expected %s to be truthy'):format(serialize(self.value)))
  end
  return self
end

function Matchers:toBeFalsy()
  if self.value then
    matcherFail(self, ('expected %s to be falsy'):format(serialize(self.value)))
  end
  return self
end

function Matchers:toBeType(expected)
  local t = type(self.value)
  if t ~= expected then
    matcherFail(self, ('expected type %s but got %s (%s)'):format(expected, t, serialize(self.value)))
  end
  return self
end

function Matchers:toBeCloseTo(expected, tolerance)
  tolerance = tolerance or 1e-9
  local diff = math.abs((self.value or 0) - expected)
  if diff > tolerance then
    matcherFail(self, ('expected %s to be close to %s (tolerance %s, diff %s)')
      :format(serialize(self.value), serialize(expected), tostring(tolerance), tostring(diff)))
  end
  return self
end

local function numericCompare(self, expected, wantGreater, label)
  if type(self.value) ~= 'number' then
    matcherFail(self, ('expected a number to compare, got %s'):format(serialize(self.value)))
  end
  local ok = wantGreater and (self.value > expected) or (self.value < expected)
  if not ok then
    matcherFail(self, ('expected %s to be %s %s'):format(tostring(self.value), label, tostring(expected)))
  end
  return self
end

function Matchers:toBeGreaterThan(expected) return numericCompare(self, expected, true, 'greater than') end
function Matchers:toBeLessThan(expected) return numericCompare(self, expected, false, 'less than') end

function Matchers:toBeGreaterThanOrEqual(expected)
  if not (type(self.value) == 'number' and self.value >= expected) then
    matcherFail(self, ('expected %s to be >= %s'):format(tostring(self.value), tostring(expected)))
  end
  return self
end

function Matchers:toBeLessThanOrEqual(expected)
  if not (type(self.value) == 'number' and self.value <= expected) then
    matcherFail(self, ('expected %s to be <= %s'):format(tostring(self.value), tostring(expected)))
  end
  return self
end

function Matchers:toContain(needle)
  local v = self.value
  if type(v) == 'table' then
    if v[needle] ~= nil then return self end
    for _, item in pairs(v) do
      if item == needle or deepEqual(item, needle) then return self end
    end
  elseif type(v) == 'string' and type(needle) == 'string' then
    if string.find(v, needle, 1, true) then return self end
  end
  matcherFail(self, ('expected %s to contain %s'):format(serialize(v), serialize(needle)))
end

function Matchers:toHaveLength(n)
  local len = (type(self.value) == 'table' and #self.value) or (type(self.value) == 'string' and #self.value)
  if len ~= n then
    matcherFail(self, ('expected length %s but got %s'):format(tostring(n), tostring(len)))
  end
  return self
end

function Matchers:toThrow()
  if not isCallable(self.value) then
    matcherFail(self, ('expected a function to call, got %s'):format(serialize(self.value)))
  end
  local ok = pcall(self.value)
  if ok then
    matcherFail(self, 'expected function to throw, but it did not')
  end
  return self
end

matcherMeta = { __index = Matchers }

function H.expect(value)
  return setmetatable({ value = value }, matcherMeta)
end

-- ---------------------------------------------------------------------------
-- luaunit-ish `assert` extensions (kept for parity with the project plan)
-- ---------------------------------------------------------------------------

local A = {}

function A.is_true(v) if v ~= true then fail('expected true but got ' .. serialize(v)) end return v end
function A.is_false(v) if v ~= false then fail('expected false but got ' .. serialize(v)) end return v end
function A.is_nil(v) if v ~= nil then fail('expected nil but got ' .. serialize(v)) end return v end
function A.is_not_nil(v) if v == nil then fail('expected a value but got nil') end return v end
function A.is_table(v) if type(v) ~= 'table' then fail('expected table but got ' .. type(v)) end return v end
function A.is_string(v) if type(v) ~= 'string' then fail('expected string but got ' .. type(v)) end return v end
function A.is_number(v) if type(v) ~= 'number' then fail('expected number but got ' .. type(v)) end return v end
function A.equals(a, b)
  if a ~= b then fail(('expected %s to equal %s'):format(serialize(a), serialize(b))) end
  return a
end
A.equal = A.equals
function A.are_equal(a, b) return A.equals(a, b) end
function A.not_equals(a, b)
  if a == b then fail(('expected %s to differ from %s'):format(serialize(a), serialize(b))) end
  return a
end
function A.near(a, b, tol)
  tol = tol or 1e-9
  if math.abs(a - b) > tol then
    fail(('expected %s to be near %s (tol %s)'):format(tostring(a), tostring(b), tostring(tol)))
  end
  return a
end
function A.gt(a, b) if not (a > b) then fail(('%s not > %s'):format(tostring(a), tostring(b))) end return a end
function A.lt(a, b) if not (a < b) then fail(('%s not < %s'):format(tostring(a), tostring(b))) end return a end
function A.gte(a, b) if not (a >= b) then fail(('%s not >= %s'):format(tostring(a), tostring(b))) end return a end
function A.lte(a, b) if not (a <= b) then fail(('%s not <= %s'):format(tostring(a), tostring(b))) end return a end
function A.is_error(fn)
  if not isCallable(fn) then fail('assert.is_error expects a function') end
  if pcall(fn) then fail('expected function to error') end
end
function A.has_error(fn) A.is_error(fn) end

H.assertions = A

-- ---------------------------------------------------------------------------
-- collection + execution
-- ---------------------------------------------------------------------------

local COLORS = {
  red = '\27[31m', green = '\27[32m', yellow = '\27[33m',
  cyan = '\27[36m', dim = '\27[2m', bold = '\27[1m', reset = '\27[0m',
}
local useColor = true

local function color(name, s)
  if not useColor then return s end
  return (COLORS[name] or '') .. s .. COLORS.reset
end

local root = { name = nil, parent = nil, before = {}, after = {}, tests = {}, children = {} }
local current = root

local function newSuite(name)
  return { name = name, parent = current, before = {}, after = {}, tests = {}, children = {} }
end

function H.describe(name, body)
  local suite = newSuite(name)
  current.children[#current.children + 1] = suite
  local prev = current
  current = suite
  local ok, err = pcall(body)
  current = prev
  if not ok then
    -- a describe body that throws is a hard error at collection time
    suite.collectionError = err
  end
  return suite
end

function H.it(name, body)
  if not current.tests then current.tests = {} end
  current.tests[#current.tests + 1] = { name = name, body = body }
end

function H.before_each(fn) current.before[#current.before + 1] = fn end
function H.after_each(fn) current.after[#current.after + 1] = fn end
H.xit = function(name) H.it(name .. ' [pending]', nil) end

function H.install()
  _G.describe = H.describe
  _G.it = H.it
  _G.xit = H.xit
  _G.before_each = H.before_each
  _G.after_each = H.after_each
  _G.expect = H.expect
  -- Replace the global `assert` with a callable table: still usable as
  -- assert(cond, msg), but now also carries `.equals`, `.is_true`, ... (a plain
  -- function value cannot be indexed, so luaunit-style assert.* needs this).
  local builtin = _G.assert
  local assertions = setmetatable({}, { __call = function(_, ...) return builtin(...) end })
  for k, v in pairs(A) do assertions[k] = v end
  _G.assert = assertions
end

local function fullName(suite)
  local names = {}
  local s = suite
  while s and s.name do
    table.insert(names, 1, s.name)
    s = s.parent
  end
  return table.concat(names, ' › ')
end

local function collectHooks(suite, field, out)
  if suite.parent then collectHooks(suite.parent, field, out) end
  for _, fn in ipairs(suite[field]) do out[#out + 1] = fn end
end

local function runHooks(hooks)
  for _, fn in ipairs(hooks) do fn() end
end

--- Executes every collected test. Returns a structured result table.
function H.run(opts)
  opts = opts or {}
  if opts.color ~= nil then useColor = opts.color end
  local out = opts.out or io.write

  local results = {
    passed = 0, failed = 0, pending = 0, collectionErrors = 0,
    failures = {}, loadErrors = H._loadErrors or {},
  }

  local function runSuite(suite)
    if suite.collectionError then
      results.collectionErrors = results.collectionErrors + 1
      results.failures[#results.failures + 1] = {
        name = fullName(suite) .. ' (collection)',
        message = 'error while collecting tests: ' .. tostring(suite.collectionError),
      }
      return
    end

    if suite.name then
      out('\n' .. color('cyan', '▸ ' .. fullName(suite)) .. '\n')
    end

    for _, test in ipairs(suite.tests or {}) do
      local label = '  ' .. test.name
      if not test.body then
        results.pending = results.pending + 1
        out(color('yellow', '  ○ ' .. test.name) .. '\n')
      else
        local before, after = {}, {}
        collectHooks(suite, 'before', before)
        collectHooks(suite, 'after', after)
        local ok, err = pcall(function()
          runHooks(before)
          test.body()
        end)
        -- after_each must run even on failure
        local afterOk, afterErr = pcall(runHooks, after)
        if ok and not afterOk then ok, err = false, afterErr end
        if ok then
          results.passed = results.passed + 1
          out(color('green', '  ✓ ') .. test.name .. '\n')
        else
          results.failed = results.failed + 1
          local message = (type(err) == 'table' and err.message) or tostring(err)
          results.failures[#results.failures + 1] = {
            name = fullName(suite) .. ' › ' .. test.name,
            message = message,
            traceback = (type(err) == 'table' and err.traceback) or nil,
          }
          out(color('red', '  ✗ ') .. test.name .. '\n')
          out(color('red', '      ' .. tostring(message)) .. '\n')
        end
      end
      local _ = label
    end

    for _, child in ipairs(suite.children) do runSuite(child) end
  end

  runSuite(root)
  H.results = results
  return results
end

function H.report(results)
  results = results or H.results
  if not results then return false end
  local out = io.write
  out('\n' .. color('bold', '──────────────────────────────────────────────') .. '\n')
  for _, e in ipairs(results.loadErrors or {}) do
    out(color('red', ('LOAD ERROR  %s\n  %s\n'):format(e.name, tostring(e.message))))
  end
  out(('  %s   %s   %s   %s\n'):format(
    color('green', results.passed .. ' passed'),
    color(results.failed > 0 and 'red' or 'dim', results.failed .. ' failed'),
    color('yellow', results.pending .. ' pending'),
    color(#(results.loadErrors or {}) > 0 and 'red' or 'dim', #(results.loadErrors or {}) .. ' load errors')))
  if #results.failures > 0 then
    out('\n' .. color('red', 'Failures:') .. '\n')
    for _, f in ipairs(results.failures) do
      out(color('red', '  ✗ ' .. f.name) .. '\n' .. '      ' .. tostring(f.message) .. '\n')
    end
  end
  out('\n')
  local ok = results.failed == 0 and results.collectionErrors == 0 and #(results.loadErrors or {}) == 0
  out(ok and color('green', '  OK') .. '\n' or color('red', '  FAILED') .. '\n')
  return ok
end

function H.recordLoadError(name, err)
  H._loadErrors = H._loadErrors or {}
  H._loadErrors[#H._loadErrors + 1] = { name = name, message = err }
end

function H.reset()
  root = { name = nil, parent = nil, before = {}, after = {}, tests = {}, children = {} }
  current = root
  H._loadErrors = nil
  H.results = nil
end

return H
