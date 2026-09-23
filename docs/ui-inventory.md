# What we can and cannot know about the UI

Driving a real game from outside is mostly a *perception* problem. This is the inventory of
what the engine will tell us, what it will not, and which tool answers which question.

## The three instruments

| Question | Instrument | Where it shows |
|---|---|---|
| What does the world model see? | `observer` snapshot + specs | `tests/spec/observer_spec.lua` |
| What is on screen *right now*? | the **UI report** | engine log, via `dev_command.txt` |
| What does the console look like? | `tools/preview_console.py` | `build/preview/*.png` |

## Triggering a report

Write a line into `mods/idle_openmw/dev_command.txt` (gitignored). The mod polls it through
`openmw.vfs`, which is reliable, unlike injecting keystrokes.

```
ui                 report once  (alias: dump)
heartbeat 10       report every 10s, for monitoring a run
note <text>        set the narration line
stop               clear the heartbeat and the note
```

Then read the engine log. Real example, taken during character creation:

```
== idle-openmw ui report ==
screen         ChargenName          <- the engine naming the open window
phase          chargen
acting         false
paused         true                 <- normal during chargen, NOT a fault
charGenDone    false                <- the actual flag, not the capability
mode           auto
screen size    1600x900
gui scale      1
text scale     1
narration box  160,652 1280x130     <- where the narration is actually drawn
lua elements   <n> (ours only, not the game widgets)
capabilities   Lua API revision 129; all required capabilities present
```

## What IS observable

| Thing | How | Notes |
|---|---|---|
| The open window(s) | `ui._getUiModeStack()` | `uibindings.cpp:276`. Names them: `ChargenName`, `Dialogue`, `Interface`, `Loading`, `Journal`… This is the single most useful signal. |
| Whether the world is paused | `core.isWorldPaused()` | `core.lua:46`. Paused during chargen and modals. |
| Whether chargen is finished | `types.Player.isCharGenFinished` | `player.cpp:438`; `getGlobalFloat("chargenstate") == -1`. |
| Our own elements | `ui.getElements()` | **Only** elements the Lua layer created — see the trap below. |
| Screen size | `ui.screenSize()` | |
| Where we are | `player.position`, cell name | via the snapshot |
| UI mode *transitions* | `onUiModeChanged` handler | plus `UiModeChanged` event with `{oldMode,newMode,arg}` |
| What was clicked | `mousePress`/`mouseRelease` carry position | `widget.cpp:559`/`:566` — `mouseClick` does **not** (`:546`). |
| Screen → world | `camera.viewportToWorldVector` + `nearby.castRay` | how tap-to-move picks. |
| Journal topics | `types.Player.journal(player).topics` | map topic → `{entries}`; `types.lua:1383`. |
| Services an NPC offers | `servicesOffered` | `types.lua:964`. |
| One engine frame's free text | `ui.printToConsole` | `files/lua_api/openmw/ui.lua:65` — it is `ui`, not `core`. |

## What is NOT observable (and the trap each one sets)

- **The engine's own widgets cannot be enumerated.** `ui.getElements()` returns the Lua
  layer's elements only. The chargen dialogs, the journal, the inventory — all invisible to
  it. So "lua elements: 12" says nothing about whether a game window is open. Use the mode
  stack for that.
- **No widget can be pressed programmatically.** There is no "click this button by name".
  Driving a native dialog means computing where its button is (`resources/mygui/*.layout`)
  and injecting a mouse event at that pixel — which is why the layout files are read as
  data and why `MyGUI.log` is worth reading when a coordinate misses.
- **A layout coordinate is not a screen coordinate.** Dialogs are centred and scaled; the
  only trustworthy position is one measured from a captured frame. Recorded after the race
  dialog's declared `(1033,641)` turned out to be nothing of the sort on screen.
- **A text property cannot be set on an element you did not create**, and you cannot assign
  to an element's fields at all — `element.layer = 'HUD'` throws `no defined new_index
  operation on usertype`. Use the mod's `setText` helper.
- **Lua text has no font family** (`components/lua_ui/text.cpp:52`): size, colour, wrap,
  alignment, shadow, multiline — but the font is the engine's. Colours come from our theme.
- **Dialogue is observe-and-open only.** `interfaces.UI.setMode('Dialogue', {target=…})`
  opens it; `DialogueResponse` is notification-only. No API selects a topic.
- **No global-variable read/write** in 0.51: `chargenstate` cannot be read or set from Lua,
  only its `isCharGenFinished` summary.

## Practical lessons (each one cost time)

1. **`paused` is not a fault, but it is not enough.** The world pauses during chargen and
   every modal. Reporting it on change (rather than reacting to it) is what made it stop
   looking like a hang. It became actionable only once the *cause* was reported too — see
   lesson 6.
2. **`minimize on focus loss = true` is the default**, so any harness that brings the window
   forward *minimises the game*, which then takes no input and looks dead.
3. **Engine values are `userdata`, not tables** in 0.51, so `type(x) == 'table'` is false for
   every engine object: `util.isObject` exists for this, and `tests/spec/userdata_spec.lua`
   guards it. This bit the UI read specifically: the mode stack is userdata, so
   `type(stack) == 'table'` called a real open window "empty" and the console reported
   `screen -> empty` while a Dialogue window was open *and* the world was paused. Hence
   `uiState.stackOf` — one reader, used by the observer, the report and the trace, so the
   mistake can only be made once.
4. **Unknown engine handlers fail silently** — `onResolutionChanged` never existed. Guard
   with `tools/dev/check_handlers.py`.
5. **A report must state the reason.** "unavailable" without a cause is worse than nothing.
6. **There are FIVE causes of a stopped world, and they are all in one line of engine code.**
   `apps/openmw/mwworld/datetimemanager.cpp:259`:

   ```cpp
   mPaused = !mPausedTags.empty() || wm->isConsoleMode() || wm->isPostProcessorHudVisible()
          || wm->isInteractiveMessageBoxActive() || stateManager->getState() == State_NoGame;
   ```

   | Cause | How to tell | Whose remedy |
   | --- | --- | --- |
   | pause **tags** | `world.getPausedTags()` (global script only) | whoever took the tag |
   | the **console** is open | `ui.getConsoleMode()` | ours: `ui.setConsoleMode(false)` (bridge `ui.closeConsole`) |
   | the **post-processor HUD** is up | not exposed to Lua | the host |
   | an **interactive message box** | not exposed to Lua; shows as *paused with no tags* | the host (Lua cannot click a widget) |
   | **no game loaded** (`State_NoGame`) | `charGenDone` can be true and the cell can be the right one | the launch/flow, not the mod |

   Two of these are readable from Lua and three are not, which is the whole reason
   `uiState.blocking` reports a *cause* with a hint instead of asserting "message box": a world
   paused with no tags is equally a message box, a cinematic, or so basic a thing as the game
   not being started. Measured live: `pause tags = (none); paused = true` -- which is what sent
   this investigation to that line of C++ in the first place.

7. **There are TWO causes of a stopped world, and they need different remedies.**
   `cause = 'menu'` (a mode is open: the mod can close it itself with
   `interfaces.UI.removeMode`, or open it with `setPauseOnMode(mode, false)` so it never
   pauses at all) versus `cause = 'messageBox'` (the stack is *empty* and the world is still
   paused: Morrowind's messages are not modes, Lua cannot click a native widget, so only the
   **host** can clear it — `tools/dev/desktop/dismiss.py`). `uiState.blocking(paused, stack)`
   is the single place that distinguishes them; a report that says only "paused" leaves the
   caller with nothing to do.

