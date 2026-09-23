-- scripts/idle/narration.lua
-- The one line that says what the mod is doing right now.
--
-- WHY THIS EXISTS
-- ---------------
-- Watching an idle game that plays itself is opaque: the character walks somewhere and
-- you cannot tell whether that was deliberate or a stuck loop. This is the smallest
-- useful answer -- a single line of current intent, drawn on the HUD, replaced as the
-- intent changes. It is deliberately NOT a log: a log is for later, this is for now.
--
-- Two sources:
--   * the director's own line (what the brain decided), and
--   * an optional `narration.txt` in the data folder (scripts/runtime reads it through
--     openmw.vfs), which lets an operator narrate over the top while watching a run.
--
-- PURE. No engine access, so the wrapping and clamping rules are unit-testable.

local M = {}

--- Longest narration we will draw. Long text is not helpful on a phone; it stops being
--- readable at a glance, which is the whole point.
M.MAX_LENGTH = 220

--- Byte length of the ellipsis. NOT 1: '…' is a three-byte UTF-8 sequence, so a
--- byte-based clamp that forgets this overruns its limit by two bytes.
local ELLIPSIS = '…'
local ELLIPSIS_BYTES = #ELLIPSIS

--- Truncate to `limit` BYTES without splitting a UTF-8 character.
--- Morrowind's data is full of accented text, and cutting mid-sequence produces
--- mojibake rather than a clean truncation.
local function utf8Cut(text, limit)
  if #text <= limit then return text end
  local cut = limit
  -- walk back off any continuation byte (0x80..0xBF) so we never split a character
  while cut > 0 do
    local byte = text:byte(cut + 1)
    if byte == nil or byte < 0x80 or byte >= 0xC0 then break end
    cut = cut - 1
  end
  return text:sub(1, cut)
end

--- Collapse whitespace to single spaces.
local function collapse(text)
  return (tostring(text):gsub('%s+', ' '):gsub('^%s', ''):gsub('%s$', ''))
end

--- Make arbitrary text safe to draw on one line: single-spaced, bounded, no newlines.
--- @param text string|nil
--- @param maxLength number|nil
--- @return string
function M.sanitize(text, maxLength)
  if text == nil then return '' end
  local limit = maxLength or M.MAX_LENGTH
  local out = collapse(text)
  if #out > limit then
    -- drop back to a word boundary, then add the ellipsis -- counting its bytes
    local cut = utf8Cut(out, limit - ELLIPSIS_BYTES)
    cut = cut:gsub('%s+%S*$', '')
    if cut == '' then cut = utf8Cut(out, limit - ELLIPSIS_BYTES) end
    out = cut .. ELLIPSIS
  end
  return out
end

--- Word-wrap to at most `columns` characters per line.
---
--- The game itself wraps for us (`wordWrap = true` on the text element), so this exists
--- for the two places that cannot: the headless preview renderer and the specs, which
--- need to know what the player will actually see. A word longer than a line is split
--- rather than allowed to overflow.
--- @param text string
--- @param columns number
--- @return table lines
function M.wrap(text, columns)
  local limit = math.max(8, math.floor(columns or 40))
  local words = {}
  for word in tostring(text or ''):gmatch('%S+') do words[#words + 1] = word end

  local lines, current = {}, ''
  local function flush()
    if current ~= '' then lines[#lines + 1] = current; current = '' end
  end

  for _, word in ipairs(words) do
    while #word > limit do
      flush()
      lines[#lines + 1] = word:sub(1, limit)
      word = word:sub(limit + 1)
    end
    if current == '' then
      current = word
    elseif #current + 1 + #word <= limit then
      current = current .. ' ' .. word
    else
      flush()
      current = word
    end
  end
  flush()
  if #lines == 0 then lines[1] = '' end
  return lines
end

--- A tiny holder for the current line, with a revision so a renderer can skip redraws.
function M.new(initial)
  local state = { text = M.sanitize(initial), revision = 0 }
  local api = {}

  --- @param text string|nil
  --- @return boolean changed
  function api:set(text)
    local nextText = M.sanitize(text)
    if nextText == state.text then return false end
    state.text = nextText
    state.revision = state.revision + 1
    return true
  end

  function api:get() return state.text end
  function api:revision() return state.revision end

  return api
end

--- Choose what to show: an operator's line wins over the mod's own, so someone watching
--- a run can narrate over the top without having to disable anything.
--- @param operatorText string|nil text from narration.txt
--- @param modText string|nil the director's own line
--- @return string
function M.choose(operatorText, modText)
  local operator = M.sanitize(operatorText)
  if operator ~= '' then return operator end
  return M.sanitize(modText)
end

return M
