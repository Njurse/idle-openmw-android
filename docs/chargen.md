# Character creation

Where the new-game flow actually goes, what blocks it, and what the mod can and cannot do
about it. Written from a live run on the **forked 0.52 engine** (`docs/engine-build.md`),
because that is the engine the super goal (`docs/scope.md`) needs.

## The signal the mod reads

`types.Player.isCharGenFinished(player)` is `getGlobalFloat("chargenstate") == -1`
(`apps/openmw/mwlua/types/player.cpp:438`). The engine sets that global:

- **`1`** on a real new game — `worldimp.cpp:290`, guarded by `if (!bypass)`.
- **`-1`** only on a **bypass** new game — `worldimp.cpp:293` (`--skip-menu=1` *without*
  `--new-game`), which is what `tools/dev/desktop/into-world.sh` uses.

So on a real new game the flag starts at `1`, and **something else** has to set it to `-1`.

## Who finishes chargen: the ESM script, not the dialogs

Grepping the engine for a writer of `chargenstate` finds only those two lines. The dialogs
(`apps/openmw/mwgui/charactercreation.cpp`) never touch it — even `onReviewDialogDone`
only removes the review window and pops the GUI mode (`charactercreation.cpp:305`).

That leaves the Morrowind `CharGen` script in `Morrowind.esm`: it is what sets
`chargenstate` to `-1` when the sequence ends. And an MWScript game script only advances
while the **world is unpaused** — which is exactly the state chargen does not hold.

## What a live run showed (measured, not inferred)

Driving `--skip-menu=1 --new-game=1` on the fork, with input synthesis
(`tools/dev/desktop/input.py`, SendInput — verified to land: typing a name and pressing
Enter advanced the dialog and the voice markers moved `chargenname2 -> chargenname3`):

| Observation | Source |
|---|---|
| The mod reaches chargen and holds fire | `idle-openmw: phase -> chargen`, `screen -> ChargenName` |
| The name prompt accepts typed text | console/typing worked; dialog advanced |
| After the last dialog the world is **paused with no pause tags** | bridge `ui` -> `blocked:true, blockedCause:"unknown"`; `world.pauseTags` -> `pause tags = (none); paused = true` |
| The UI mode stack is empty, yet a window is on screen | bridge `ui` -> `uiModes:{}`, `uiKind:"world"`; a screenshot still shows a dialog |
| `chargenstate` is still `1` | bridge `ui` -> `charGenDone:"false"`, `lifecycle: ... charGenFinished=false` |
| The player is at the origin | bridge `ui` -> `position:{x:0,y:0,z:0}` |

A paused world with **no pause tags** is one of: the console visible, the post-processor
HUD up, an interactive message box, or no game loaded (`datetimemanager.cpp:259`). The
message box is the candidate that fits "a window is visible but the mode stack is empty".
`tools/dev/desktop/dismiss.py` (Space / Return / centre-click, 6 attempts) did **not**
clear it, so either it is a message box with a specific button, or it is not a message box.

## The two honest conclusions

1. **Lua cannot finish chargen.** There is no API to set a global, no API to click a native
   widget, and the engine's own completion path runs in an ESM script that needs an
   unpaused world. This is fork reason #2 in `docs/engine-build.md`.
2. **The mod must not try.** `scripts/idle/lifecycle.lua` gates on the flag and on a
   `Chargen*` UI mode; that gate is correct and worked — the director never fought the
   dialogs.

## What would actually finish it (the next engine task)

Two options, both engine-side, in increasing effort:

1. **A Lua binding to complete chargen** — one function that does what `worldimp.cpp:290`
   does in reverse (`setInteger(-1)`) plus releasing player controls. Small, and enough for
   the mod to *finish* a chargen the player started. It does **not** choose a race/class.
2. **Expose the chargen dialogs** — the real goal: let the mod name the character, pick a
   race/class/birthsign, and hand back. That is `CharacterCreation`'s `mCreationStage` made
   reachable (or a scripted path that drives it), and it is what "go through character
   creation" in `docs/scope.md` actually means.

Until one of those exists, the world is reached the documented way
(`tools/dev/desktop/into-world.sh`), and Android chargen stays blocked behind the same door.

## Reproducing the observation

```bash
# the engine must survive between calls, so run it as a background job
cd /f/OpenMW-build/build && ./openmw.exe --skip-menu=1 --new-game=1 \
  --user-data "$USERPROFILE/Documents/My Games/OpenMW"

# observation channel (answers even while paused)
{"id":1,"method":"ui"}            # -> blocked, blockedCause, charGenDone, lifecycle
{"id":2,"method":"world.pauseTags"}   # -> the warden's answer, in the log
```
