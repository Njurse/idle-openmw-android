#!/usr/bin/env python3
"""Headless test runner for the idle_openmw Lua mod.

Runs the pure-Lua test suite inside an embedded Lua VM (via `lupa`), so the
whole thing is testable on a dev box -- or CI -- with no game, no display, and
no native OpenMW build.  The default flavour is **LuaJIT 2.1**, which is what
OpenMW ships with (see docs/openmw-lua-api.md).

Usage
-----
    python tools/run_tests.py                # run the spec suite under LuaJIT 2.1
    python tools/run_tests.py --all          # also verify under Lua 5.1 and 5.4
    python tools/run_tests.py --flavour lua54
    python tools/run_tests.py --sim          # headless 1000-game-hour simulation
    python tools/run_tests.py --sim --hours 500 --seed 7
    python tools/run_tests.py --list         # list discovered spec modules

Exit code is 0 only when everything is green.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import traceback
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_DIR = REPO_ROOT / "tests" / "spec"
MOD_ROOT = REPO_ROOT / "mods" / "idle_openmw"

# lupa flavour -> human label.  luajit21 == LuaJIT 2.1 == OpenMW's runtime.
FLAVOURS = {
    "luajit21": "LuaJIT 2.1",
    "luajit20": "LuaJIT 2.0",
    "lua51": "Lua 5.1",
    "lua52": "Lua 5.2",
    "lua53": "Lua 5.3",
    "lua54": "Lua 5.4",
    "lua55": "Lua 5.5",
}
DEFAULT_FLAVOUR = "luajit21"
PORTABILITY_FLAVOURS = ["luajit21", "lua51", "lua54"]


def lua_module(flavour: str):
    import importlib

    return importlib.import_module(f"lupa.{flavour}")


def build_package_path() -> str:
    """Path for Lua `require` to find both the tests and the mod's own modules.

    A production module lives at `<mod>/scripts/idle/foo.lua` and is required as
    `scripts.idle.foo`, so the mod root must be on the path -- this mirrors how
    OpenMW's VFS resolves requires from a data folder.
    """
    roots = [REPO_ROOT, MOD_ROOT]
    templates = []
    for root in roots:
        # forward slashes work on every platform for Lua's package.path
        base = root.as_posix()
        templates.append(f"{base}/?.lua")
        templates.append(f"{base}/?/init.lua")
    return ";".join(templates) + ";"


def discover_specs() -> list[str]:
    if not SPEC_DIR.is_dir():
        return []
    names = []
    for path in sorted(SPEC_DIR.glob("*_spec.lua")):
        names.append(f"tests.spec.{path.stem}")
    return names


def manifest_specs() -> list[str]:
    """Read the fallback manifest (tests/specs.lua) for drift detection."""
    manifest = REPO_ROOT / "tests" / "specs.lua"
    if not manifest.is_file():
        return []
    text = manifest.read_text(encoding="utf-8")
    return re.findall(r"['\"](tests[A-Za-z0-9_.]*)['\"]", text)


def make_runtime(flavour: str, color: bool, specs: list[str], extra_globals=None):
    mod = lua_module(flavour)
    runtime = mod.LuaRuntime(unpack_returned_tuples=True)
    globals_ = runtime.globals()
    runtime.execute(f"package.path = {lua_str(build_package_path())}")
    runtime.execute("package.cpath = ''")  # no C modules needed
    globals_.HARNESS_COLOR = "1" if color else "0"
    globals_.HARNESS_SPECS = runtime.table_from(specs)
    for key, value in (extra_globals or {}).items():
        globals_[key] = value
    return runtime


def lua_str(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def lint_specs() -> list[str]:
    """Catch a spec that can never run.

    A spec file wrapped in `return function() ... end` is a silent hole: the
    harness `require`s the module, the wrapper is never called, and the file is
    discovered, loads cleanly, and contributes zero tests. That really happened
    here (two spec files, 27 tests, no error anywhere), so it is checked
    statically -- no harness internals needed, works on any Lua flavour.
    """
    import re as _re
    problems: list[str] = []
    for path in sorted(SPEC_DIR.glob("*_spec.lua")):
        text = path.read_text(encoding="utf-8", errors="replace")
        # strip leading comment/blank lines, then look at the first real statement
        first_statement = _re.sub(r"^(?:\s*--[^\n]*\n|\s*\n)+", "", text).lstrip()
        if first_statement.startswith("return function"):
            problems.append(
                f"{path.name}: wrapped in `return function()` -- the harness never "
                f"calls the wrapper, so it registers no tests; call describe(...) "
                f"at the top level instead")
        elif "describe(" not in text and "it(" not in text:
            problems.append(f"{path.name}: registers no describe()/it() at all")
    return problems


def run_suite(flavour: str, color: bool, verbose: bool, upstream_stdout=None, only: str | None = None) -> bool:
    specs = discover_specs()
    if only:
        specs = [name for name in specs if only in name]
    if not specs:
        print("no spec modules matched under tests/spec/", file=sys.stderr)
        return False

    try:
        runtime = make_runtime(flavour, color, specs)
    except ImportError as exc:
        print(f"  ! cannot load embedded runtime '{flavour}': {exc}", file=sys.stderr)
        return False

    label = FLAVOURS.get(flavour, flavour)
    print(f"\n=== idle_openmw test suite :: {label} ({flavour}) ===")

    entry = (REPO_ROOT / "tests" / "run.lua").read_text(encoding="utf-8")
    sys.stdout.flush()
    try:
        runtime.execute(entry, "tests/run.lua")
    except Exception:  # noqa: BLE001 - surface the Lua traceback verbatim
        print(traceback.format_exc(), file=sys.stderr)
        return False
    sys.stdout.flush()

    result = runtime.globals().HARNESS_RESULT
    if result is None:
        print("  ! run.lua did not produce HARNESS_RESULT", file=sys.stderr)
        return False

    summary = {k: result[k] for k in ("ok", "passed", "failed", "pending", "loadErrors")}
    if verbose:
        print(f"  summary: {summary}")
    return bool(summary["ok"])


def run_sim(flavour: str, hours: float, seed: int, color: bool, verbose: bool) -> bool:
    try:
        runtime = make_runtime(flavour, color, [])
    except ImportError as exc:
        print(f"  ! cannot load embedded runtime '{flavour}': {exc}", file=sys.stderr)
        return False

    globals_ = runtime.globals()
    globals_.SIM_HOURS = hours
    globals_.SIM_SEED = seed
    globals_.SIM_VERBOSE = "1" if verbose else "0"

    label = FLAVOURS.get(flavour, flavour)
    print(f"\n=== idle_openmw headless simulation :: {label} :: {hours:g} game-hours, seed {seed} ===")

    entry = (REPO_ROOT / "tests" / "sim" / "headless_sim.lua").read_text(encoding="utf-8")
    try:
        runtime.execute(entry, "tests/sim/headless_sim.lua")
    except Exception:  # noqa: BLE001
        print(traceback.format_exc(), file=sys.stderr)
        return False

    result = globals_.SIM_RESULT
    if result is None:
        print("  ! headless_sim.lua did not produce SIM_RESULT", file=sys.stderr)
        return False
    summary = {k: result[k] for k in result.keys()}
    print(f"  summary: {summary}")
    return bool(result["ok"])


def check_manifest_drift() -> None:
    on_disk = set(discover_specs())
    listed = set(manifest_specs())
    missing = on_disk - listed
    if missing:
        print(
            "  note: tests/specs.lua is out of date (fallback manifest). "
            f"Add: {', '.join(sorted(missing))}\n"
            "        The Python runner still picked them up from disk.",
            file=sys.stderr,
        )


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--flavour", default=DEFAULT_FLAVOUR, choices=sorted(FLAVOURS))
    parser.add_argument("--all", action="store_true", help="run LuaJIT 2.1 + Lua 5.1 + Lua 5.4")
    parser.add_argument("--sim", action="store_true", help="run the headless simulation harness instead of the specs")
    parser.add_argument("--hours", type=float, default=1000.0, help="simulated game-hours (with --sim)")
    parser.add_argument("--seed", type=int, default=1337, help="RNG seed (with --sim)")
    parser.add_argument("--trace", action="store_true",
                        help="print the decision trace (with --sim; see scripts/idle/trace.lua)")
    parser.add_argument("--list", action="store_true", help="list discovered spec modules and exit")
    parser.add_argument("--only", default=None,
                        help="only run spec modules whose name contains this (e.g. --only director)")
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("--no-color", action="store_true")
    args = parser.parse_args(argv)

    if args.list:
        for name in discover_specs():
            print(name)
        return 0

    color = not args.no_color and os.environ.get("NO_COLOR") is None and sys.stdout.isatty()
    if args.trace:
        os.environ["HARNESS_TRACE"] = "1"

    os.chdir(REPO_ROOT)

    if args.sim:
        ok = run_sim(args.flavour, args.hours, args.seed, color, args.verbose)
        print("\n  SIMULATION OK\n" if ok else "\n  SIMULATION FAILED\n")
        return 0 if ok else 1

    check_manifest_drift()

    # a spec that can never run is worse than no spec: fail before running
    lint_problems = lint_specs()
    if lint_problems:
        for problem in lint_problems:
            print(f"  SPEC LINT  {problem}", file=sys.stderr)
        print(f"\n  {len(lint_problems)} spec file(s) would never run.\n", file=sys.stderr)
        return 1

    flavours = PORTABILITY_FLAVOURS if args.all else [args.flavour]
    results = {}
    for flavour in flavours:
        results[flavour] = run_suite(flavour, color, args.verbose, only=args.only)

    print("\n" + "=" * 46)
    for flavour, ok in results.items():
        label = FLAVOURS.get(flavour, flavour)
        print(f"  {label:<12} {'PASS' if ok else 'FAIL'}")
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
