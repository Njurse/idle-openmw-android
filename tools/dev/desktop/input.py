#!/usr/bin/env python3
"""Drive the OpenMW window: focus it, then click, move or type.

Why Python/ctypes rather than the PowerShell helper (tools/dev/desktop/input.ps1):
SendInput fails SILENTLY when the INPUT marshalling is off -- it just returns 0 and
nothing happens, which is indistinguishable from "wrong coordinates". Here the
structure sizes are asserted (SendInput's INPUT is 40 bytes on x64) and every call's
return value is checked, so a failure says so.

Clicks are in CLIENT coordinates (0,0 = top-left of the rendered area), the same
space tools/dev/desktop/shot.ps1 captures -- so a screenshot and a click can be
reasoned about together.

  python tools/dev/desktop/input.py --probe
  python tools/dev/desktop/input.py --click 800,708
  python tools/dev/desktop/input.py --key F12
  python tools/dev/desktop/input.py --type Nerevar
  python tools/dev/desktop/input.py --move 400,300
  python tools/dev/desktop/input.py --click 800,708 --shot build/desktop/x.png
"""

from __future__ import annotations

import argparse
import ctypes
import sys
import time
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)

# --- Win32 shapes -----------------------------------------------------------
INPUT_MOUSE = 0
INPUT_KEYBOARD = 1

KEYEVENTF_EXTENDEDKEY = 0x0001
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004
KEYEVENTF_SCANCODE = 0x0008

MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_RIGHTDOWN = 0x0008
MOUSEEVENTF_RIGHTUP = 0x0010
MOUSEEVENTF_ABSOLUTE = 0x8000
MOUSEEVENTF_VIRTUALDESK = 0x4000

ULONG_PTR = wintypes.WPARAM


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG),
                ("mouseData", wintypes.DWORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD),
                ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD),
                ("dwExtraInfo", ULONG_PTR)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", wintypes.DWORD), ("wParamL", wintypes.WORD),
                ("wParamH", wintypes.WORD)]


class _INPUTunion(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("u", _INPUTunion)]


assert ctypes.sizeof(INPUT) == 40, f"INPUT is {ctypes.sizeof(INPUT)} bytes, expected 40"
assert ctypes.sizeof(MOUSEINPUT) in (28, 32), ctypes.sizeof(MOUSEINPUT)

VK = {
    "ENTER": 0x0D, "RETURN": 0x0D, "ESC": 0x1B, "ESCAPE": 0x1B, "SPACE": 0x20,
    "TAB": 0x09, "BACKSPACE": 0x08, "SHIFT": 0x10, "CTRL": 0x11, "ALT": 0x12,
    "UP": 0x26, "DOWN": 0x28, "LEFT": 0x25, "RIGHT": 0x27,
    "Y": 0x59, "N": 0x4E, "E": 0x45, "T": 0x54, "F": 0x46, "W": 0x57, "S": 0x53,
    "1": 0x31, "2": 0x32, "3": 0x33, "4": 0x34, "5": 0x35,
    # VK_OEM_3 is the grave/backtick key, which is OpenMW's console toggle
    # (defaultKeyBindings[A_Console] = SDL_SCANCODE_GRAVE, bindingsmanager.cpp:268).
    "GRAVE": 0xC0, "BACKTICK": 0xC0, "TILDE": 0xC0,
    "MINUS": 0xBD, "EQUALS": 0xBB,
}
for i in range(1, 13):
    VK[f"F{i}"] = 0x6F + i


def _send(*inputs: INPUT) -> None:
    array = (INPUT * len(inputs))(*inputs)
    sent = user32.SendInput(len(inputs), array, ctypes.sizeof(INPUT))
    if sent != len(inputs):
        err = ctypes.get_last_error()
        raise OSError(f"SendInput sent {sent}/{len(inputs)} (GetLastError={err})")


def find_window(process: str = "openmw") -> int:
    """HWND of the first visible top-level window owned by `process` (by image name)."""
    target = process.lower().removesuffix(".exe")
    found: list[int] = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def cb(hwnd, _lparam):
        pid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if not user32.IsWindowVisible(hwnd):
            return True
        length = user32.GetWindowTextLengthW(hwnd)
        if length == 0:
            return True
        # compare the owning process image name
        PROCESS_QUERY_LIMITED = 0x1000
        h = ctypes.windll.kernel32.OpenProcess(PROCESS_QUERY_LIMITED, False, pid.value)
        if not h:
            return True
        try:
            buf = ctypes.create_unicode_buffer(512)
            size = wintypes.DWORD(512)
            if ctypes.windll.kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
                name = buf.value.split("\\")[-1].lower().removesuffix(".exe")
                if name == target:
                    found.append(hwnd)
        finally:
            ctypes.windll.kernel32.CloseHandle(h)
        return True

    user32.EnumWindows(cb, 0)
    if not found:
        raise SystemExit(f"no visible window for process '{process}'")
    return found[0]


def place_window(hwnd: int, x: int, y: int) -> None:
    """Move the game window onto a chosen screen position.

    OpenMW remembers where it was and can land on a secondary monitor -- which here
    meant x=-1796, and the engine then rendered nothing capturable (every screenshot
    came out black, mean brightness 13 instead of 58). Pinning the window to the
    primary desktop makes focus, clicks and captures all agree on one coordinate space.
    """
    SWP_NOSIZE = 0x0001
    SWP_NOZORDER = 0x0004
    user32.SetWindowPos(hwnd, 0, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER)
    time.sleep(0.3)


def client_rect(hwnd: int) -> tuple[int, int, int, int]:
    r = wintypes.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(r))
    origin = wintypes.POINT(0, 0)
    user32.ClientToScreen(hwnd, ctypes.byref(origin))
    return origin.x, origin.y, r.right - r.left, r.bottom - r.top


def focus(hwnd: int) -> None:
    """Bring the game to the foreground, reliably.

    A bare SetForegroundWindow fails when another process currently owns the
    foreground -- Windows only lets you steal it if you share an input queue. So
    attach to the current foreground window's thread first, which is the standard
    workaround, then detach. Without this the game is not focused and SendInput goes
    somewhere else entirely (which is indistinguishable from "wrong coordinates").
    """
    user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    fg = user32.GetForegroundWindow()
    if fg != hwnd:
        our_thread = ctypes.windll.kernel32.GetCurrentThreadId()
        fg_thread = user32.GetWindowThreadProcessId(fg, None)
        attached = False
        if fg_thread and fg_thread != our_thread:
            attached = bool(user32.AttachThreadInput(our_thread, fg_thread, True))
        try:
            user32.BringWindowToTop(hwnd)
            user32.SetForegroundWindow(hwnd)
            user32.SetFocus(hwnd)
        finally:
            if attached:
                user32.AttachThreadInput(our_thread, fg_thread, False)
    time.sleep(0.3)


def _absolute(hwnd: int, cx: int, cy: int) -> tuple[int, int]:
    """Client point -> SendInput's 0..65535 absolute space (over the virtual desk)."""
    p = wintypes.POINT(cx, cy)
    user32.ClientToScreen(hwnd, ctypes.byref(p))
    vx = user32.GetSystemMetrics(76)   # SM_XVIRTUALSCREEN
    vy = user32.GetSystemMetrics(77)
    vw = user32.GetSystemMetrics(78)
    vh = user32.GetSystemMetrics(79)
    ax = int(round((p.x - vx) * 65535 / max(1, vw - 1)))
    ay = int(round((p.y - vy) * 65535 / max(1, vh - 1)))
    return ax, ay


def _mouse(flags: int, ax: int, ay: int) -> INPUT:
    i = INPUT(type=INPUT_MOUSE)
    i.u.mi = MOUSEINPUT(dx=ax, dy=ay, mouseData=0, dwFlags=flags, time=0, dwExtraInfo=0)
    return i


def click(hwnd: int, cx: int, cy: int, right: bool = False, delay: float = 0.12) -> None:
    ax, ay = _absolute(hwnd, cx, cy)
    move = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK
    _send(_mouse(move, ax, ay))
    time.sleep(0.05)
    down = MOUSEEVENTF_RIGHTDOWN if right else MOUSEEVENTF_LEFTDOWN
    up = MOUSEEVENTF_RIGHTUP if right else MOUSEEVENTF_LEFTUP
    _send(_mouse(move | down, ax, ay), _mouse(move | up, ax, ay))
    time.sleep(delay)


def move(hwnd: int, cx: int, cy: int) -> None:
    ax, ay = _absolute(hwnd, cx, cy)
    _send(_mouse(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, ax, ay))


def _key_inputs(vk: int) -> list[INPUT]:
    # Send the SCANCODE as well as the virtual key. SDL (and therefore OpenMW) keys
    # off the scancode, and a VK-only event can be dropped: F12 is bound as
    # SDL_SCANCODE_F12 (bindingsmanager.cpp:287), not as a VK.
    scan = user32.MapVirtualKeyW(vk, 0)  # MAPVK_VK_TO_VSC
    down = INPUT(type=INPUT_KEYBOARD)
    down.u.ki = KEYBDINPUT(wVk=vk, wScan=scan, dwFlags=0, time=0, dwExtraInfo=0)
    up = INPUT(type=INPUT_KEYBOARD)
    up.u.ki = KEYBDINPUT(wVk=vk, wScan=scan, dwFlags=KEYEVENTF_KEYUP, time=0, dwExtraInfo=0)
    return [down, up]


def key(hwnd: int, name: str, delay: float = 0.12) -> None:
    vk = VK.get(name.upper())
    if not vk:
        raise SystemExit(f"unknown key '{name}' (known: {', '.join(sorted(VK))})")
    _send(*_key_inputs(vk))
    time.sleep(delay)


def type_text(hwnd: int, text: str, delay: float = 0.04) -> None:
    """Type as UNICODE key events -- no keymap needed, so any character works."""
    for ch in text:
        code = ord(ch)
        down = INPUT(type=INPUT_KEYBOARD)
        down.u.ki = KEYBDINPUT(wVk=0, wScan=code, dwFlags=KEYEVENTF_UNICODE, time=0, dwExtraInfo=0)
        up = INPUT(type=INPUT_KEYBOARD)
        up.u.ki = KEYBDINPUT(wVk=0, wScan=code, dwFlags=KEYEVENTF_UNICODE | KEYEVENTF_KEYUP,
                             time=0, dwExtraInfo=0)
        _send(down, up)
        time.sleep(delay)
    time.sleep(delay * 4)


def emit(line: str) -> None:
    """A line for the log, so a run can be reconstructed from the engine log."""
    print(f"[input] {line}", flush=True)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--process", default="openmw")
    ap.add_argument("--click", metavar="X,Y")
    ap.add_argument("--right-click", metavar="X,Y")
    ap.add_argument("--move", metavar="X,Y")
    ap.add_argument("--key", metavar="NAME")
    ap.add_argument("--type", dest="text", metavar="TEXT")
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--seq", metavar="STEPS",
                    help="ordered steps in ONE process, e.g. "
                         "'key:GRAVE;type:set chargenstate -1;key:ENTER'. Each separate "
                         "invocation re-focuses the window, which drops the in-game "
                         "console's text focus between keystrokes.")
    ap.add_argument("--delay", type=float, default=0.12)
    ap.add_argument("--place", metavar="X,Y",
                    help="move the game window to this SCREEN position first")
    ap.add_argument("--probe", action="store_true",
                    help="report struct sizes, the window, and whether it is focused")
    args = ap.parse_args(argv)

    hwnd = find_window(args.process)
    if args.place:
        px, py = (int(v) for v in args.place.split(","))
        place_window(hwnd, px, py)
        hwnd = find_window(args.process)  # handle may move with the window
    x, y, w, h = client_rect(hwnd)
    title = ctypes.create_unicode_buffer(256)
    user32.GetWindowTextW(hwnd, title, 256)
    fg = user32.GetForegroundWindow()

    if args.probe:
        print(f"sizeof(INPUT)={ctypes.sizeof(INPUT)} (must be 40)")
        print(f"hwnd={hwnd} title={title.value!r}")
        print(f"client {w}x{h} at screen {x},{y}")
        print(f"foreground={fg} isForeground={fg == hwnd}")

    focus(hwnd)
    after_focus = user32.GetForegroundWindow()
    emit(f"focus hwnd={hwnd} title={title.value!r} fg_after={after_focus} "
         f"focused={after_focus == hwnd}")

    def point(spec: str) -> tuple[int, int]:
        a, b = spec.split(",")
        return int(a), int(b)

    if args.seq:
        for step in args.seq.split(";"):
            step = step.strip()
            if not step:
                continue
            kind, _, value = step.partition(":")
            kind = kind.strip().lower()
            if kind == "key":
                key(hwnd, value.strip(), delay=args.delay)
                emit("seq key " + value.strip())
            elif kind == "type":
                type_text(hwnd, value)
                emit("seq type " + repr(value))
            elif kind == "click":
                cx, cy = point(value)
                click(hwnd, cx, cy, delay=args.delay)
                emit("seq click (%d,%d)" % (cx, cy))
            elif kind in ("wait", "sleep"):
                time.sleep(float(value.strip() or 0.5))
                emit("seq wait " + value.strip())
            else:
                raise SystemExit("unknown seq step: " + step)
        return 0

    for n in range(args.repeat):
        if args.click:
            cx, cy = point(args.click)
            click(hwnd, cx, cy, delay=args.delay)
            emit(f"click #{n + 1} client=({cx},{cy})")
        if args.right_click:
            cx, cy = point(args.right_click)
            click(hwnd, cx, cy, right=True, delay=args.delay)
            emit(f"right-click #{n + 1} client=({cx},{cy})")
        if args.move:
            cx, cy = point(args.move)
            move(hwnd, cx, cy)
            emit(f"move client=({cx},{cy})")
        if args.key:
            key(hwnd, args.key, delay=args.delay)
            emit(f"key {args.key}")
        if args.text:
            type_text(hwnd, args.text)
            emit(f"type {args.text!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
