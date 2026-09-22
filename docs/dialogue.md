# Dialogue: what is integrated, and the one thing that cannot be

## The hard limit

Morrowind's dialogue is **observe-only** from Lua, and this has not changed
(`docs/openmw-lua-api.md` §4):

- there is **no `onInfoGetText`** — nothing can rewrite or pre-empt a line;
- **`DialogueResponse` is a notification**: it tells you what was said, it cannot
  influence what happens next;
- there is **no API for selecting a dialogue topic** — the topic list is drawn by
  the engine's own window, and `ui.getElements` cannot see it (§11.1).

So the mod can never *choose an answer for you*. Anything that pretends to would
be lying about what the engine allows.

## What IS integrated

Three real things, all from exposed data:

### 1. The topics your character knows — `journal().topics`

`types.Player.journal(player).topics` is a **map** of `topicName -> PlayerJournalTopic`
(types.lua:1383), each carrying every line you have heard for that topic. This is
the closest the engine gets to "the dialogue options you have unlocked": it is the
set of things you can *say* to an NPC. `scripts/runtime/observer.lua` reads it
(`readJournalTopics`) and the console's **Talk** tab lists it under "Topics you
know", with a line count per topic.

### 2. The topics you have actually heard — the dialogue memory

`scripts/idle/dialogue.lua` keeps a pure memory fed by `DialogueResponse` events:
who greeted you, what was said, who refused you. The Talk tab shows "Topics heard"
with counts, and "Recent conversations" as a transcript. This is *observation*,
correctly labelled.

### 3. Talking = walking there and opening the window

Tapping a topic in the Talk tab pushes the `talk` directive: the character walks
to the nearest NPC and activates it, which opens **Morrowind's own dialogue
window**. You then pick the topic there, with the engine's UI, exactly as the game
intends.

That is the honest integration: we surface the *data* and we *take you to the
conversation*, but the conversation itself stays the game's.

## The transcript as a log

Because `DialogueResponse` is a notification, it is also the only dialogue hook we
get, so it is used for observability: every event is forwarded into the director
(`Director:onDialogue`), recorded in the bounded transcript, and appended to the
activity log the phone console shows in its **Log** tab.

## Testing

```
python tools/run_tests.py --only dialogue     # the memory + interpreter
python tools/run_tests.py --only runtime      # readJournalTopics / readPanel
```

The panel contract gained `journalTopics` (`tests/spec/runtime_spec.lua`), and
`uiModel.talkRows` renders it (`tests/spec/uiModel_spec.lua`).
