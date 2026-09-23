#!/usr/bin/env python3
"""Hold the game window focused, so the world keeps running.

WHY THIS IS NEEDED
------------------
Measured on OpenMW 0.51: while the world is PAUSED the engine hands Lua `dt=0` on every
frame, so everything that advances on time -- the snapshot interval, the dev channel, the API
poll -- stalls, and the engine does not populate its `nearby` lists either. That is not a
fault in the mod; it is the engine declining to advance a paused game.

And the world pauses as soon as the window loses focus, which happens constantly while a
harness drives other processes. So a run that should take seconds stalls, and every in-world
demonstration (walking, pathfinding, activating a door) is blocked by it.

This holds focus for a fixed window of time and then exits, so it cannot permanently fight the
user for the keyboard.

  python tools/dev/desktop/keep-focus.py --seconds 120            # hold for two minutes
  python tools/dev/desktop/keep-focus.py --seconds 60 --interval 0.2
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wintypes
import sys
import time

user32 = ctypes.WinDLL("user32", use_last_error=True)

user32.FindWindowW.restype = wintypes.HWND
user32.FindWindowW.argtypes = (wintypes.LPCWSTR, wintypes.LPCWSTR)
user32.SetForegroundWindow.argtypes = (wintypes.HWND,)
user32.GetForegroundWindow.restype = wintypes.HWND
user32.IsWindowVisible.argtypes = (wintypes.HWND,)
user32.ShowWindow.argtypes = (wintypes.HWND, ctypes.c_int)

SW_RESTORE = 9


def find_game_window() -> int | None:
    """The OpenMW window by class name, so we do not depend on the title."""
    for class_name in ("SDL_app", "OpenMW"):
        handle = user32.FindWindowW(class_name, None)
        if handle and user32.IsWindowVisible(handle):
            return handle
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--seconds", type=float, default=120.0,
                        help="how long to hold focus (default 120)")
    parser.add_argument("--interval", type=float, default=0.25,
                        help="how often to re-assert focus (default 0.25s)")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    handle = find_game_window()
    if not handle:
        print("no visible OpenMW window found (is the game running?)", file=sys.stderr)
        return 1

    if not args.quiet:
        print(f"holding focus on hwnd={handle} for {args.seconds:g}s "
              f"(every {args.interval:g}s)")

    deadline = time.monotonic() + args.seconds
    reassertions = 0
    while time.monotonic() < deadline:
        if user32.GetForegroundWindow() != handle:
            # SW_RESTORE first: a minimised window cannot be brought forward
            user32.ShowWindow(handle, SW_RESTORE)
            user32.SetForegroundWindow(handle)
            reassertions += 1
        time.sleep(args.interval)

    if not args.quiet:
        print(f"released (re-asserted focus {reassertions} time(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
