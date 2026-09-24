# The app UI — layout and screens

Specified by the user for the Android app that hosts the mod and drives the engine. This is the
**app's** chrome, not the in-game UI: the mod runs in the engine, so its own console lives on the
Morrowind screen (see `docs/console.md`), while this describes the phone-looking surface around it.

The organising idea: the player **issues orders to the Nerevarine** rather than steering them. Tap
to command, not a joystick.

## Layout, top to bottom

### 1. The viewport (top panel)

A large, prominent scene window across roughly the top third of the screen. Morrowind's world
renders here — or a stylised representation of it. The character's current location is the subject:
a Seyda Neen dockside, the Ashlands at dusk, an ancestral tomb interior.

- Bordered in thick black/gold, like the game's own dialogue portrait frames.
- **Inset below the Android system status bar** so nothing overlaps. This was called out
  explicitly in the mockup, and it is the kind of thing that is invisible on a tablet and obvious
  on a phone with a notch — so it belongs in the layout from the start, not as a later fix.
- Content may be a live animated scene, a static illustrated location card, or a looping
  particle-effect environment (dust motes, rain, ash storms).

### 2. Stat bars (middle strip)

A slim but information-dense horizontal strip between the viewport and the action panel.

- Health / Magicka / Fatigue in the classic Morrowind red / blue / green.
- Thin, elegant lines rather than chunky mobile bars — respecting the original's minimalist HUD.
- May pulse or animate on change: taking damage, resting, casting.

### 3. Action & idle UI (lower dark panel)

The heart of the app. A dark-backgrounded control panel framed in gold, divided into interactive
zones. Tap-to-command buttons, pulled from an existing idle-app button layout — orders, not a
joystick.

### 4. Character portrait panel (right column)

A narrow vertical sidebar to the right of the action panel. The active character's portrait,
exactly as Morrowind's own UI shows it (the face thumbnail from dialogue and the inventory screen).

- Exported/mirrored from the actual game's active character.
- **Reflects current state**: healthy, wounded, diseased, encumbered. This is the reason to mirror
  rather than ship a static image — a portrait that never changes is decoration, a portrait that
  greys out when the character is dying is information.
- Tapping it opens the full character sheet (attributes, skills, birthsign, ...).

## Screens

| Screen | Shape |
|---|---|
| **Journal** | Scrollable quest log in the original typeface aesthetic, gold separator lines between entries |
| **Inventory** | Grid of items with Morrowind-style icon art; weight/gold shown at the bottom |
| **Map** | A sketched, hand-drawn-looking map of Vvardenfell with discovered locations marked |
| **Character sheet** | Attributes and skills as the original game's stat blocks |
| **Spellbook** | Scrollable list of known spells with magicka costs |

## What the mod already provides for this

These are not hypotheticals — the bridge already answers in roughly this shape (see
`docs/bridge-api.md` for the measured answers and `docs/ui-inventory.md` for the in-game console
that reuses them):

- `player` — the panel shape: attributes, pools, skills, equipment, inventory, `canFight`.
- `world` / `cell.current` — where the character is, which is what the viewport captions.
- `entities.nearby` — who and what is around, for the action panel's targets.
- `journal.topics` / `quests.active` — the journal screen.
- `ui.state` — what the mod believes the UI is showing.

The map screen is the one with no engine support worth having: `openmw` exposes no map marker data
to Lua, so Vvardenfell has to be drawn from **discovered locations we track ourselves** (the
`registry` of cells and places the character has actually visited), not from the engine.

## Open question for the app

The portrait is the interesting one. "Exported/mirrored from the actual game's active character"
means reading Morrowind's own portrait bitmaps — `kx_` face parts assembled from the race/head/hair
records, which the engine has and Lua cannot reach. That is squarely in the **engine-change** half
of the scope the user set (engine for what Lua cannot express, injection for what the UI can), and
it is the same kind of access the character sheet needs.
