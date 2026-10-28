#!/usr/bin/env python3
"""tools/android/tests/read_screen.py

Read a device screenshot and report the LAYOUT it shows, as numbers.

WHY THIS EXISTS
---------------
The only thing the x86_64 emulator can prove about this app is pixels: the APK is arm64-v8a
because the published OpenMW Android dependency archive is, and QEMU2 will not emulate arm64 on an
an x86_64 host (docs/android.md). So the UI is reviewed by screenshot -- and a screenshot reviewed
by eye is not evidence that survives the next session.

This turns it into a measurement. It classifies the colours it knows (the same constants as
tools/android/apk/src/is/xyz/idle_openmw/Palette.java) and prints:

  * the vertical run-length profile down the centre column -- where the status bar ends, where the
    viewport starts and ends, where the stat strip and the command panel are;
  * a horizontal profile across the viewport row, which is what shows the gold frame's stroke;
  * the three stat bars, found by colour, with the y they sit on.

It is deliberately a REPORTER, not an assertion: it prints what it measured and leaves the
judgement to whoever asked. The layout is fractions of the content area, so the numbers differ per
device and an assertion would encode one device's pixel arithmetic as a contract.

Usage:
    python tools/android/tests/read_screen.py build/device/10-ui-shell-portrait.png
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# The same values as Palette.java / scripts/idle/theme.lua. Keep in step with them.
EBONY = (26, 21, 14)
EBONY_EDGE = (44, 35, 22)
PAPYRUS_LIGHT = (236, 214, 163)
PAPYRUS_DARK = (198, 154, 84)
GOLD = (197, 146, 57)
HEALTH = (200, 60, 30)
MAGIC = (53, 69, 159)
FATIGUE = (0, 150, 60)


def near(a, b, tolerance=14) -> bool:
    return all(abs(x - y) <= tolerance for x, y in zip(a, b))


def classify(colour) -> str:
    """A human name for a pixel, or its hex when it is a colour we do not know."""
    if near(colour, EBONY):
        return "EBONY"
    if near(colour, EBONY_EDGE):
        return "SLOT"
    if near(colour, GOLD):
        return "GOLD"
    if near(colour, PAPYRUS_LIGHT) or near(colour, PAPYRUS_DARK, 30):
        return "PAPYRUS"
    r, g, b = colour
    # The papyrus gradient passes through tones the two constants above do not cover.
    if r > 150 and 100 < g < 230 and b < 190 and b > 60:
        return "PAPYRUS?"
    if r > 200 and g > 180 and b > 140:
        return "PARCHMENT"
    return "%02x%02x%02x" % colour


def runs(get, count, step, classify_fn) -> list:
    """Contiguous runs of one classification along an axis, as (index, name) transitions."""
    out = []
    previous = None
    for i in range(0, count, step):
        name = classify_fn(get(i))
        if name != previous:
            out.append((i, name))
            previous = name
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("png")
    parser.add_argument("--row", type=int, default=None,
                        help="a y to profile horizontally (default: 30%% down the screen)")
    parser.add_argument("--step", type=int, default=4, help="sampling step, pixels")
    args = parser.parse_args()

    path = Path(args.png)
    if not path.is_file():
        print("no such screenshot: %s" % path, file=sys.stderr)
        return 2

    try:
        from PIL import Image
    except ImportError:
        print("this needs Pillow: pip install pillow", file=sys.stderr)
        return 2

    image = Image.open(path).convert("RGB")
    width, height = image.size
    print("screen   : %dx%d  (h/w = %.3f%s)"
          % (width, height, height / width, ", portrait" if height > width else ", landscape"))

    print("\ncentre column, top to bottom (x=%d):" % (width // 2))
    for index, name in runs(lambda y: image.getpixel((width // 2, y)), height, args.step,
                            classify):
        print("  y=%-5d %5.1f%%  %s" % (index, 100.0 * index / height, name))

    row = args.row if args.row is not None else int(height * 0.30)
    print("\nrow y=%d, left to right:" % row)
    for index, name in runs(lambda x: image.getpixel((x, row)), width, args.step, classify):
        print("  x=%-5d %5.1f%%  %s" % (index, 100.0 * index / width, name))

    print("\nstat bars:")
    report_bars(image, width, height)
    return 0


def report_bars(image, width, height) -> None:
    """Find the stat bars and report what FRACTION of each is filled.

    Two mistakes are recorded here because both were made:

    1. Looking for the bar colour ANYWHERE and reporting the first hit found the coloured LABEL above
       the bar, so it reported a text row and a nonsense width. The bar row is now the first row where
       all three bars are present together.
    2. Measuring the track as (last match - first match) spans from the first bar to the third, which
       is why one bar read as 737px wide. The track is now the CONTIGUOUS run of bar-or-track pixels
       around the fill.

    The track is the bar colour at low alpha over the ebony panel -- which composites to about
    (57,49,37) regardless of WHICH bar it is, because the track paint is one fixed colour
    (Palette.withAlpha(PARCHMENT, 40)) rather than a per-stat one. Getting that wrong made magicka and
    fatigue read as 1.00: their track pixels were not recognised, so the walk stopped at the end of
    the fill.
    """
    track = (57, 49, 37)
    bars = {"health": HEALTH, "magicka": MAGIC, "fatigue": FATIGUE}

    for y in range(height):
        row = [image.getpixel((x, y)) for x in range(width)]
        parts = []
        for label in ("health", "magicka", "fatigue"):
            colour = bars[label]
            trackc = track
            hits = [x for x, c in enumerate(row) if near(c, colour, 25)]
            if len(hits) < 8:
                break
            left, right = hits[0], hits[-1]
            while left > 0 and (near(row[left - 1], colour, 25) or near(row[left - 1], trackc, 18)):
                left -= 1
            while right < width - 1 and (near(row[right + 1], colour, 25)
                                         or near(row[right + 1], trackc, 18)):
                right += 1
            length = right - left + 1
            filled = sum(1 for x in range(left, right + 1) if near(row[x], colour, 25))
            # Discriminate a BAR from TEXT: the fill of a bar is one solid rectangle, so its pixels
            # form a single unbroken run. Glyphs do not. Without this the label row above the bar
            # satisfies "all three present" and reports 0.40 for a bar that is really 0.84.
            longest = 0
            current = 0
            for x in range(left, right + 1):
                if near(row[x], colour, 25):
                    current += 1
                    longest = max(longest, current)
                else:
                    current = 0
            if longest != filled or filled < 20:
                break
            parts.append("%s %3d/%3dpx = %.2f" % (label, filled, length, filled / float(length)))
        if len(parts) == 3:
            print("  y=%d  %s" % (y, "   ".join(parts)))
            return
    print("  no row with all three bars was found")


if __name__ == "__main__":
    raise SystemExit(main())
