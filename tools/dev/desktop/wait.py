#!/usr/bin/env python3
"""Wait for a condition, then return immediately -- instead of sleeping blindly.

WHY THIS EXISTS
---------------
Driving a real game with fixed sleeps wastes the whole budget: Morrowind takes 20-40s
to reach a menu, a cell load takes a few seconds, and there is no way to know from the
outside. So every wait in this harness should poll a CONDITION and return the moment it
is satisfied -- and say how long it took, so slow steps are visible.

Conditions:
  --log-regex PAT     a line matching PAT appears in the engine log (new lines only)
  --log-grew          the log grew past where it was when we started
  --window            the game window exists
  --no-window         the game window is gone
  --screen-still S    the captured frame stops changing for S seconds (loading done)
  --exists PATH       a path appears (e.g. a new screenshot)

  python tools/dev/desktop/wait.py --window
  python tools/dev/desktop/wait.py --log-regex 'Loading cell' --timeout 90
  python tools/dev/desktop/wait.py --screen-still 1.5 --timeout 60
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]  # tools/dev/desktop/x.py -> repo root
CONFIG_DIR = Path.home() / "Documents" / "My Games" / "OpenMW"
LOG = CONFIG_DIR / "openmw.log"


def window_up(process: str = "openmw") -> bool:
    cmd = ("(Get-Process -Name %s -ErrorAction SilentlyContinue | "
           "Where-Object { $_.MainWindowHandle -ne 0 } | Measure-Object).Count" % process)
    out = subprocess.run(["powershell.exe", "-NoProfile", "-Command", cmd],
                         capture_output=True, text=True).stdout.strip()
    return out.isdigit() and int(out) > 0


def capture(path: Path) -> bool:
    r = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                        "-File", str(REPO / "tools/dev/desktop/shot.ps1"),
                        "-Out", str(path)], capture_output=True, text=True)
    return r.returncode == 0 and path.exists()


def frame_signature(path: Path):
    """A cheap fingerprint of the frame (downscaled bytes), for change detection."""
    try:
        from PIL import Image
    except ImportError:
        return None
    im = Image.open(path).convert("L").resize((64, 36))
    return bytes(im.tobytes())


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--log-regex")
    ap.add_argument("--log-grew", action="store_true")
    ap.add_argument("--window", action="store_true")
    ap.add_argument("--no-window", action="store_true")
    ap.add_argument("--screen-still", type=float, metavar="SECONDS")
    ap.add_argument("--exists")
    ap.add_argument("--process", default="openmw")
    ap.add_argument("--timeout", type=float, default=90.0)
    ap.add_argument("--interval", type=float, default=0.4)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    started = time.time()
    start_size = LOG.stat().st_size if LOG.exists() else 0
    still_since = None
    last_sig = None
    tmp = REPO / "build" / "desktop" / "_wait.png"

    def satisfied() -> bool:
        nonlocal still_since, last_sig
        if args.window and window_up(args.process):
            return True
        if args.no_window and not window_up(args.process):
            return True
        if args.log_grew and LOG.exists() and LOG.stat().st_size > start_size:
            return True
        if args.log_regex and LOG.exists():
            text = LOG.read_text(encoding="utf-8", errors="replace")
            # only consider content written since we started watching
            tail = text[start_size:] if start_size <= len(text) else text
            if re.search(args.log_regex, tail, re.I | re.M):
                return True
        if args.exists and Path(args.exists).exists():
            return True
        if args.screen_still is not None:
            if capture(tmp):
                sig = frame_signature(tmp)
                if sig is not None:
                    if sig != last_sig:
                        last_sig = sig
                        still_since = time.time()
                    elif time.time() - still_since >= args.screen_still:
                        return True
        return False

    while True:
        if satisfied():
            if not args.quiet:
                print("ready after %.1fs" % (time.time() - started))
            return 0
        if time.time() - started > args.timeout:
            print("TIMEOUT after %.1fs waiting for %s" % (
                time.time() - started, args), file=sys.stderr)
            return 1
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
