-- scripts/idle/json.lua
-- A minimal, deterministic JSON codec, for the engine <-> host bridge (docs/bridge-api.md).
--
-- WHY HAND-ROLLED: the mod may not take dependencies, and OpenMW's Lua is sandboxed with
-- no JSON library. This is small enough to be worth owning: encode for responses and
-- heartbeat telemetry, decode for incoming requests.
--
-- DETERMINISM: object keys are emitted in sorted order. Two identical tables must produce
-- identical bytes, or a log diff cannot tell "nothing changed" from "everything did" --
-- the same reason the snapshots are sorted before they are stored.
--
-- PURE. No engine access, so the codec is fully testable.

local M = {}

local escapes = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escapeChar(char)
  return escapes[char] or ('\\u%04x'):format(char:byte())
end

local function encodeString(text)
  return '"' .. text:gsub('[%z\1-\31\\"]', escapeChar) .. '"'
end

--- Is this a genuine JSON array (a table with 1..n integer keys and no others)?
---
--- NOTE the empty case: an empty Lua table encodes as `{}` (an object), not `[]`. A Lua
--- table is a map first, so an empty one makes no claim to be a sequence, and a host that
--- receives `{}` can still treat it as empty. Callers that specifically mean an array
--- should say so in the response shape rather than rely on this guessing.
local function isArray(value)
  local count = 0
  for key in pairs(value) do
    if type(key) ~= 'number' then return false end
    count = count + 1
  end
  if count == 0 then return false end
  for index = 1, count do
    if value[index] == nil then return false end
  end
  return true
end

local function encodeNumber(value)
  if value ~= value then return 'null' end                 -- NaN is not JSON
  if value == math.huge or value == -math.huge then return 'null' end
  if value == math.floor(value) and math.abs(value) < 1e15 then
    return ('%d'):format(value)
  end
  return ('%.6g'):format(value)
end

local encodeValue

local function encodeTable(value)
  if isArray(value) then
    local parts = {}
    for index = 1, #value do parts[index] = encodeValue(value[index]) end
    return '[' .. table.concat(parts, ',') .. ']'
  end

  -- an object: sorted keys, so the output is stable
  local keys = {}
  for key in pairs(value) do
    if type(key) == 'string' or type(key) == 'number' then keys[#keys + 1] = key end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = encodeString(tostring(key)) .. ':' .. encodeValue(value[key])
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

encodeValue = function(value)
  local kind = type(value)
  if value == nil then return 'null' end
  if kind == 'boolean' then return value and 'true' or 'false' end
  if kind == 'number' then return encodeNumber(value) end
  if kind == 'string' then return encodeString(value) end
  if kind == 'table' then return encodeTable(value) end
  -- engine objects (userdata) cannot be serialised: say so rather than emitting garbage
  if kind == 'userdata' then return '"<userdata>"' end
  return encodeString('<' .. kind .. '>')
end

--- Encode a value to a JSON string.
--- @param value any
--- @return string
function M.encode(value)
  local ok, text = pcall(encodeValue, value)
  if ok then return text end
  return '{"error":"unencodable","detail":' .. encodeString(tostring(text)) .. '}'
end

-- ---------------------------------------------------------------------------
-- decoding
-- ---------------------------------------------------------------------------

-- A small recursive-descent parser. Only what a request line needs: objects, arrays,
-- strings, numbers, booleans, null. Deliberately strict -- a bridge that accepts malformed
-- input silently is a bridge that answers the wrong question.
local function skipSpace(text, position)
  local _, last = text:find('^[ \t\r\n]*', position)
  return (last or position - 1) + 1
end

local parseValue

local function parseString(text, position)
  local out, index = {}, position + 1
  while index <= #text do
    local char = text:sub(index, index)
    if char == '"' then return table.concat(out), index + 1 end
    if char == '\\' then
      local code = text:sub(index + 1, index + 1)
      local simple = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b',
                       f = '\f', n = '\n', r = '\r', t = '\t' }
      if simple[code] then
        out[#out + 1] = simple[code]
        index = index + 2
      elseif code == 'u' then
        local hex = text:sub(index + 2, index + 5)
        local code_point = tonumber(hex, 16)
        if not code_point then return nil end
        -- encode as UTF-8; enough for the ASCII text a request carries
        if code_point < 0x80 then
          out[#out + 1] = string.char(code_point)
        elseif code_point < 0x800 then
          out[#out + 1] = string.char(0xC0 + math.floor(code_point / 64),
            0x80 + code_point % 64)
        else
          out[#out + 1] = string.char(0xE0 + math.floor(code_point / 4096),
            0x80 + math.floor(code_point / 64) % 64, 0x80 + code_point % 64)
        end
        index = index + 6
      else
        return nil
      end
    else
      out[#out + 1] = char
      index = index + 1
    end
  end
  return nil
end

parseValue = function(text, position)
  position = skipSpace(text, position)
  local char = text:sub(position, position)
  if char == '' then return nil end

  if char == '{' then
    local object, index = {}, skipSpace(text, position + 1)
    if text:sub(index, index) == '}' then return object, index + 1 end
    while true do
      local key, afterKey = parseString(text, index)
      if not key then return nil end
      index = skipSpace(text, afterKey)
      if text:sub(index, index) ~= ':' then return nil end
      local value
      value, index = parseValue(text, index + 1)
      if index == nil then return nil end
      object[key] = value
      index = skipSpace(text, index)
      local separator = text:sub(index, index)
      if separator == ',' then index = skipSpace(text, index + 1)
      elseif separator == '}' then return object, index + 1
      else return nil end
    end
  elseif char == '[' then
    local array, index = {}, skipSpace(text, position + 1)
    if text:sub(index, index) == ']' then return array, index + 1 end
    while true do
      local value
      value, index = parseValue(text, index)
      if index == nil then return nil end
      array[#array + 1] = value
      index = skipSpace(text, index)
      local separator = text:sub(index, index)
      if separator == ',' then index = skipSpace(text, index + 1)
      elseif separator == ']' then return array, index + 1
      else return nil end
    end
  elseif char == '"' then
    local text2, after = parseString(text, position)
    if not text2 then return nil end
    return text2, after
  elseif text:sub(position, position + 3) == 'true' then
    return true, position + 4
  elseif text:sub(position, position + 4) == 'false' then
    return false, position + 5
  elseif text:sub(position, position + 3) == 'null' then
    return nil, position + 4
  else
    local number = text:match('^-?%d+%.?%d*[eE]?[-+]?%d*', position)
    if number and #number > 0 then
      return tonumber(number), position + #number
    end
    return nil
  end
end

--- Decode one JSON value. Returns nil plus a reason when the text is not valid JSON.
--- @param text string
--- @return any value, string|nil error
function M.decode(text)
  if type(text) ~= 'string' then return nil, 'not a string' end
  local trimmed = text:gsub('^%s+', ''):gsub('%s+$', '')
  if trimmed == '' then return nil, 'empty' end
  local ok, value, position = pcall(parseValue, trimmed, 1)
  if not ok then return nil, tostring(value) end
  if position == nil then return nil, 'malformed JSON' end
  local trailing = trimmed:sub(skipSpace(trimmed, position))
  if trailing ~= '' then return nil, 'trailing text after the value' end
  return value, nil
end

return M
