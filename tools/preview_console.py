#!/usr/bin/env python3
"""Draw the phone console to an HTML mock -- from the REAL geometry and palette.

The console's pixels only exist on a device, and `ui.create()` cannot be verified
headlessly. But the three things that decide what you *see* are all pure Lua:

    scripts/idle/uiLayout.lua   geometry (panel/tabs/rows/footers)
    scripts/idle/uiModel.lua    tabs, rows, footers, the text itself
    scripts/idle/theme.lua      the Morrowind palette

So this tool loads those modules in an embedded Lua VM (lupa, LuaJIT 2.1 -- the
same runtime the game and the test suite use), asks `tools/preview/console_mock.lua`
for a description of every element, and paints it into a self-contained HTML page.
Open the file in a browser.

It is a MOCK, not a screenshot:
  * the game art behind it is a flat placeholder;
  * the font is a serif stand-in for Morrowind's MysticCards (Lua cannot choose a
    font family -- see docs/theme.md).

Usage:
    python tools/preview_console.py                       # Info tab, morrowind theme
    python tools/preview_console.py --tab pack --theme plain
    python tools/preview_console.py --out build/preview.html
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MOD_ROOT = REPO_ROOT / "mods" / "idle_openmw"
FLAVOUR = "luajit21"


def build_package_path() -> str:
    templates = []
    for root in (REPO_ROOT, MOD_ROOT):
        base = root.as_posix()
        templates.append(f"{base}/?.lua")
        templates.append(f"{base}/?/init.lua")
    return ";".join(templates) + ";"


def lua_to_python(value):
    """Best-effort conversion of a lupa value to plain Python."""
    # lupa exposes Lua tables with .items()/iteration; scalars pass through.
    if isinstance(value, (bool, int, float, str)) or value is None:
        return value
    # Anything else: try to treat it as a Lua table.
    try:
        items = list(value.items())
    except AttributeError:
        return value
    # array-like (1..n integer keys) -> list, else dict
    if items and all(isinstance(k, int) for k, _ in items):
        length = 0
        for k, _ in items:
            length = max(length, k)
        out = [None] * length
        for k, v in items:
            out[k - 1] = lua_to_python(v)
        return out
    return {k: lua_to_python(v) for k, v in items}


def css_colour(colour) -> str:
    if not isinstance(colour, dict):
        return "rgba(202,165,96,0.95)"
    r = int(round((colour.get("r") or 0) * 255))
    g = int(round((colour.get("g") or 0) * 255))
    b = int(round((colour.get("b") or 0) * 255))
    a = colour.get("a")
    a = 1.0 if a is None else a
    return f"rgba({r},{g},{b},{a:.3f})"


def render_html(model: dict, tab: str, theme: str) -> str:
    screen = model["screen"]
    w, h = int(screen["x"]), int(screen["y"])
    elements = model["elements"]

    parts = []
    for el in elements:
        kind = el.get("kind")
        x, y = int(el["x"]), int(el["y"])
        ew, eh = int(el["w"]), int(el["h"])
        if kind == "panel":
            parts.append(
                f'<div class="el panel" style="left:{x}px;top:{y}px;'
                f'width:{ew}px;height:{eh}px;background:{css_colour(el.get("colour"))}"></div>'
            )
        else:
            size = int(el.get("size") or 12)
            text = (el.get("text") or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            parts.append(
                f'<div class="el text" style="left:{x}px;top:{y}px;width:{ew}px;height:{eh}px;'
                f'font-size:{size}px;color:{css_colour(el.get("colour"))}">{text}</div>'
            )

    body = "\n".join(parts)
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>idle-openmw console preview ({tab}, {theme})</title>
<style>
  html, body {{ margin: 0; background: #15110b; color: #caa560; }}
  .wrap {{ display: flex; justify-content: center; padding: 18px; }}
  /* A phone-shaped screen at 1:1 in CSS pixels (the game is 1080x2340 logical). */
  .screen {{ position: relative; width: {w}px; height: {h}px; overflow: hidden;
             border: 3px solid #3a3122; border-radius: 10px; }}
  .game {{ position: absolute; inset: 0;
           background: linear-gradient(#5a6a7a 0%, #6f7a6a 42%, #39432f 43%, #2b3423 100%); }}
  .game .note {{ position: absolute; left: 24px; top: 24px; font: 13px/1.4 serif;
                 color: rgba(255,255,255,0.55); }}
  .el {{ position: absolute; }}
  .text {{ font-family: Georgia, 'Times New Roman', serif; line-height: 1.15;
           white-space: pre; overflow: hidden; }}
  .panel {{ border: 2px solid #6b5a3a; box-shadow: inset 0 0 0 1px #2a241a; }}
  h1 {{ text-align: center; font: 14px/2 monospace; color: #8a7a56; }}
</style></head>
<body>
<h1>idle-openmw console PREVIEW &mdash; tab={tab} theme={theme} &mdash; {w}x{h} logical
  &nbsp;(mock: serif stands in for MysticCards)</h1>
<div class="wrap"><div class="screen">
  <div class="game"><div class="note">placeholder game art<br>(the console is the point)</div></div>
{body}
</div></div>
</body></html>
"""


def render_png(model: dict, out: Path) -> None:
    """Rasterise the mock to a PNG (a convenient, viewable image).

    Uses a serif TTF as a stand-in for Morrowind's MysticCards. Layout and colour
    are exact; the typeface is not.
    """
    from PIL import Image, ImageDraw, ImageFont

    screen = model["screen"]
    w, h = int(screen["x"]), int(screen["y"])
    img = Image.new("RGB", (w, h), (43, 52, 35))
    draw = ImageDraw.Draw(img, "RGBA")

    # placeholder "game": sky -> horizon -> ground
    for y in range(h):
        if y < h * 0.42:
            t = y / (h * 0.42)
            col = (int(90 + 20 * t), int(106 + 16 * t), int(122 + 10 * t))
        else:
            t = (y - h * 0.42) / (h * 0.58)
            col = (int(57 - 14 * t), int(67 - 15 * t), int(47 - 12 * t))
        draw.line([(0, y), (w, y)], fill=col)
    draw.text((24, 24), "placeholder game art\n(the console is the point)", font=None, fill=(255, 255, 255, 140))

    font_paths = [
        r"C:\Windows\Fonts\georgia.ttf",
        r"C:\Windows\Fonts\constan.ttf",
        r"C:\Windows\Fonts\cambria.ttc",
        r"C:\Windows\Fonts\times.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf",
    ]
    cache: dict[int, object] = {}

    def font(size: int):
        if size not in cache:
            for path in font_paths:
                try:
                    cache[size] = ImageFont.truetype(path, size)
                    break
                except OSError:
                    continue
            else:
                cache[size] = ImageFont.load_default()
        return cache[size]

    def rgba(colour) -> tuple[int, int, int, int]:
        if not isinstance(colour, dict):
            return (202, 165, 96, 242)
        r = int(round((colour.get("r") or 0) * 255))
        g = int(round((colour.get("g") or 0) * 255))
        b = int(round((colour.get("b") or 0) * 255))
        a = colour.get("a")
        a = 1.0 if a is None else a
        return (r, g, b, int(round(a * 255)))

    for el in model["elements"]:
        x, y = int(el["x"]), int(el["y"])
        ew, eh = int(el["w"]), int(el["h"])
        if el.get("kind") == "panel":
            draw.rectangle([x, y, x + ew, y + eh], fill=rgba(el.get("colour")),
                           outline=(107, 90, 58, 255), width=2)
        else:
            text = el.get("text") or ""
            if text:
                draw.text((x, y), text, font=font(int(el.get("size") or 12)),
                          fill=rgba(el.get("colour")))

    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tab", default="info", help="which tab to preview")
    parser.add_argument("--theme", default="morrowind", choices=["morrowind", "plain"])
    parser.add_argument("--screen", default="1080x2340", help="portrait WxH (logical)")
    parser.add_argument("--out", type=Path, default=REPO_ROOT / "build" / "console-preview.html")
    parser.add_argument("--png", action="store_true", help="also write a PNG (needs Pillow)")
    parser.add_argument("--png-only", action="store_true", help="write only the PNG")
    parser.add_argument("--list-tabs", action="store_true")
    parser.add_argument("--print-model", action="store_true", help="dump the element table and exit")
    args = parser.parse_args(argv)

    try:
        import importlib

        lupa = importlib.import_module(f"lupa.{FLAVOUR}")
    except ImportError as exc:
        print(f"cannot load embedded runtime '{FLAVOUR}': {exc}", file=sys.stderr)
        print("  pip install lupa", file=sys.stderr)
        return 1

    width, height = (int(v) for v in args.screen.lower().split("x"))

    runtime = lupa.LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(f"package.path = {lua_str(build_package_path())}")
    runtime.execute("package.cpath = ''")
    mock = runtime.eval("require('tools.preview.console_mock')")

    if args.list_tabs:
        uiModel = runtime.eval("require('scripts.idle.uiModel')")
        for t in lua_to_python(uiModel.TABS):
            print(f"{t['id']:10s} {t['label']}")
        return 0

    result = mock.build(width, height, runtime.table_from({"tab": args.tab, "theme": args.theme}))
    model = lua_to_python(result)

    if args.print_model:
        import json

        print(json.dumps(model, indent=2)[:8000])
        return 0

    if args.png_only:
        out = args.out.with_suffix(".png")
        render_png(model, out)
        print(f"wrote {out}  ({len(model['elements'])} elements, tab={args.tab}, theme={args.theme})")
        return 0

    html = render_html(model, args.tab, args.theme)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(html, encoding="utf-8")
    print(f"wrote {args.out}  ({len(model['elements'])} elements, tab={args.tab}, theme={args.theme})")
    if args.png:
        out = args.out.with_suffix(".png")
        render_png(model, out)
        print(f"wrote {out}")
    return 0


def lua_str(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


if __name__ == "__main__":
    sys.exit(main())
