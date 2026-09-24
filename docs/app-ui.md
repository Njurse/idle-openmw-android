# The app UI — the Morrowind Companion App

The Android app that hosts the mod and drives the engine. Specified by the user; this is the
**app's** chrome, not the in-game UI. The mod's own console lives on the Morrowind screen (see
`docs/console.md`), while this describes the phone-looking surface around it.

## The idea

> A piece of Vvardenfell in your hand.

Deeply faithful to the original game's aesthetic — aged papyrus, gold filigree, dark leather —
rebuilt from the ground up for a touchscreen. And the core mechanic is the same one the mod already
implements: **you give direction, the AI executes.** You do not navigate; you set intent.

## Visual design language

### Background and framing

The whole app sits on a **warm, textured papyrus** background — yellowed, orange-flecked, slightly
uneven, like a page torn from a Dunmer tome. Not a flat colour: it should breathe and feel tactile.
Gold-orange borders frame every panel, evoking the worn gilded edges of Morrowind's in-game books
and windows.

### Palette

| Role | Colour |
|---|---|
| Background | Deep amber / burnt sienna papyrus texture |
| Panel interiors | Near-black (dark leather / ebony), echoing the inventory and dialogue windows |
| Borders & accents | Warm gold and orange — the signature Morrowind UI trim |
| Text | Soft antique gold or parchment white, as if printed with ink on vellum |

`scripts/idle/theme.lua` is the mod's palette and is the place these values should come from rather
than being re-invented in the app — the in-game console and the app must not drift apart.

## Layout, top to bottom

### 1. The viewport (top panel)

A large, prominent scene window across roughly the top third of the screen: Morrowind's world, or a
stylised representation of it, showing where the character is — a Seyda Neen dockside, the Ashlands
at dusk, an ancestral tomb interior.

- Bordered in thick black/gold, like the game's own dialogue portrait frames.
- **Inset below the Android system status bar.** Called out explicitly, and it is the kind of thing
  that is invisible on a tablet and obvious on a phone with a notch — so it belongs in the layout
  from the start rather than as a later fix.
- Content may be a live animated scene, a static illustrated location card, or a looping
  particle-effect environment (dust motes, rain, ash storms).

### 2. Stat bars (middle strip)

A slim, information-dense horizontal strip between the viewport and the action panel.

- Health / Magicka / Fatigue in the classic Morrowind red / blue / green.
- **Thin, elegant lines** rather than chunky mobile bars — respecting the original's minimalist HUD.
- May pulse or animate on change: taking damage, resting, casting.

### 3. Action & idle UI (lower dark panel)

The heart of the app. A dark-backgrounded control panel framed in gold, divided into interactive
zones. **Tap-to-command buttons, not a joystick** — orders issued to your Nerevarine.

| Command | What it does |
|---|---|
| **Wait** | Pass time, recover stats, let the world tick |
| **Go to Town** | Pathfind to the nearest settlement |
| **Explore** | Wander, discover locations, random encounters |
| **Talk** | Initiate NPC dialogue; surface topics, rumours, quests |
| **Sneak** | Toggle sneak; affects encounter outcomes |
| **Attack** | Engage the nearest hostile; combat resolves with dice / skill rolls |
| **Flee** | Pathfind away from danger, stamina-dependent |
| **Inventory** | Open item management |
| **Journal** | Open the quest log in Morrowind's iconic journal style |
| **Magic** | Open the spellbook / spell selection |
| **Rest** | Camp or find an inn; time skips with recovery |

These map onto mod concepts that already exist: the **directive** system (`go_town`, `roam`,
`walk_to`, `wait`) and the play modes in `docs/architecture.md`. The app's job is to emit a
directive and render the result; the judgement stays in Lua where it is testable.

### 4. Character portrait panel (right column)

A narrow vertical sidebar to the right of the action panel. The active character's portrait, exactly
as Morrowind's own UI shows it (the face thumbnail from dialogue and the inventory screen).

- Exported / mirrored from the actual game's active character.
- **Reflects current state**: healthy, wounded, diseased, encumbered. This is the reason to mirror
  rather than ship a static image — a portrait that never changes is decoration; one that greys out
  when the character is dying is information.
- Tapping opens the full character sheet (attributes, skills, birthsign, ...).

## The AI / pathfinding layer

You give direction; the AI executes. The character:

- Pathfinds autonomously (the mod already does this — see `docs/pathfinding.md`).
- Makes contextual decisions: **prioritises healing when low on health**, avoids guards when a
  bounty is active, greets friendly NPCs.
- **Surfaces judgement calls to you** as a pop-up in the Morrowind dialogue style:

  > *A mudcrab approaches. Attack, Flee, or Ignore?*

- Reports back via the Journal on what happened during an explore or travel session.

That last pair is the interesting part of the design: the loop is *idle but engaged*. You set the
character loose, check back, make the key decisions, manage inventory, send them off again.

The "surfaces choices" behaviour is a genuine gap in the mod today, and a small one to close: the
director already computes `topGoals` and a reason line per tick (`goalReason`), so a decision worth
asking about is a goal switch the director was **not** confident about. That belongs in
`scripts/idle/director.lua` as a *question*, not in the app — the app should never re-derive
judgement from raw numbers.

## Management screens

Secondary screens slide in as **overlapping parchment panels**, exactly like Morrowind's stacked
windows.

| Screen | Shape |
|---|---|
| **Journal** | Scrollable quest log in the original typeface aesthetic, gold separator lines between entries |
| **Inventory** | Grid of items with Morrowind-style icon art; weight / gold at the bottom |
| **Map** | A sketched, hand-drawn-looking map of Vvardenfell with discovered locations marked |
| **Character sheet** | Attributes and skills as the original game's stat blocks |
| **Spellbook** | Scrollable list of known spells with magicka costs |

## What the mod already answers for this

These are not hypotheticals — the bridge already returns roughly this shape. See
`docs/bridge-api.md` for the measured answers and `docs/ui-inventory.md` for the in-game console
that consumes the same data.

| Screen / panel | Bridge source |
|---|---|
| Viewport caption | `world`, `cell.current` |
| Stat bars | `player` (attributes, dynamic pools) |
| Portrait state | `player` — health fraction, disease, encumbrance |
| Action targets | `entities.nearby`, `ui.target`, `ui.interactables` |
| Journal | `journal.topics`, `quests.active` |
| Inventory | `player` / `entities.nearby` item stacks (with `equipSlot`) |
| What the mod is doing | the `ui` report: `goal`, `goalReason`, `topGoals`, `brainCommands` |

### The two screens with no engine support worth having

- **Map.** `openmw` exposes no map marker data to Lua, so Vvardenfell has to be drawn from the
  **discovered locations we track ourselves** — the `registry` of cells and places the character has
  actually visited — not from the engine.
- **Portrait art.** "Exported / mirrored from the actual game's active character" means Morrowind's
  own portrait bitmaps: `kx_` face parts assembled from the race / head / hair records. The engine
  has them and Lua cannot reach them. That is squarely in the **engine-change** half of the scope
  the user set (engine for what Lua cannot express, injection for what the UI can), and it is the
  same kind of access the character sheet needs.
