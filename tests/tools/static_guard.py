#!/usr/bin/env python3
"""Static guards for GDScript hazards that only fail in the REAL game.

Why this exists
---------------
v2.9.0 shipped with `if "nb_of_waves" in RunData:` in world_view.gd. The
offline parse gate (`check_gd.sh`, stub project) compiled it fine, but in the
real mod-loader context the steering script is compiled before RunData is a
typed constant: `String in RunData` is constant-folded with a null right-hand
operand and fails at PARSE time with

    Parse Error: Invalid operand types ("String" and "null") to operator "in"

The whole world_view script then fails to load, the movement behaviour's
preload chain fails, and the autopilot silently never moves (real-game
regression, 2026-11-07 play test: "角色根本没有移动").

`Object.get("property")` at RUNTIME is safe. This guard makes the class of
mistake impossible to ship again: it scans every shipped .gd for `"key" in
<autoload>` probes and fails.

Usage:
    python3 tests/tools/static_guard.py <mod_dir>
    python3 tests/tools/static_guard.py --selftest
"""
import re
import sys
import tempfile
from pathlib import Path

AUTOLOADS = [
    "RunData", "Utils", "Keys", "ProgressData", "DebugService",
    "ItemService", "ZoneService", "TempStats", "ModLoaderMod",
    "SoundManager", "SoundManager2D", "MusicManager", "Text",
    "ChallengeService", "InputService", "WeaponService", "EntityService",
    "LinkedStats", "Platform", "Streamplay", "UIService", "OS_Seaven",
]
FORBIDDEN = [
    (
        re.compile(
            r'"[a-z0-9_]+"\s+in\s+(' + "|".join(AUTOLOADS) + r")\b"
        ),
        'autoload `"key" in Autoload` fails at PARSE time in the real game '
        '(v2.9.0 regression); use Object.get("key") at runtime instead',
    ),
]


def scan_file(path: Path):
    problems = []
    text = path.read_text(encoding="utf-8", errors="replace")
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        for pattern, why in FORBIDDEN:
            if pattern.search(line):
                problems.append((lineno, line.strip(), why))
    return problems


def scan_tree(root: Path) -> int:
    files = sorted(root.rglob("*.gd"))
    failures = 0
    for f in files:
        for lineno, line, why in scan_file(f):
            rel = f.relative_to(root)
            print(f"STATIC_FAIL {rel}:{lineno}: {line}")
            print(f"  -> {why}")
            failures += 1
    if failures:
        print(f"RESULT static_guard files={len(files)} violations={failures} FAIL")
        return 1
    print(f"RESULT static_guard files={len(files)} violations=0 PASS")
    return 0


def selftest() -> int:
    """The guard must catch the exact v2.9.0 pattern (and not flag safe code)."""
    bad = (
        'extends Reference\n'
        'func f():\n'
        '    if "nb_of_waves" in RunData:\n'
        '        pass\n'
    )
    good = (
        'extends Reference\n'
        'func f():\n'
        '    var v = RunData.get("nb_of_waves")\n'
        '    if v != null:\n'
        '        pass\n'
    )
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        (root / "bad.gd").write_text(bad)
        (root / "good.gd").write_text(good)
        caught_bad = scan_file(root / "bad.gd") != []
        caught_good = scan_file(root / "good.gd") == []
    ok = caught_bad and caught_good
    print(f"STATIC_SELFTEST forbidden_detected={caught_bad} safe_code_clean={caught_good} "
          + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    if len(sys.argv) < 2:
        print("usage: static_guard.py <mod_dir> | --selftest", file=sys.stderr)
        sys.exit(2)
    sys.exit(scan_tree(Path(sys.argv[1])))
