#!/usr/bin/env python3
"""Find the clickable things on the current game screen.

WHY THIS EXISTS
---------------
OpenMW cannot enumerate its own widgets from Lua: `ui.getElements` returns only
elements the *Lua* layer created (uibindings.cpp:144), so a native MyGUI dialog is
invisible to introspection. The engine's .layout files give positions for the widgets
that declare one, but several chargen dialogs leave their OK button unplaced and let
MyGUI auto-position it at runtime.

So: look at the pixels. This finds button-like bright boxes -- roughly rectangular,
60x25ish, brighter than the dark dialog around them -- and prints their centres, which
is a coordinate you can feed straight to input.py --click. It also prints a labelled
ASCII digest, so the shape of the screen can be read without opening the image.

  python tools/dev/desktop/findui.py --shot            # F12, then read that shot
  python tools/dev/desktop/findui.py --image x.png
  python tools/dev/desktop/findui.py --shot --top 8
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parents[3]  # tools/dev/desktop/x.py -> repo root
SHOT_DIR = Path.home() / "Documents" / "My Games" / "OpenMW" / "screenshots"


def engine_shot(process: str = "openmw") -> Path:
    """Ask the engine for a screenshot (F12) and return the newest file."""
    before = set(SHOT_DIR.glob("*.png")) if SHOT_DIR.is_dir() else set()
    subprocess.run([sys.executable, str(REPO / "tools/dev/desktop/input.py"),
                    "--process", process, "--key", "F12"],
                   check=True, capture_output=True)
    for _ in range(40):
        time.sleep(0.25)
        now = set(SHOT_DIR.glob("*.png"))
        new = now - before
        if new:
            newest = max(new, key=lambda p: p.stat().st_mtime)
            # wait for the write to settle
            size = -1
            while newest.stat().st_size != size:
                size = newest.stat().st_size
                time.sleep(0.2)
            return newest
    raise SystemExit("no new screenshot appeared (is the game running?)")


def blobs(img: Image.Image, threshold: int = 100, min_w: int = 22, max_w: int = 200,
          min_h: int = 12, max_h: int = 60, min_fill: float = 0.35):
    """Connected bright components shaped like a button. Returns (x, y, w, h) boxes."""
    g = img.convert("L")
    W, H = g.size
    px = g.load()
    seen = bytearray(W * H)
    out = []
    for y0 in range(H):
        for x0 in range(W):
            i = y0 * W + x0
            if seen[i] or px[x0, y0] < threshold:
                continue
            # iterative flood fill
            stack = [(x0, y0)]
            seen[i] = 1
            minx = maxx = x0
            miny = maxy = y0
            count = 0
            while stack:
                x, y = stack.pop()
                count += 1
                if x < minx: minx = x
                if x > maxx: maxx = x
                if y < miny: miny = y
                if y > maxy: maxy = y
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < W and 0 <= ny < H:
                        j = ny * W + nx
                        if not seen[j] and px[nx, ny] >= threshold:
                            seen[j] = 1
                            stack.append((nx, ny))
            w = maxx - minx + 1
            h = maxy - miny + 1
            if min_w <= w <= max_w and min_h <= h <= max_h:
                if count / float(w * h) >= min_fill:
                    out.append((minx, miny, w, h))
    return out


def grid(img: Image.Image, cols: int = 80, rows: int = 24) -> str:
    g = img.convert("L")
    W, H = g.size
    chars = " .:-=+*#%@"
    lines = []
    for r in range(rows):
        y0, y1 = H * r // rows, max(H * (r + 1) // rows, H * r // rows + 1)
        row = []
        for c in range(cols):
            x0, x1 = W * c // cols, max(W * (c + 1) // cols, W * c // cols + 1)
            acc = n = 0
            for y in range(y0, y1, max(1, (y1 - y0) // 3)):
                for x in range(x0, x1, max(1, (x1 - x0) // 3)):
                    acc += g.getpixel((x, y)); n += 1
            row.append(chars[min(len(chars) - 1, int(acc / n / 256 * len(chars)))])
        lines.append("%4d|%s" % (y0, "".join(row)))
    header = "    |" + "".join(str((W * c // cols) // 100 % 10) for c in range(cols))
    return "\n".join([header] + lines) + "\n(x labels are hundreds of px; y labels are px)"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--image")
    ap.add_argument("--shot", action="store_true", help="take a fresh F12 screenshot")
    ap.add_argument("--process", default="openmw")
    ap.add_argument("--top", type=int, default=12)
    ap.add_argument("--threshold", type=int, default=100)
    ap.add_argument("--ascii", action="store_true", help="print the labelled digest")
    args = ap.parse_args(argv)

    if args.shot:
        path = engine_shot(args.process)
        print(f"# fresh engine screenshot: {path}")
    elif args.image:
        path = Path(args.image)
    else:
        shots = sorted(SHOT_DIR.glob("*.png"), key=lambda p: p.stat().st_mtime) if SHOT_DIR.is_dir() else []
        if not shots:
            raise SystemExit("no screenshots found; use --shot or --image")
        path = shots[-1]
        print(f"# newest engine screenshot: {path}")

    img = Image.open(path)
    print(f"# {path.name}  {img.size[0]}x{img.size[1]}")

    found = blobs(img, threshold=args.threshold)
    # biggest first: buttons are the most substantial bright boxes
    found.sort(key=lambda b: -(b[2] * b[3]))
    print(f"# {len(found)} button-like box(es); centres are click coordinates")
    for (x, y, w, h) in found[:args.top]:
        print("  click %4d,%4d   box %4dx%-3d at %4d,%4d" % (x + w // 2, y + h // 2, w, h, x, y))

    if args.ascii:
        print()
        print(grid(img))
    return 0


if __name__ == "__main__":
    sys.exit(main())
