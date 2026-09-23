#!/usr/bin/env python3
"""Check that every engine handler the mod declares actually exists.

WHY THIS EXISTS
---------------
An engine handler the engine does not know is NOT fatal. The engine logs

    Not supported handler 'onResolutionChanged' in L@0x1[scripts/portraitui.lua]

and carries on -- so the feature silently never fires. We shipped exactly that: the
console's rebuild-on-rotate handler was `onResolutionChanged`, which does not exist
(openmw calls `onViewportResized`). Nothing in the Lua test suite could see it, because
the handler table is just data.

The name list below is copied from the engine's own reference:
  .research/openmw/docs/source/reference/lua-scripting/engine_handlers.rst
so this is a static check against the engine, not against our assumptions.

  python tools/dev/check_handlers.py            # exit 1 on an unknown handler
  python tools/dev/check_handlers.py --list     # print the known names
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "mods" / "idle_openmw" / "scripts"

# From docs/source/reference/lua-scripting/engine_handlers.rst (context noted).
HANDLERS = {
    # any script
    "onInterfaceOverride",
    # any non-menu script (global / local / player)
    "onInit", "onUpdate", "onSave", "onLoad",
    # global only
    "onNewGame", "onPlayerAdded", "onObjectActive", "onActorActive", "onItemActive",
    "onActive", "onInactive", "onConsume", "onActivate", "onActivated", "onDeactivated",
    "onTeleported", "onNewExterior", "onStateChanged", "onContentFilesLoaded",
    "onQuestUpdate", "onPlaced", "onDropped", "onTouchMove",
    # player only
    "onKeyPress", "onKeyRelease", "onMouseButtonPress", "onMouseButtonRelease",
    "onMouseWheel", "onControllerButtonPress", "onControllerButtonRelease",
    "onInputAction", "onFrame", "onViewportResized", "onUiModeChanged",
    "onTouchPress", "onTouchRelease",
    # menu only / misc
    "onConsoleCommand",
}

# Keys that appear inside `engineHandlers = { ... }` but are ours, not the engine's.
# (Custom event names live in `eventHandlers`, which is a different table.)
IGNORED = {"onDialogueResponse", "onGuardianApplied"}


def handler_keys(path: Path) -> list[tuple[str, int]]:
    """Every `name = ...` key inside an `engineHandlers = {` table in this file."""
    text = path.read_text(encoding="utf-8", errors="replace")
    out: list[tuple[str, int]] = []
    for m in re.finditer(r"engineHandlers\s*=\s*\{", text):
        i = m.end()
        depth = 1
        while i < len(text) and depth:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        body = text[m.end():i - 1]
        line0 = text[:m.start()].count("\n") + 1
        for km in re.finditer(r"([A-Za-z_][A-Za-z0-9_]*)\s*=", body):
            out.append((km.group(1), line0 + body[:km.start()].count("\n")))
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args(argv)

    if args.list:
        for name in sorted(HANDLERS):
            print(name)
        return 0

    files = sorted(SCRIPTS.rglob("*.lua"))
    checked = unknown = 0
    for path in files:
        for name, line in handler_keys(path):
            checked += 1
            if name in IGNORED:
                continue
            if name not in HANDLERS:
                rel = path.relative_to(REPO)
                print(f"{rel}:{line}: unknown engine handler '{name}'")
                unknown += 1

    print(f"checked {checked} handler declaration(s) in {len(files)} file(s)")
    if unknown:
        print(f"{unknown} UNKNOWN -- the engine will log 'Not supported handler' and never call it")
        return 1
    print("all handler names known to the engine")
    return 0


if __name__ == "__main__":
    sys.exit(main())
