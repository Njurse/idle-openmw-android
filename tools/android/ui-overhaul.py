#!/usr/bin/env python3
"""Relocate OpenMW's own Morrowind windows for a phone-shaped screen.

WHY THIS IS POSSIBLE AT ALL (and why it is a *data* change, not a hack):

  apps/openmw/mwgui/windowmanagerimp.cpp:213
      constexpr VFS::Path::NormalizedView resourcePath("mygui");
      ... resourceSystem->getVFS(), mScalingFactor, resourcePath, ...

  Every one of the engine's windows is a MyGUI XML layout under `mygui/`, and
  that prefix is resolved through the VFS -- the same mod data-dir stack that
  texture replacers use. So a mod that ships `mygui/openmw_inventory_window.layout`
  overrides the engine's copy under normal mod precedence. That is the supported
  way to move the real windows, and it needs no engine patch and no Lua.

WHAT THIS TOOL DELIBERATELY DOES NOT DO:

  It does not ship copies of the layouts. It reads the *installed* engine's
  layout, rewrites only the root window's `position`/`align`, and writes the
  result. Copying whole layouts would freeze them at today's engine version and
  silently shadow later engine fixes to those windows.

WHY NOT LUA (the honest limit -- docs/openmw-lua-api.md §11):

  `openmw.ui.getElements` is documented as returning "Elements created with
  `ui.create`. It does not return native engine UI widgets." So Lua can neither
  read the contents of these windows nor move them. Lua draws *its own* windows
  (which is what scripts/portraitUI.lua does); the engine's windows are moved
  here, in data.

Usage:
    python tools/android/ui-overhaul.py --install "F:/Games/OpenMW Latest" --out mods/idle_openmw
    python tools/android/ui-overhaul.py --list
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

# ---------------------------------------------------------------------------
# The rule set -- the ONE place our window modifications are described.
#
# `band` describes where on a portrait phone the window should live, as
# fractions of the *screen* rather than pixels, so this survives resolution
# changes. `align` is the MyGUI alignment keyword list; "HStretch" is what makes
# a window span the width on a narrow screen.
# ---------------------------------------------------------------------------

TOP_BAND = (0.0, 0.55)      # upper: the world view should stay visible
BOTTOM_BAND = (0.55, 1.0)   # lower: one-handed reach, below the game view


@dataclass(frozen=True)
class Rule:
    band: tuple[float, float]
    align: str
    note: str


#: window layout file -> rule. Keys are engine layout names.
RULES: dict[str, Rule] = {
    'openmw_dialogue_window.layout': Rule(TOP_BAND, 'Left Top HStretch',
                                          'reading history wants the most space'),
    'openmw_inventory_window.layout': Rule(BOTTOM_BAND, 'Left Bottom HStretch',
                                           'the pack you poke at while playing'),
    'openmw_container_window.layout': Rule(BOTTOM_BAND, 'Left Bottom HStretch',
                                           'loot is the same motion as the pack'),
    'openmw_trade_window.layout': Rule(BOTTOM_BAND, 'Left Bottom HStretch',
                                       'bartering is the same motion again'),
    'openmw_journal.layout': Rule(BOTTOM_BAND, 'Left Bottom HStretch', 'journal'),
    'openmw_stats_window.layout': Rule(BOTTOM_BAND, 'Left Bottom HStretch', 'stats'),
    'openmw_magicselection_dialog.layout': Rule(BOTTOM_BAND, 'Left Bottom HStretch',
                                                'spell picking'),
    'openmw_map_window.layout': Rule(TOP_BAND, 'Left Top HStretch',
                                     'the map is looked at, not tapped'),
}

#: The root widget of every one of these layouts looks like:
#:   <Widget type="Window" skin="MW_Window" layer="Windows" position="0 0 588 433" name="_Main">
#: We rewrite `position` (and add/replace `align`) on exactly that widget.
_ROOT_WIDGET_RE = re.compile(
    r'(<Widget\b[^>]*?\bname="_Main"[^>]*?)(/?>)', re.DOTALL)
_ATTR_RE = r'(?<=\s){}\s*=\s*"[^"]*"'
_POSITION_RE = re.compile(r'(?<=\s)position\s*=\s*"[^"]*"')


class LayoutError(ValueError):
    """A layout we cannot confidently rewrite. Never guessed at."""


def find_root_widget(text: str) -> tuple[str, str]:
    """Return (matched, tail) for the `name=\"_Main\"` root widget tag."""
    match = _ROOT_WIDGET_RE.search(text)
    if not match:
        raise LayoutError('no root Widget with name="_Main" found')
    return match.group(0), match.group(1)


def root_position(text: str) -> str:
    """The root widget's current `position` value, e.g. "0 0 588 433"."""
    widget, _ = find_root_widget(text)
    match = _POSITION_RE.search(widget)
    if not match:
        raise LayoutError('root widget has no position attribute')
    return match.group(0).split('"')[1]


def band_position(position: str, band: tuple[float, float],
                  screen: tuple[int, int]) -> str:
    """A `position` string placing the window in `band` of a `screen`.

    Only the y offset and the height are derived from the band; the window keeps
    its authored width so its internal layout is not squashed.
    """
    parts = position.split()
    if len(parts) != 4:
        raise LayoutError(f'expected 4 position numbers, got {position!r}')
    try:
        x, _y, width, height = (int(p) for p in parts)
    except ValueError as exc:
        raise LayoutError(f'non-integer position {position!r}') from exc

    screen_w, screen_h = screen
    top = int(round(band[0] * screen_h))
    bottom = int(round(band[1] * screen_h))
    # Never larger than the authored height, and never off the screen.
    new_height = max(1, min(height, bottom - top))
    del screen_w  # width is authored on purpose; kept for signature clarity
    return f'{x} {top} {width} {new_height}'


def apply_rule(text: str, rule: Rule, screen: tuple[int, int]) -> tuple[str, str]:
    """Rewrite one layout's root widget. Returns (new_text, old_position)."""
    widget, prefix = find_root_widget(text)
    old_position = root_position(text)

    new_widget = _POSITION_RE.sub(
        f'position="{band_position(old_position, rule.band, screen)}"', widget, count=1)

    # `align` may or may not already exist; MyGUI takes the last value, so
    # replacing in place when present and appending when absent is safe.
    align_attr = re.compile(r'(?<=\s)align\s*=\s*"[^"]*"')
    if align_attr.search(new_widget):
        new_widget = align_attr.sub(f'align="{rule.align}"', new_widget, count=1)
    else:
        new_widget = new_widget.replace(
            f'name="_Main"', f'name="_Main" align="{rule.align}"', 1)

    return text.replace(widget, new_widget, 1), old_position


def has_crlf(text: str) -> bool:
    """Does this file use CRLF line endings?"""
    return '\r\n' in text


def find_layouts(install: Path) -> dict[str, Path]:
    """Locate the engine's `mygui/*.layout` files.

    The path moved: older engines keep them in `resources/mygui`, but 0.49+ builds
    ship a VFS where `mygui` maps to `resources/vfs/mygui` (and Morrowind-specific
    layouts to `resources/vfs-mw/mygui`). Search the known shapes rather than one
    hard-coded path -- a wrong guess here silently produces overrides copied from
    the WRONG engine version, which the engine then refuses to load.
    """
    for candidate in (
        'resources/vfs/mygui',   # 0.49+ (VFS)
        'resources/mygui',       # classic layout
        'resources/vfs-mw/mygui',
        'resources',
        'mygui',
    ):
        directory = install / candidate
        if directory.is_dir():
            found = {p.name: p for p in directory.glob('*.layout')}
            if found:
                return found
    return {}


def run(install: Path, out: Path, screen: tuple[int, int],
        dry_run: bool = False) -> list[str]:
    """Apply RULES to the installed engine's layouts, writing mod overrides."""
    available = find_layouts(install)
    if not available:
        raise SystemExit(f'no mygui/*.layout found under {install}')

    target_dir = out / 'mygui'
    report: list[str] = []
    for name, rule in sorted(RULES.items()):
        path = available.get(name)
        if path is None:
            # A missing layout is an engine-version difference, not our bug.
            report.append(f'SKIP {name}: not present in this install')
            continue
        # Read and write as BYTES, not text. Path.read_text() applies universal
        # newline translation, which silently rewrites CRLF files as LF and makes
        # the override differ on every single line -- the opposite of the
        # byte-minimal change this tool promises.
        raw = path.read_bytes().decode('utf-8', errors='replace')
        new_text, old = apply_rule(raw, rule, screen)
        if new_text == raw:
            report.append(f'SAME {name}: already {old}')
            continue
        if not dry_run:
            target_dir.mkdir(parents=True, exist_ok=True)
            # Match the source file's own newline so the header does not stand out.
            nl = '\r\n' if has_crlf(raw) else '\n'
            header = nl.join([
                '<!-- idle-openmw: generated by tools/android/ui-overhaul.py',
                f'     source: {name} (from the installed engine)',
                f'     Moved to the {"top" if rule.band == TOP_BAND else "bottom"} band '
                f'({rule.align}) for a phone screen. {rule.note}.',
                '     Only the root window position/align differ from the engine copy,',
                '     so engine updates to the rest of this window still apply. -->',
            ]) + nl
            (target_dir / name).write_bytes((header + new_text).encode('utf-8'))
        report.append(f'WRITE {name}: {old} -> {band_position(old, rule.band, screen)}')
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--install', type=Path,
                        help='OpenMW install root (contains resources/mygui)')
    parser.add_argument('--out', type=Path, default=Path('mods/idle_openmw'),
                        help='mod folder to write mygui/ overrides into')
    parser.add_argument('--screen', default='1080x2340',
                        help='portrait screen WxH (default: Galaxy S23+)')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--list', action='store_true',
                        help='show the rule set and exit')
    args = parser.parse_args(argv)

    if args.list:
        for name, rule in sorted(RULES.items()):
            band = 'top' if rule.band == TOP_BAND else 'bottom'
            print(f'{name:42s} {band:6s} {rule.align:22s} {rule.note}')
        return 0

    if not args.install:
        parser.error('--install is required (or pass --list)')

    try:
        width, height = (int(v) for v in args.screen.lower().split('x'))
    except ValueError:
        parser.error(f'--screen must look like 1080x2340, got {args.screen!r}')

    for line in run(args.install, args.out, (width, height), args.dry_run):
        print(line)
    return 0


if __name__ == '__main__':
    sys.exit(main())
