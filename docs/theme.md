# The console's look: Morrowind colours (and the font question)

Two different things get called "the UI's appearance": the **font** and the
**colours**. They have different answers.

## Colours — ours, and now Morrowind's own

`scripts/idle/theme.lua` is a pure palette. Its values are **Morrowind's GMST font
colours verbatim**, as OpenMW ships them in `files/openmw.cfg`:

| Role | Morrowind value | Where |
| --- | --- | --- |
| normal (the tan) | `202,165,96` | `fallback=FontColor_color_normal` |
| header / hover (parchment) | `223,201,159` | `FontColor_color_normal_over`, `_header` |
| disabled / dim | `179,168,135` | `FontColor_color_disabled` |
| negative / health | `200,60,30` | `FontColor_color_negative`, `_health` |
| positive | `223,201,159` | `FontColor_color_positive` |
| link (topic blue) | `112,126,207` | `FontColor_color_link` |
| magic | `53,69,159` | `FontColor_color_magic` |
| fatigue | `0,150,60` | `FontColor_color_fatigue` |
| misc | `0,205,205` | `FontColor_color_misc` |

The console paints by **role**, not by hex: `mode`, `goal`, `gold`, `log`,
`tabActive`, `row`, `rowSelected`, `heading`, `footer`, `alert`, … map onto those
palette entries in one table (`theme.THEMES`). Log rows are coloured by their
level (`bad` → red, `warn` → deep red, `good` → parchment), headings get the
header colour, and the selected row is picked out.

### It adopts *your* Morrowind

Hard-coding the numbers is the fallback. At runtime `portraitUI` passes
`core.getGMST` into `theme.colors(...)`, which overrides any entry the game
actually reports (`FontColor_color_*` come back as `"r,g,b"` strings —
`components/fallback/validate.cpp:100`). So a Morrowind with recoloured GMSTs
paints the console in *those* colours, and a bare engine uses the shipped ones. A
value that fails to parse is ignored rather than painted black.

### Switching

Setup tab → **Console colours**, or `ui.theme` in config (`morrowind` default,
`plain` for a high-contrast palette on a bright screen).

## Font — it is already Morrowind's, and Lua cannot change it

The console's text uses the engine's UI font. OpenMW maps the game's fonts as
(`files/openmw.cfg:68-70`):

```
fallback=Fonts_Font_0,MysticCards
fallback=Fonts_Font_1,DejaVuLGCSansMono
fallback=Fonts_Font_2,DemonicLetters
```

`MysticCards` is Morrowind's UI face, so the console is already drawn in it — the
mod uses the MWUI `textNormal`/`textHeader` templates (`scripts/omw/mwui/text.lua`),
which carry only a size and a colour, no family.

Choosing a *different* family from Lua is not possible: the Lua text element
exposes `text`, `textSize`, `textColor`, `wordWrap`, `textAlignH`, … and **no font
property** (`components/lua_ui/text.cpp:52`). What the mod *can* change is the
**size** — `ui.textScale` — and the colour, above.

(The one way to force a different face would be to ship a `mygui/openmw_font.xml`
override, but that re-registers MyGUI's fonts for the *whole* game, not just our
console, and Lua text would still use the engine default rather than a font we
name. Not worth the blast radius.)

## Verification

```
python tools/run_tests.py --only theme     # the palette, parse(), colours(), roles
```

Geometry is `uiLayout.lua` (tested); the *pixels* still want a device pass — same
caveat as `docs/ui-overhaul.md`.
