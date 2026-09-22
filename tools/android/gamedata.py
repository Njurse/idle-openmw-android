"""Locate, validate and stage a Morrowind install for OpenMW and the Android build.

Why this exists
---------------
OpenMW ships an *engine*; it contains no game assets. Everything OpenMW can load
comes from a Morrowind install, and the Android port needs that data either inside
its app-private directory or in a user-chosen folder on the device. So there is a
real step between "Morrowind is installed on Steam" and "the mod can run", and this
module is that step.

Design: every non-trivial decision is a pure function over paths, so it is
unit-testable without a game install (see tests/test_gamedata.py). The CLI at the
bottom is a thin wrapper with no logic of its own.

Verified against the Steam GOTY layout:
    <steam>/steamapps/common/Morrowind/Data Files/{Morrowind,Tribunal,Bloodmoon}.{esm,bsa}
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# what a complete, unmodded GOTY install contains
# ---------------------------------------------------------------------------

#: The three masters and their archives. Absent any of these, OpenMW cannot load
#: the game, so they are required (not merely nice to have).
REQUIRED_FILES = (
    "Morrowind.esm",
    "Tribunal.esm",
    "Bloodmoon.esm",
    "Morrowind.bsa",
    "Tribunal.bsa",
    "Bloodmoon.bsa",
)

#: Load order OpenMW expects for GOTY. Bloodmoon before Morrowind is deliberate:
#: it matches the order Bethesda's own Morrowind.ini ships with.
CONTENT_LOAD_ORDER = (
    "Morrowind.esm",
    "Tribunal.esm",
    "Bloodmoon.esm",
)

DATA_DIR_NAMES = ("Data Files", "DataFiles", "Data")

#: Where a Morrowind install hides on Windows, in the order worth trying.
STEAM_RELATIVE = Path("steamapps") / "common" / "Morrowind"
STEAM_COMMON = Path("steamapps") / "common"
MORROWIND_DIR_NAMES = ("Morrowind", "The Elder Scrolls III - Morrowind",
                       "The Elder Scrolls III Morrowind", "Morrowind GOTY")


# ---------------------------------------------------------------------------
# pure logic
# ---------------------------------------------------------------------------

def data_dir_of(install_dir: Path) -> Path | None:
    """The `Data Files` directory inside a Morrowind install, or None."""
    if install_dir is None:
        return None
    for name in DATA_DIR_NAMES:
        candidate = install_dir / name
        if candidate.is_dir():
            return candidate
    return None


def looks_like_morrowind(candidate: Path) -> bool:
    """True when `candidate` is a Morrowind install root (has a populated Data Files)."""
    data = data_dir_of(candidate)
    if data is None:
        return False
    return (data / "Morrowind.esm").is_file()


def steam_library_roots(steam_dir: Path) -> list[Path]:
    """Every library root a Steam install knows about, primary first.

    Steam records extra libraries in `steamapps/libraryfolders.vdf` (and, on older
    layouts, `config/libraryfolders.vdf`). The file is a tiny VDF, so rather than
    pull in a dependency we scan it for `"path"` values -- which is exactly the
    shape we need and is stable across Steam versions.
    """
    roots: list[Path] = []
    if steam_dir is None or not steam_dir.is_dir():
        return roots
    roots.append(steam_dir)

    for vdf in (steam_dir / "steamapps" / "libraryfolders.vdf",
                steam_dir / "config" / "libraryfolders.vdf"):
        if not vdf.is_file():
            continue
        try:
            text = vdf.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            line = line.strip()
            if not line.startswith('"path"'):
                continue
            _, _, value = line.partition("\t")
            value = value.strip().strip('"').replace("\\\\", "\\")
            if value:
                path = Path(value)
                if path not in roots:
                    roots.append(path)
    return roots


def candidate_installs(steam_dirs=(), extra_roots=()) -> list[Path]:
    """Every plausible Morrowind install root, most likely first."""
    seen: list[Path] = []
    candidates: list[Path] = []

    def add(path: Path) -> None:
        if path not in seen:
            seen.append(path)
            candidates.append(path)

    for steam in steam_dirs:
        for root in steam_library_roots(Path(steam)):
            for name in MORROWIND_DIR_NAMES:
                add(root / STEAM_COMMON / name)
            add(root / STEAM_RELATIVE)

    # GOG and hand-rolled installs
    for root in extra_roots:
        root = Path(root)
        for name in MORROWIND_DIR_NAMES:
            add(root / name)

    return candidates


def find_install(steam_dirs=(), extra_roots=(), explicit: str | None = None) -> Path | None:
    """The first directory that really is a Morrowind install.

    An explicit path wins, but it still has to validate -- a wrong path should
    fail loudly rather than produce a half-working OpenMW setup.
    """
    if explicit:
        path = Path(explicit)
        # accept being pointed at either the install root or its Data Files
        if looks_like_morrowind(path):
            return path
        parent = path.parent
        if path.name in DATA_DIR_NAMES and looks_like_morrowind(parent):
            return parent
        return None

    for candidate in candidate_installs(steam_dirs, extra_roots):
        if looks_like_morrowind(candidate):
            return candidate
    return None


def validate(data_dir: Path) -> dict:
    """Report which required files are present, with sizes.

    Returns a plain dict so callers (and tests) can assert on it without touching
    the filesystem further.
    """
    data_dir = Path(data_dir)
    found, missing = [], []
    total = 0
    for name in REQUIRED_FILES:
        path = data_dir / name
        if path.is_file():
            size = path.stat().st_size
            found.append({"name": name, "size": size})
            total += size
        else:
            missing.append(name)
    return {
        "data_dir": str(data_dir),
        "ok": not missing,
        "found": found,
        "missing": missing,
        "total_bytes": total,
    }


def sha256_of(path: Path, chunk: int = 1 << 20) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(chunk), b""):
            digest.update(block)
    return digest.hexdigest()


def build_manifest(data_dir: Path, hash_files: bool = False) -> dict:
    """A JSON-serialisable description of the staged data, for drift detection."""
    report = validate(data_dir)
    entries = []
    for item in report["found"]:
        entry = dict(item)
        if hash_files:
            entry["sha256"] = sha256_of(Path(data_dir) / item["name"])
        entries.append(entry)
    return {
        "format": 1,
        "required": list(REQUIRED_FILES),
        "ok": report["ok"],
        "missing": report["missing"],
        "files": entries,
        "total_bytes": report["total_bytes"],
    }


def openmw_cfg_fragment(data_dir: Path, content=None) -> str:
    """The `data=` / `content=` lines that make OpenMW load this install.

    Paths use forward slashes: OpenMW accepts them on every platform, and they
    survive being copied into a file that a Windows and a Linux build both read.
    """
    data = str(data_dir).replace("\\", "/")
    lines = [
        "# Generated by tools/android/gamedata.py -- do not edit by hand.",
        "# Append these to your user openmw.cfg (see docs/android.md).",
        f'data="{data}"',
    ]
    for name in (content or CONTENT_LOAD_ORDER):
        lines.append(f"content={name}")
    return "\n".join(lines) + "\n"


def plan_import(install_dir: Path, dest: Path) -> list[tuple[Path, Path]]:
    """The (source, destination) pairs an import would copy. Pure; copies nothing."""
    data = data_dir_of(Path(install_dir))
    if data is None:
        raise ValueError(f"{install_dir} has no Data Files directory")
    dest = Path(dest)
    pairs = []
    for name in REQUIRED_FILES:
        src = data / name
        if src.is_file():
            pairs.append((src, dest / name))
    return pairs


def import_data(install_dir: Path, dest: Path, overwrite: bool = False,
                on_progress=None) -> dict:
    """Copy the required files into `dest`, skipping ones already there.

    Idempotent: re-running copies only what is missing unless `overwrite` is set,
    so a 1.1 GB staging directory is not rewritten on every invocation.
    """
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    pairs = plan_import(install_dir, dest)
    copied, skipped = [], []
    for index, (src, target) in enumerate(pairs, start=1):
        if on_progress:
            on_progress(index, len(pairs), src.name)
        if target.is_file() and not overwrite and target.stat().st_size == src.stat().st_size:
            skipped.append(src.name)
            continue
        shutil.copy2(src, target)
        copied.append(src.name)
    return {"dest": str(dest), "copied": copied, "skipped": skipped}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _steam_dirs(extra) -> list[Path]:
    dirs = [Path(r"c:/program files (x86)/steam"), Path(r"c:/program files/steam")]
    dirs.extend(Path(p) for p in extra)
    return [d for d in dirs if d.is_dir()]


def main(argv=None) -> int:
    here = Path(__file__).resolve().parent
    repo = here.parent.parent
    default_dest = repo / "gamedata"

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--find", action="store_true", help="print the install found and exit")
    parser.add_argument("--check", nargs="?", const=str(default_dest), metavar="DIR",
                        help="validate a staged data directory")
    parser.add_argument("--import", dest="do_import", action="store_true",
                        help="copy the required files into --dest")
    parser.add_argument("--print-cfg", metavar="DIR", help="print an openmw.cfg fragment for DIR")
    parser.add_argument("--source", help="Morrowind install root (or its Data Files dir)")
    parser.add_argument("--dest", default=str(default_dest), help="staging directory")
    parser.add_argument("--steam", action="append", default=[], help="extra Steam root")
    parser.add_argument("--extra-root", action="append", default=[], help="extra search root (GOG etc.)")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args(argv)

    if args.print_cfg:
        sys.stdout.write(openmw_cfg_fragment(Path(args.print_cfg)))
        return 0

    if args.check is not None and not args.do_import and not args.find:
        report = validate(Path(args.check))
        if args.json:
            print(json.dumps(report, indent=2))
        else:
            print(f"data dir : {report['data_dir']}")
            print(f"complete : {'YES' if report['ok'] else 'NO'}")
            print(f"total    : {report['total_bytes'] / 1e6:.1f} MB")
            for name in report["missing"]:
                print(f"  MISSING: {name}")
        return 0 if report["ok"] else 1

    install = find_install(
        steam_dirs=_steam_dirs(args.steam),
        extra_roots=[Path(p) for p in args.extra_root],
        explicit=args.source,
    )

    if args.find or install is None:
        if install is None:
            print("No Morrowind install found.", file=sys.stderr)
            print("  Install Morrowind GOTY (Steam/GOG), or pass --source <path>.", file=sys.stderr)
            if args.source:
                print(f"  --source {args.source} did not look like a Morrowind install.", file=sys.stderr)
            return 1
        print(install)
        if not args.do_import:
            return 0

    report = validate(data_dir_of(install))
    if not report["ok"]:
        print(f"Incomplete install at {install} — missing: {', '.join(report['missing'])}",
              file=sys.stderr)
        return 1

    if args.do_import:
        print(f"staging {install} -> {args.dest}")
        result = import_data(
            install, Path(args.dest),
            on_progress=lambda i, n, name: print(f"  [{i}/{n}] {name}", flush=True),
        )
        print(f"copied {len(result['copied'])}, already present {len(result['skipped'])}")

    fragment = Path(args.dest) / "openmw.cfg.fragment"
    fragment.write_text(openmw_cfg_fragment(Path(args.dest)), encoding="utf-8")
    print(f"wrote {fragment}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
