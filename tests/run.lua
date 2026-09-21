-- tests/run.lua
-- Headless test entry point. Executed by `tools/run_tests.py` under LuaJIT 2.1.
--
-- The runner (Python) is responsible for:
--   * setting `package.path` so `tests.*` and `scripts.*` resolve,
--   * filling the global `HARNESS_SPECS` (list of spec module names),
--   * optionally setting `HARNESS_COLOR` ('0'/'1').
-- It then reads back `HARNESS_RESULT`.

local harness = require('tests.harness')
harness.reset()
harness.install()

-- Unbuffered stdout: lupa writes to the same fd as the Python host, and without
-- this Lua's buffered output interleaves out of order with the host's prints.
pcall(function() io.stdout:setvbuf('no') end)

local specs = _G.HARNESS_SPECS
if not specs then
  local ok, manifest = pcall(require, 'tests.specs')
  if ok and type(manifest) == 'table' then
    specs = manifest
  else
    print('no spec list provided (set HARNESS_SPECS or provide tests/specs.lua)')
    specs = {}
  end
end

for _, name in ipairs(specs) do
  local ok, err = pcall(require, name)
  if not ok then
    harness.recordLoadError(name, err)
  end
end

local colorOpt = _G.HARNESS_COLOR
local results = harness.run({ color = (colorOpt == nil) and true or (colorOpt == '1') })
local ok = harness.report(results)

_G.HARNESS_RESULT = {
  ok = ok,
  passed = results.passed,
  failed = results.failed,
  pending = results.pending,
  loadErrors = #(results.loadErrors or {}),
}

return ok
