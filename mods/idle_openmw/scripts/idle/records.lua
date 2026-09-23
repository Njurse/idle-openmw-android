-- scripts/idle/records.lua
-- Shaping the engine's read-only dialogue records (core.dialogue.*) into something a host can
-- use.
--
-- WHAT CHANGED HERE
-- The project used to describe dialogue as "observe-only", and that is true of *interaction* --
-- there is still no way to pick a topic. But the RECORDS are fully readable, and they are the
-- interesting half:
--
--   core.dialogue.journal.records[id]     -> .questName, .infos[] with .questStage,
--                                            .isQuestFinished, .text (the journal entry)
--   core.dialogue.topic.records[id]       -> .infos[].text (what an NPC can actually say)
--   core.dialogue.voice.records[id]       -> .infos[].sound (a sound file) + .text
--   core.dialogue.greeting/persuasion     -> the same shape
--
-- (Citations in docs/openmw-lua-api.md section 14, from the engine's own reference.) So a quest
-- can be *named*, its current stage's journal text read, and the line for a topic retrieved --
-- which is what a journal screen and a quest-destination resolver need.
--
-- TWO THINGS THIS MODULE IS CAREFUL ABOUT
--
--   1. **Bounded.** `topic` alone has thousands of records and some have hundreds of infos.
--      A read that dumps everything is a request that never returns. Infos are capped and the
--      count that was dropped is REPORTED (`infosTruncated`), because silently returning 40 of
--      300 entries would look like the record only has 40.
--   2. **Text is a template.** Morrowind's text carries placeholders: `%PCName`,
--      `%NextPCRank`, `%Cell`, and so on. The engine substitutes them at display time; a raw
--      read does not. So `substitute` fills in what we can actually know and leaves the rest
--      alone, rather than printing "%PCName" at a user or inventing a value.
--
-- PURE -- no engine, no clock.

local M = {}

--- The record families the engine exposes, in a fixed order so output is stable.
M.FAMILIES = { 'journal', 'topic', 'greeting', 'persuasion', 'voice' }

--- How many info entries to return per record by default, and how long each may be.
--- Both are deliberately small: these payloads cross a file into a phone.
M.DEFAULT_MAX_INFOS = 25
M.DEFAULT_MAX_TEXT = 400

--- The placeholders we can fill in ourselves. Anything not listed is left verbatim, because a
--- wrong substitution is worse than a visible placeholder.
--- @param vars table name -> value (e.g. { PCName = 'DeepSeek' })
--- @param text string
--- @return string text, number substituted
function M.substitute(text, vars)
  if type(text) ~= 'string' or type(vars) ~= 'table' then return text, 0 end
  local count = 0
  local out = text:gsub('%%([A-Za-z][A-Za-z0-9]*)', function(name)
    local value = vars[name]
    if value == nil then return '%' .. name end
    count = count + 1
    return tostring(value)
  end)
  return out, count
end

--- Collapse whitespace and clamp to `limit` bytes without splitting a character.
---
--- Dialogue text is full of newlines and runs of spaces (it is stored as typed, wrapped), so a
--- raw read looks ragged.
function M.tidy(text, limit)
  if type(text) ~= 'string' then return nil end
  local out = text:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
  limit = limit or M.DEFAULT_MAX_TEXT
  if #out <= limit then return out end
  -- cut on a byte boundary that is not mid-character
  local cut = out:sub(1, limit)
  while #cut > 0 and cut:byte(-1) and cut:byte(-1) >= 128 and cut:byte(-1) < 192 do
    cut = cut:sub(1, #cut - 1)
  end
  -- then drop the partial word, so we never end on "congratulat"
  cut = cut:gsub('%s+%S*$', '')
  if cut == '' then cut = out:sub(1, limit) end
  return cut
end

--- One info entry (a journal entry, an NPC line, a voice line) -> a plain table.
function M.shapeInfo(raw, opts)
  if type(raw) ~= 'table' then return nil end
  opts = opts or {}
  local out = {
    id = raw.id,
    text = M.tidy(raw.text, opts.maxText),
  }
  if opts.vars then out.text, out.substituted = M.substitute(out.text, opts.vars) end
  -- journal-only fields: present or absent, never defaulted to a made-up value
  if raw.questStage ~= nil then out.questStage = raw.questStage end
  if raw.isQuestFinished ~= nil then out.questFinished = raw.isQuestFinished end
  if raw.isQuestRestart ~= nil then out.questRestart = raw.isQuestRestart end
  if raw.isQuestName ~= nil then out.questNameEntry = raw.isQuestName end
  -- the voice family's payload: which file the line is
  if raw.sound ~= nil then out.sound = raw.sound end
  -- the speaking conditions, which say WHICH actor could say this line
  if raw.filterActorId ~= nil then out.filterActor = raw.filterActorId end
  if raw.filterActorRace ~= nil then out.filterActorRace = raw.filterActorRace end
  if raw.filterActorClass ~= nil then out.filterActorClass = raw.filterActorClass end
  if raw.filterActorFaction ~= nil then out.filterActorFaction = raw.filterActorFaction end
  if raw.filterActorFactionRank ~= nil then out.filterActorFactionRank = raw.filterActorFactionRank end
  return out
end

--- A whole record -> a plain table, with the info list capped and the cap reported.
---
--- `raw.infos` is a read-only engine list; it may be indexed by number (and, for records,
--- `#` works), so it is walked by index rather than with pairs.
function M.shapeRecord(raw, opts)
  if type(raw) ~= 'table' then return nil end
  opts = opts or {}
  local maxInfos = opts.maxInfos or M.DEFAULT_MAX_INFOS

  local out = {
    id = raw.id,
    name = raw.name,
    family = opts.family,
  }
  if raw.questName ~= nil then out.questName = raw.questName end

  local infos = raw.infos
  local total = 0
  if type(infos) == 'table' then
    local ok = pcall(function() total = #infos end)
    if not ok then total = 0 end
  end

  out.infosTotal = total
  local shaped = {}
  for index = 1, math.min(total, maxInfos) do
    local one = M.shapeInfo(infos[index], opts)
    if one then shaped[#shaped + 1] = one end
  end
  out.infos = shaped
  -- say what was dropped, so a partial read cannot be mistaken for a whole one
  if total > #shaped then
    out.infosTruncated = total - #shaped
  end
  return out
end

--- The family table a read returned, as a sorted list of { family, count }.
---
--- `core.dialogue.<family>.records` can be counted with `#`, and that is cheap enough to run for
--- discovery -- but only the COUNT is taken, never the records themselves, because enumerating
--- thousands of records to answer "what is there?" would be absurd.
function M.familyCounts(counts)
  local out = {}
  for _, family in ipairs(M.FAMILIES) do
    local count = type(counts) == 'table' and counts[family] or nil
    if count ~= nil then out[#out + 1] = { family = family, records = count } end
  end
  return out
end

--- The journal entries for one quest stage, in record order.
---
--- This is the join between the player's quest state (`types.Player.quests` gives a stage) and
--- the record that says what that stage MEANS. Returns an empty list for a stage with no entry
--- rather than a guess.
function M.entriesForStage(record, stage)
  local out = {}
  if type(record) ~= 'table' or type(record.infos) ~= 'table' then return out end
  for _, info in ipairs(record.infos) do
    if info.questStage ~= nil and tonumber(info.questStage) == tonumber(stage) then
      out[#out + 1] = info
    end
  end
  return out
end

--- Is this record's text a finished-state entry? Used to explain why a quest is done.
function M.isFinished(record)
  if type(record) ~= 'table' or type(record.infos) ~= 'table' then return false end
  for _, info in ipairs(record.infos) do
    if info.questFinished == true then return true end
  end
  return false
end

return M
