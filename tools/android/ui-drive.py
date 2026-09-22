"""Drive the OpenMW-Android launcher over adb, by widget text.

The launcher is the one part of this pipeline that cannot be configured from a
file: its "Game files" screen is a storage browser that writes the chosen path to
SharedPreferences, and the app is not debuggable so those prefs cannot be seeded
directly. This little driver taps through it instead, so setup is repeatable
rather than a thing you did once and forgot.

    python tools/android/ui-drive.py dump
    python tools/android/ui-drive.py tap "Game files"
    python tools/android/ui-drive.py tapxy 540 666
    python tools/android/ui-drive.py select "Morrowind"     # tap row, then SELECT

It is intentionally dumb -- text matching against a `uiautomator` dump -- because
that is the only interface the launcher offers.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
REMOTE_DUMP = "/sdcard/ui-dump.xml"
LOCAL_DUMP = REPO / "build" / "evidence" / "ui-live.xml"


def find_adb() -> str:
    for candidate in (
        os.environ.get("ADB"),
        str(Path(os.environ.get("LOCALAPPDATA", "")) / "Android" / "Sdk" / "platform-tools" / "adb.exe"),
        str(Path(os.environ.get("ANDROID_SDK_ROOT", "")) / "platform-tools" / "adb.exe"),
        str(Path(os.environ.get("ANDROID_HOME", "")) / "platform-tools" / "adb.exe"),
    ):
        if candidate and Path(candidate).is_file():
            return candidate
    raise SystemExit("adb not found; set ANDROID_SDK_ROOT or ADB")


ADB = find_adb()


def adb(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    env = dict(os.environ, MSYS_NO_PATHCONV="1")
    return subprocess.run([ADB, *args], capture_output=True, text=True,
                          encoding="utf-8", errors="replace", env=env, check=check)


def dump() -> ET.Element:
    """Capture the current screen hierarchy."""
    adb("shell", "uiautomator", "dump", REMOTE_DUMP, check=False)
    xml = adb("shell", "cat", REMOTE_DUMP).stdout
    LOCAL_DUMP.parent.mkdir(parents=True, exist_ok=True)
    LOCAL_DUMP.write_text(xml, encoding="utf-8")
    return ET.fromstring(xml)


def bounds_of(node: ET.Element) -> tuple[int, int, int, int] | None:
    b = node.get("bounds")
    if not b:
        return None
    m = re.match(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", b)
    if not m:
        return None
    return tuple(int(v) for v in m.groups())  # type: ignore[return-value]


def centre(node: ET.Element) -> tuple[int, int] | None:
    b = bounds_of(node)
    if not b:
        return None
    x1, y1, x2, y2 = b
    return (x1 + x2) // 2, (y1 + y2) // 2


def nodes_with_text(root: ET.Element, text: str, exact: bool = True) -> list[ET.Element]:
    out = []
    for node in root.iter():
        value = node.get("text") or ""
        if (value == text) if exact else (text.lower() in value.lower()):
            if bounds_of(node):
                out.append(node)
    return out


def tap_xy(x: int, y: int) -> None:
    adb("shell", "input", "tap", str(x), str(y))


def visible_text(root: ET.Element) -> list[str]:
    seen, out = set(), []
    for node in root.iter():
        value = (node.get("text") or "").strip()
        if value and value not in seen:
            seen.add(value)
            out.append(value)
    return out


def cmd_dump(args) -> int:
    root = dump()
    for line in visible_text(root):
        print(line)
    return 0


def cmd_tap(args) -> int:
    root = dump()
    nodes = nodes_with_text(root, args.text, exact=not args.contains)
    if not nodes:
        print(f"not found: {args.text!r}", file=sys.stderr)
        print("visible: " + ", ".join(repr(t) for t in visible_text(root)[:20]), file=sys.stderr)
        return 1
    point = centre(nodes[0])
    tap_xy(*point)
    print(f"tapped {args.text!r} at {point}")
    return 0


def cmd_tapxy(args) -> int:
    tap_xy(args.x, args.y)
    print(f"tapped ({args.x},{args.y})")
    return 0


def cmd_select(args) -> int:
    """Enter a folder (by tapping it) and then press the launcher's SELECT."""
    root = dump()
    nodes = nodes_with_text(root, args.text)
    if not nodes:
        print(f"not found: {args.text!r}", file=sys.stderr)
        return 1
    tap_xy(*centre(nodes[0]))
    if args.enter:
        time.sleep(args.delay)
        root = dump()
    selectors = nodes_with_text(root, "SELECT") or nodes_with_text(root, "OK") \
        or nodes_with_text(root, "DONE")
    if not selectors:
        print("no SELECT/OK button on screen", file=sys.stderr)
        print("visible: " + ", ".join(repr(t) for t in visible_text(root)[:20]), file=sys.stderr)
        return 1
    tap_xy(*centre(selectors[0]))
    print(f"tapped {args.text!r}, then SELECT")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("dump", help="print visible text").set_defaults(func=cmd_dump)

    p = sub.add_parser("tap", help="tap the first widget with this text")
    p.add_argument("text")
    p.add_argument("--contains", action="store_true", help="substring match")
    p.set_defaults(func=cmd_tap)

    p = sub.add_parser("tapxy", help="tap absolute coordinates")
    p.add_argument("x", type=int)
    p.add_argument("y", type=int)
    p.set_defaults(func=cmd_tapxy)

    p = sub.add_parser("select", help="tap a folder, then press SELECT")
    p.add_argument("text")
    p.add_argument("--enter", action="store_true", help="re-dump before pressing SELECT")
    p.add_argument("--delay", type=float, default=2.0)
    p.set_defaults(func=cmd_select)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
