# The phone console

A bottom-half overlay drawn with `ui.create`, so the game stays playable by hand.
Geometry is `scripts/idle/uiLayout.lua`, rows and text are
`scripts/idle/uiModel.lua`, colours are `scripts/idle/theme.lua` — all pure and
unit-tested. `scripts/portraitUI.lua` only renders. See `docs/theme.md` for the
look and `tools/preview_console.py` to see it without launching the game.

## Tabs

| Tab | Shows | Taps do |
| --- | --- | --- |
| **Info** | mode, goal + why, ordered directive, HP/MP/FT/load, gold/level, the top-3 goals being considered, the live "On screen" window, and a "Holding" row naming the phase when the mod is not acting | the mode line cycles manual → orders → auto |
| **Order** | the directives you can give | queue an order |
| **Pack** | the **worn paper-doll** ("Worn"), then everything carried, then a junk summary | tap a worn piece or an item to select it, then Equip / Sell / Drop |
| **Talk** | recent conversations, topics heard, **the topics your character knows** (`journal().topics`), and quests | tap a topic → walk to the nearest NPC and open the dialogue window |
| **Log** | the bounded activity log | scroll |
| **Open** | launchers for Morrowind's own windows (Inventory, Journal, Barter, Training, Dialogue, Rest, Spells, Map) | open that engine window |
| **Setup** | the live options | cycle an option (applies on the next tick, persisted) |

## Orders (the Order tab)

`shop`, `sell_junk`, `rest`, `train`, `heal`, `talk`, `quest`, `travel`,
`explore`, and the world actions `wait / stop`, `roam the area`, `go to town`.

An order is a **directive** (`scripts/idle/directive.lua`) with a TTL (default
120 sim-seconds); it overrides the director's own choice while it holds, except
when the character is in danger — safety always wins. `go_town` is
directive-only: it is planned but never scored, because "take me to town" is an
instruction, not a preference.

## Setup options

`simulateActions`, `autoTravel`, **`roam`**, `npcFightHostility`,
`creaturesAreHostile`, console refresh, mode on load, the **isometric camera**,
and the **console colours** theme.

## Inventory management

- **Tap to equip**: a carried item that maps to an equipment slot (by *name*, not
  by the item `type` number — see `docs/plan-reconciliation.md` C7) can be worn.
- **The paper-doll**: `equipment.paperDoll(items)` lays the worn gear out in
  `SLOT_ORDER` (head → hands → feet). We cannot render the 3D actor, so the
  "portrait" *is* the slot list: what is worn where, tappable so the footer can
  swap, sell or drop it.
- **Equip / Sell / Drop** act on the selected row, through the `IdleOpenMW`
  interface (`act('equip'|'sell'|'drop', payload)`).

## Failing safe

Every rebuild goes through `requestRebuild()`, which **destroys first** — skipping
the destroy leaks a second console on screen (that bug is why the rule is
written down). If `ui.create` throws, the script latches off instead of throwing
every frame. Outside the world (character creation, menu, load screen) the
console **hides itself entirely** and builds nothing, so it cannot cover the
engine's own windows (`scripts/idle/lifecycle.lua`).
