# The phone UI overhaul

Two different problems get called "the UI". They have completely different
answers, and conflating them is how a plan goes wrong.

| | Can Lua do it? | The answer |
| --- | --- | --- |
| **B. The engine's own windows** (dialogue, inventory, trade, journal, stats, magic, map, container) | **No** — neither read nor move | Override their MyGUI **`.layout`** data files |
| **A. Our own windows** (the idle console) | Yes, fully | `ui.create` + `MWUI` templates |

## B. Moving Morrowind's real windows — the supported hook

Every engine window is a MyGUI XML layout. They are loaded through the **VFS**,
which is the mod data-dir stack, in
`apps/openmw/mwgui/windowmanagerimp.cpp:213`:

```cpp
constexpr VFS::Path::NormalizedView resourcePath("mygui");
... resourceSystem->getVFS(), mScalingFactor, resourcePath, logpath / "MyGUI.log");
```

So the `mygui/` prefix resolves like any other game asset. A mod that ships
`mygui/openmw_inventory_window.layout` **overrides the engine's copy** under
normal mod precedence — no engine patch, no Lua, no hooks. It is the same
mechanism a texture replacer uses.

`tools/android/ui-overhaul.py` does exactly that:

```
python tools/android/ui-overhaul.py --install "F:/Games/OpenMW Latest" \
                                    --out mods/idle_openmw
```

It rewrites **only the root widget's `position` and `align`** on each target
window and leaves every other byte of the engine's file alone, so engine fixes
to the rest of that window still reach us. This is why the tool reads the
*installed* engine rather than shipping copies: a copy would freeze the window at
today's version and silently shadow every later improvement.

The rule set lives in one table at the top of that file — band (`top` / `bottom`
of a portrait screen, as fractions so it survives resolution changes), an `align`
that always includes `HStretch` (a fixed-width window on a narrow screen is the
main thing that breaks), and a note saying why. That table is the single place
our window modifications are described.

## A. What Lua can and cannot see

The limit is documented in the API itself —
`files/lua_api/openmw/ui.lua`, `getElements`:

> Returns currently rendered **Lua UI root Elements** in this Lua context. … Note:
> this returns Elements created with `ui.create`. **It does not return native
> engine UI widgets** or child layouts that are not separate Elements.

So from Lua we can neither read the *contents* of the engine's windows (the
dialogue topics, the inventory rows, the menu entries) nor move them. Anything
that renders those things is our own window, built with `ui.create`.

What Lua *can* do, and does:

- **Draw our own windows**, styled to look native via `interfaces.MWUI`
  (`scripts/omw/mwui/init.lua`), whose templates are `padding`, `borders`, `box`,
  `boxSolid`, `textNormal`, `textHeader`, `textParagraph`, `verticalLine`,
  `horizontalLine` and thick variants.
- **Add a page to the main menu** — `ui.registerSettingsPage`, which puts a panel
  on the Scripts tab of the settings screen. This is the one supported way to
  appear *inside* an existing engine window.
- **Read the underlying data** and re-present it: inventory
  (`types.Actor.inventory`), dispositions (`types.Actor.stats.ai.fight`), service
  records, journal, quests. What we cannot get is a window's *rendering*; the
  *data* is largely available.
- **Observe dialogue** — `DialogueResponse` is a notification, not a hook
  (`docs/openmw-lua-api.md` §7). It tells us what was said, not what is on screen.
- **Read which window is open** — `ui._getUiModeStack()`
  (`docs/openmw-lua-api.md` §11.2). This is the live "UI hook": we cannot read a
  window's *contents*, but we can read *which* window is up, including
  `MainMenu`, `Dialogue` and the whole `Chargen*` family.

## So what does "hooking into the UI" actually mean here?

Being precise about it, because the phrase covers three different things:

1. **Reposition / restyle** the real windows → `.layout` overrides (done, above).
2. **Mirror content** in our own console → read the data, render it ourselves.
   **Built** (`scripts/runtime/observer.lua` + `scripts/idle/uiModel.lua`): the
   console shows dialogue topics, the pack, the log, *and* a live "On screen" row
   naming the window the engine currently has open
   (`scripts/idle/uiState.lua`, read from `ui._getUiModeStack`).
3. **Add controls** to an engine window → only `ui.registerSettingsPage` exists.
   There is no general widget-injection API.

## Verification

```
python tools/android/tests/test_ui_overhaul.py    # 23 tests
python tools/android/ui-overhaul.py --install "F:/Games/OpenMW Latest" --dry-run
```

The dry run against the real 0.49 engine finds and relocates all eight target
windows. Diffing a generated override against the engine's original shows
**exactly one changed line** — the root widget.

**A regression worth recording.** The first version read and wrote the layout with
`Path.read_text()` / `write_text()`, which apply universal newline translation.
The real engine's layouts are **CRLF**, so that silently rewrote every line as LF:
the diff was 63 changed lines, not one, and the "minimal change" claim in the
tool's own docstring was false. The tool now reads and writes **bytes** and
re-emits the source file's own newline. It is the same failure shape as the
heredoc trap in `AGENTS.md`: the check was written the same way as the bug, so it
could not see the bug — the fixture used `\n` and therefore passed.

The tests now assert the byte-level contract directly
(`test_a_crlf_file_stays_crlf`, `test_bytes_survive_a_round_trip`), build CRLF
fixtures with `chr(13) + chr(10)` rather than `"\\r\\n"` literals, and
`test_preserves_everything_else_byte_for_byte` counts the differing lines so a
whole-file rewrite cannot pass again. The tool also refuses a layout with no
`name="_Main"` root rather than guessing, is idempotent, and no rule can drop
`HStretch`.


## Not yet done

- The **navigation bar / cutout insets** are a C++ concern, not a data one: the
  engine does not read `WindowInsets`. Until that is patched, layout overrides
  place windows in the *full* screen and the system bar overlaps the bottom edge.
- The `mygui/` overrides are **generated**, so they are only as current as the
  last run of the tool. Re-run it after an engine update.
- Nothing here has been seen on a device. The geometry is arithmetic and tested;
  the pixels are not.

## Related

- **Reading which window is open** (the live UI hook, and the character-creation
  gate that keeps the mod out of chargen) — `docs/openmw-lua-api.md` §11 and §13.
- **The isometric camera** — a Lua toggle, not an engine patch, with a named
  engine-side limit for hiding roofs — `docs/isometric.md`.
