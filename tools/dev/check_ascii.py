#!/usr/bin/env python3
"""Enforce: Lua sources are pure ASCII. Build multi-byte characters with string.char.

WHY THIS EXISTS
---------------
Twice in one session a non-ASCII character written through a shell heredoc became a
DIFFERENT character, silently:

  * an ellipsis in a clamp function, which then overran its own length limit, and
  * an accented letter in a test's expected value, which made the test assert against
    text that was mangled exactly the same way as the code under test.

That second failure mode is the dangerous one: a check written through the same channel
as the damage cannot detect the damage. The cheap structural fix is to keep non-ASCII out
of source files entirely -- `string.char(226, 128, 166)` is unambiguous, survives every
tool in the chain, and says exactly which bytes it means.

Morrowind's own data is full of accented text, so this is not about avoiding non-ASCII
VALUES -- the mod deals in them constantly. It is about not typing them into source.

COMMENTS ARE EXEMPT on purpose: a section mark or an arrow in prose is documentation, and
it cannot be compared against anything. Only non-ASCII that could reach a string LITERAL
matters, because that is the kind that gets compared and therefore the kind that can lie.

  python tools/dev/check_ascii.py            # exit 1 on any non-ASCII byte
  python tools/dev/check_ascii.py --list     # also list the offending characters
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# A cp1252 console cannot print every character we might report, and a lint that crashes
# on its own output is useless.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

REPO = Path(__file__).resolve().parents[2]

# Lua the mod and the tests actually run. Documentation and data are exempt: a doc should
# be allowed a real ellipsis, and Morrowind's .esm text obviously is not ASCII.
ROOTS = [REPO / "mods" / "idle_openmw" / "scripts", REPO / "tests"]
SKIP_PARTS = {".git", "build", ".research", "vendor"}  # vendor: third-party, as-is


def offenders() -> list[tuple[Path, int, str, str]]:
    found = []
    for root in ROOTS:
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.lua")):
            if any(part in SKIP_PARTS for part in path.parts):
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            for number, line in enumerate(text.splitlines(), 1):
                code = line.split("--", 1)[0]      # comments are exempt (see above)
                bad = sorted({ch for ch in code if ord(ch) > 127})
                if bad:
                    found.append((path.relative_to(REPO), number, code.strip()[:70], bad))
    return found


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 on any finding (default: report and pass)")
    args = ap.parse_args(argv)

    found = offenders()
    if not found:
        print("all Lua sources are ASCII in code positions (non-ASCII is built with string.char)")
        return 0

    for path, number, line, bad in found:
        chars = " ".join(f"U+{ord(c):04X}" for c in bad)
        print(f"{path}:{number}: non-ASCII {chars}")
        if args.list:
            print(f"    {line}")
    print()
    print(f"{len(found)} line(s) with non-ASCII in code positions")
    if not args.strict:
        # Pre-existing display glyphs (arrows, crosses) are not worth a refactor, and they
        # are only fragile where a byte-for-byte comparison depends on them. The policy
        # is for NEW code: build the bytes with string.char.
        print("policy: NEW lua code builds non-ASCII with string.char "
              "(see AGENTS.md); pass --strict to fail on any finding")
        return 0
    print("use string.char(...) so the bytes cannot be mangled by a heredoc or an editor")
    return 1


if __name__ == "__main__":
    sys.exit(main())
