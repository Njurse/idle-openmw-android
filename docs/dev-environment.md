# The dev environment

How to run, watch, poke at and screenshot a real OpenMW with this mod installed — and
what the tools are for. Written after a session in which the missing piece turned out
not to be a tool at all, but a **version**: the only installed engine (0.48.0) had almost
none of the Lua API this mod needs.

## What is installed

| Thing | Where | Notes |
| --- | --- | --- |
| **OpenMW 0.51.0** (dev) | `F:/Games/OpenMW-0.51` | Side-by-side. `resources/version` = `0.51.0`, Lua API revision **129**. |
| OpenMW 0.48.0 (left alone) | `F:/Games/OpenMW Latest` | **Do not touch.** Used only to prove the mod degrades rather than breaks. |
| Morrowind data | `gamedata/Data Files` | ESM + BSA; the BSAs must be named in `openmw.cfg`. |
| User config | `%USERPROFILE%/Documents/My Games/OpenMW/` | `openmw.cfg` + `settings.cfg`, generated. |
| The mod | `mods/idle_openmw` | Pointed at **live**, so edits apply on the next launch. |

The floor is **0.49+** and the reasons are measured in
`docs/openmw-lua-api.md` ("The supported engine floor").

## Setup (once, or after moving the repo)

```bash
bash tools/dev/desktop/setup-cfg.sh      # write openmw.cfg + settings.cfg, windowed 1600x900
```

`openmw.cfg` points `data=` at the live repo mod and lists
`fallback-archive=Morrowind.bsa` (writing the file by hand means writing the archives
too, or every mesh texture inside the BSA is "not found").

## The everyday loop

```bash
bash tools/dev/desktop/run.sh --fresh-log   # launch (detached), moving the old log aside
bash tools/dev/desktop/errors.sh           # pass/fail: did the mod load, is Lua clean?
bash tools/dev/desktop/log.sh 40           # tail the engine log
bash tools/dev/desktop/shot.ps1 -Out build/desktop/x.png   # capture the game window
```

`errors.sh` is the important one. A Lua error in a PLAYER script **does not stop the
engine** — so a green screenshot can hide a broken mod. It reports "content loaded" and
"no Lua errors" separately for that reason.

### Keep the game alive

A launched engine does not always survive between tool calls. `ensure.sh` makes every
later step idempotent:

```bash
bash tools/dev/desktop/ensure.sh && python tools/dev/desktop/input.py --key ENTER
```

For longer sessions, run the engine as a background job so it persists:

```bash
"F:/Games/OpenMW-0.51/openmw.exe" --user-data "$USERPROFILE/Documents/My Games/OpenMW"
```

**Do not pass `--no-sound` while working through character creation** — the chargen
*voice lines are the stage markers*, and with sound off there is no way to tell which
dialog you are looking at.

## The tools, and the problem each one solves

### `wait.py` — stop sleeping blindly

```bash
python tools/dev/desktop/wait.py --window                       # the game is up
python tools/dev/desktop/wait.py --log-regex "Loading cell" --timeout 90
python tools/dev/desktop/wait.py --screen-still 1.5            # loading finished
```

Morrowind takes 20–40s to reach a menu and seconds to load a cell. Every wait should
poll a condition and return the instant it is satisfied, and print how long it took.

### `input.py` — actually reach the game

```bash
python tools/dev/desktop/input.py --probe                       # sizes, window, focus
python tools/dev/desktop/input.py --place 40,40                 # pin the window to the primary screen
python tools/dev/desktop/input.py --click 1033,641              # CLIENT coordinates
python tools/dev/desktop/input.py --key ENTER
python tools/dev/desktop/input.py --type Nerevar
```

Clicks are in client coordinates — the same space `shot.ps1` captures — so a screenshot
and a click can be reasoned about together. Three things had to be right before input
landed at all:

- **SendInput, not SendKeys**, and with the **scancode** as well as the virtual key:
  OpenMW binds through SDL, which keys off scancodes (`F12` is `SDL_SCANCODE_F12`).
- **`sizeof(INPUT) == 40`** is asserted. When the marshalling is wrong SendInput
  returns 0 and does nothing — indistinguishable from "wrong coordinates".
- **Focus must be stolen properly** (`AttachThreadInput`): a bare `SetForegroundWindow`
  fails while another window owns the foreground, and then input goes elsewhere.

### `findui.py` — find the thing to click

```bash
python tools/dev/desktop/findui.py --shot            # F12, then list button-like boxes
python tools/dev/desktop/findui.py --shot --ascii    # + a labelled ASCII digest
```

OpenMW cannot enumerate its own widgets from Lua (`ui.getElements` returns only
Lua-created elements, `uibindings.cpp:144`), and some chargen dialogs leave their OK
button to MyGUI's automatic placement. So sometimes the only way to find a control is to
look at the pixels. Where a widget *does* declare a position, prefer reading it:

```bash
grep -oE 'position="[0-9 ]*" name="OKButton"' \
  F:/Games/OpenMW-0.51/resources/vfs/mygui/openmw_chargen_race.layout
# -> position="532 397 42 23"  in a 640x433 window that is align="Center"
#    centre = window_origin + pos + size/2 = (1033, 641) at 1600x900
```

### `api-probe.sh` — ask an engine what it can do

```bash
bash tools/dev/desktop/api-probe.sh "F:/Games/OpenMW-0.51"
# -> API_PROBE rev=129 core=yes ui=yes types=no nearby=no camera=no interfaces=yes ...
```

A tiny MENU-context mod that reports an engine's real Lua API **at the main menu**, so no
save or character is needed. (`types`/`nearby`/`camera` read `no` there simply because a
menu script does not get those packages.) This is where the floor table's evidence comes
from. Note: `MENU:` does not exist before 0.49 — 0.48 answers `Unknown flag 'MENU'`.

### `check_handlers.py` — catch handlers the engine does not have

```bash
python tools/dev/check_handlers.py
```

An unknown engine handler is **not fatal**: the engine logs `Not supported handler ...`
and never calls it, so the feature silently stops working. We shipped exactly that
(`onResolutionChanged`, which does not exist — it is `onViewportResized`). This checks
every handler we declare against the engine's authoritative list.

## Getting into the game fast

```bash
bash tools/dev/desktop/new-game.sh          # new game -> in the world
bash tools/dev/desktop/new-game.sh --save   # ... and quicksave for instant reloads
```

The engine has flags that remove almost all of the slow part:

| Flag | Effect |
| --- | --- |
| `--skip-menu=1` | do not show the main menu at all |
| `--new-game=1` | run the new game sequence straight away (needs `skip-menu`) |
| `--load-savegame <file>` | load a save on startup — the fast path once a save exists |
| `--start <cell>` | set the initial cell |

**Verified**: with `--skip-menu=1 --new-game=1` the game starts a new game with no menu
and no intro, and the mod logs `idle-openmw: phase -> chargen` without a single click —
see the phase-transition line the mod now prints (it exists for exactly this reason).
The intro cinematic also simply is not in this data set (`Failed to open video:
video/new_game.webm not found`), so there is nothing to skip past it.

**Still to finish**: character creation itself. Two ways through it, and the state of each:

1. **The console** — `set chargenstate -1` marks chargen complete and
   `EnablePlayerControls` gives control back; the mod reads the same flag, so its phase
   flips to `world` and the console appears. The console key is grave/backtick
   (`defaultKeyBindings[A_Console] = SDL_SCANCODE_GRAVE`, bindingsmanager.cpp:268).
   **Not yet confirmed** that injected key events open it and land in its text field —
   that is the next thing to check, and it is the cheapest path by far.
2. **Clicking the dialogs** — works but needs the right coordinates, and the GUI is
   SCALED: at 1600x900 the scale is about 1.22, so the race dialog's declared 640x433
   window renders as roughly 782x528, centred at x 408-1190, y 190-714. Its declared
   OK button position (532 397 42 23) therefore lands at about **(1084, 684)**, not the
   unscaled (1033, 641). Measured, not assumed — always derive from the frame you can
   see in a capture rather than from the layout file alone.

Handy: `F5` is quicksave and `F9` quickload, so once a character exists,
`--load-savegame` gets you into the world in seconds.

## Driving character creation

The engine log is the UI signal — each stage plays a voice line:

| Marker in the log | Stage |
| --- | --- |
| `chargenname1` … `chargenname3` | the name prompt and its follow-ups |
| `chargenwalk1` | released |

Practical notes:

- At the main menu, `newgame` already has keyboard focus (`mainmenu.cpp:147`), so
  **`--key ENTER` starts a new game** — no pixel hunting required.
- The chargen dialogs are MyGUI windows, `align="Center"`, sizes 640x433 (race),
  491x316 (class), 527x378 (birthsign), 541x428 (review). Their OK buttons are bottom
  right; the race dialog's is at exactly `(1033, 641)` at 1600x900.
- The intro video is missing from this data set (`video/new_game.webm not found`) and
  the voice files resolve to `.mp3` that is absent — both are cosmetic and expected.

## Gotchas that cost real time here

1. **`--user-data`, not `--userdata`.** The wrong flag is accepted silently and the
   engine just uses the default config dir.
2. **The engine logs to the CONFIG dir**, which `--user-data` does not move.
3. **PowerShell splits an `-ArgumentList` element containing a space.** So
   `--user-data "…/My Games/OpenMW"` was truncated to `…/Documents/My`, and screenshots
   were written to `Documents/My/screenshots`. Quote it.
4. **`pwd` returns an MSYS path** (`/c/...`) which OpenMW cannot use. `pwd -W` does.
5. **A `cmd /c start` child inherits stdout**, so a piped caller blocks until the game
   exits. Use `Start-Process`, or run the engine as a background job.
6. **The window can land on a secondary monitor** (here: `x=-1796`) and then render
   nothing capturable. `input.py --place 40,40` pins it.
7. **The `.layout` overrides are tied to one engine version.** Run them against another
   and the engine quits on a missing widget. Regenerate with
   `python tools/android/ui-overhaul.py --install "F:/Games/OpenMW-0.51"` after an engine
   change; hide `mods/idle_openmw/mygui` to test the Lua against a different engine.
