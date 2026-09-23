#!/usr/bin/env python3
"""Dismiss whatever modal is blocking the world, by asking the mod and then acting.

Run from the repo root:  python tools/dev/desktop/dismiss.py [--max 12]

WHY THIS EXISTS
---------------
Morrowind's message boxes are not UI *modes*, so when one is up the engine's mode stack is
EMPTY and the world is PAUSED -- "no window is open" and "the game is stopped" are true at the
same time. Lua cannot click a native widget (docs/ui-inventory.md), so the mod cannot dismiss
it itself; something that can synthesise input has to.

That is the host's job -- the Android layer, or this harness. So the loop is exactly what the
app will do:

  1. ASK the bridge (`ui`) whether the world is paused/blocked       <- observation channel
  2. if blocked, send a key and a click                              <- input synthesis
  3. repeat, bounded, and report what happened

Step 1 is the part that makes it reliable rather than a blind sleep: the observation channel
runs on a NOMINAL clock, so it answers even while the world is paused -- which is precisely
when it is needed.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
import time

# tools/dev/desktop/dismiss.py -> repo root is three levels up
REPO = pathlib.Path(__file__).resolve().parents[3]
REQUEST_FILE = REPO / "mods" / "idle_openmw" / "idle_api.txt"
LOG = pathlib.Path.home() / "Documents" / "My Games" / "OpenMW" / "openmw.log"
INPUT = REPO / "tools" / "dev" / "desktop" / "input.py"


def ask_ui(request_id: int, timeout: float = 2.0) -> dict | None:
    """Ask the bridge how the world looks, and return the `ui` result."""
    REQUEST_FILE.write_text(json.dumps({"id": request_id, "method": "ui"}) + "\n",
                            encoding="utf-8")
    deadline = time.monotonic() + timeout
    pattern = re.compile(r"IDLEAPI (\{.*\})")
    while time.monotonic() < deadline:
        try:
            text = LOG.read_text(encoding="utf-8", errors="replace")
        except OSError:
            text = ""
        for line in reversed(text.splitlines()[-400:]):
            match = pattern.search(line)
            if not match:
                continue
            try:
                envelope = json.loads(match.group(1))
            except ValueError:
                continue
            if envelope.get("id") == request_id:
                return envelope.get("result") if envelope.get("ok") else None
        time.sleep(0.2)
    return None


def send(*args: str) -> None:
    subprocess.run([sys.executable, str(INPUT), *args],
                   check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--max", type=int, default=12, help="attempts before giving up")
    parser.add_argument("--screen", default="1600x900", help="for the centre click")
    args = parser.parse_args(argv)

    width, height = (int(v) for v in args.screen.lower().split("x"))
    centre = f"{width // 2},{height // 2}"

    request_id = 900
    for attempt in range(1, args.max + 1):
        request_id += 1
        state = ask_ui(request_id)
        if state is None:
            print(f"attempt {attempt}: no answer from the bridge (is the game running?)")
            return 2

        paused = state.get("paused")
        blocked = state.get("blocked")
        screen = state.get("uiMode") or state.get("screen") or "(none reported)"
        print(f"attempt {attempt}: paused={paused} blocked={blocked} screen={screen}")
        if paused is not True:
            print("the world is running.")
            return 0

        # A message box dismisses on any key; a click anywhere also works. Try the keyboard
        # first (cheaper and independent of where the box is), then a click in the middle.
        send("--key", "SPACE")
        time.sleep(0.3)
        send("--key", "RETURN")
        time.sleep(0.3)
        send("--click", centre)
        time.sleep(0.6)

    print(f"still blocked after {args.max} attempts; the modal may need a specific answer")
    return 1


if __name__ == "__main__":
    sys.exit(main())
