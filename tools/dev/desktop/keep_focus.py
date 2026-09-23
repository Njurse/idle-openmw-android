"""Hold the game window focused, so the world keeps running.

Run from the repo root:  python tools/dev/desktop/keep_focus.py --seconds 60

WHY THIS IS NEEDED
------------------
Measured on OpenMW 0.51: while the world is PAUSED the engine hands Lua `dt=0` on every
frame, so everything that advances on time stalls -- the snapshot interval, the dev channel,
the API poll -- and the engine never populates its `nearby` lists either, so pathfinding has
no doors to walk to. A paused game looks exactly like a frozen mod.

The world pauses when the window is not focused, and a harness driving other processes loses
focus constantly. This holds it for a bounded time and then exits, so it cannot permanently
fight the user for the keyboard.

NOTE ON FINDING THE WINDOW: by process image name, NOT by window class. The class-name lookup
(`SDL_app`) found nothing at all, which made an earlier focus test silently invalid -- it looked
like "focus does not help" when in truth focus was never taken.
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wintypes
import sys
import time

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.windll.kernel32

user32.SetForegroundWindow.argtypes = (wintypes.HWND,)
user32.GetForegroundWindow.restype = wintypes.HWND
user32.ShowWindow.argtypes = (wintypes.HWND, ctypes.c_int)
user32.GetWindowTextLengthW.argtypes = (wintypes.HWND,)
user32.GetWindowTextW.argtypes = (wintypes.HWND, wintypes.LPWSTR, ctypes.c_int)
user32.IsWindowVisible.argtypes = (wintypes.HWND,)

SW_RESTORE = 9
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000


def find_window(process: str = "openmw") -> int:
    """HWND of the first visible top-level window owned by `process` (by image name)."""
    target = process.lower().removesuffix(".exe")
    found: list[int] = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def callback(hwnd, _lparam):
        pid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if not user32.IsWindowVisible(hwnd):
            return True
        if user32.GetWindowTextLengthW(hwnd) == 0:
            return True
        handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid.value)
        if not handle:
            return True
        try:
            buffer = ctypes.create_unicode_buffer(512)
            size = wintypes.DWORD(512)
            if kernel32.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
                if buffer.value.lower().endswith(target + ".exe"):
                    found.append(hwnd)
        finally:
            kernel32.CloseHandle(handle)
        return True

    user32.EnumWindows(callback, 0)
    if not found:
        raise SystemExit(f"no visible window for process '{process}'")
    return found[0]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--process", default="openmw")
    parser.add_argument("--seconds", type=float, default=60.0)
    parser.add_argument("--interval", type=float, default=0.2)
    args = parser.parse_args(argv)

    handle = find_window(args.process)
    print(f"holding focus on hwnd={handle} for {args.seconds:g}s (every {args.interval:g}s)")

    deadline = time.monotonic() + args.seconds
    reassertions = 0
    while time.monotonic() < deadline:
        if user32.GetForegroundWindow() != handle:
            user32.ShowWindow(handle, SW_RESTORE)
            user32.SetForegroundWindow(handle)
            reassertions += 1
        time.sleep(args.interval)

    print(f"released (re-asserted focus {reassertions} time(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
