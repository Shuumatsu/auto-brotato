#!/usr/bin/env python3
"""Local benchmark driver for AutoBattler (runs the real game via Steam).

What it does
------------
1. Temporarily disables the other Workshop mods (restores them on exit) and
   installs the current dist/*.zip + the local test harness.
2. For each candidate weight set x scenario:
   - writes user://auto-battler-overrides.json  (the mod merges these into its
     arbiter overrides at startup)
   - writes user://harness_scenario.json        (character + difficulty)
   - launches Brotato through Steam, waits for it to exit, parses the run log
3. Writes calibration/results.csv and restores the original mod set.

Requirements: Steam running + logged in, game launched through Steam (the
workshop item conflict prompt must be accepted once by a human), macOS.
The script must run with write access to the Steam/Brotato data dirs.

Usage (from repo root, with full file access):
    python3 calibration/run_pilot.py --repeats 1
"""
import argparse
import csv
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
GAME = HOME / "Library/Application Support/Steam/steamapps/common/Brotato"
STEAM = HOME / "Library/Application Support/Steam"
WORKSHOP = STEAM / "steamapps/workshop/content/1942280"
MOD_ITEM = WORKSHOP / "3598984651"          # local injection target (Mod Options item)
USER_DATA = HOME / "Library/Application Support/Brotato"
LOGDIR = USER_DATA / "logs"
LOG = LOGDIR / "godot.log"
OVERRIDES = USER_DATA / "auto-battler-overrides.json"
SCENARIO = USER_DATA / "harness_scenario.json"
HARNESS_STATE = USER_DATA / "harness_state.cfg"
HARNESS_CURRENT = USER_DATA / "harness_current.txt"
HARNESS_ZIP = Path(__file__).resolve().parents[1] / "_research/harness-mod/dist/LocalTest-Harness.zip"
DISABLED = "._disabled_by_calibration"

RESULT_RE = re.compile(r"\[HARNESS\] RESULT char=(\S+) reason=(\S+).*?wave=(\d+).*?move_ratio=([0-9.]+).*?t=(\d+)")
HP_RE = re.compile(r"\[HARNESS\] t=\d+ wave=\d+ t_left=[0-9.]+ hp=(\d+)/(\d+)")
PROFILE_RE = re.compile(r"BOTLOG PROFILE char=(\S+) (\{.*\})")


def log(msg):
    print(f"[calib] {msg}", flush=True)


def find_mod_zip() -> Path:
    dist = Path(__file__).resolve().parents[1] / "dist"
    zips = sorted(dist.glob("AutoBattler-*.zip"))
    if not zips:
        raise SystemExit("no dist/AutoBattler-*.zip; run ./build.sh first")
    return zips[-1]


def disable_other_mods():
    moved = []
    for d in WORKSHOP.iterdir():
        if not d.is_dir():
            continue
        for z in d.glob("*.zip"):
            if z.name.startswith("AutoBattler-") or z.name == "LocalTest-Harness.zip":
                continue
            target = d / DISABLED
            target.mkdir(exist_ok=True)
            shutil.move(str(z), str(target / z.name))
            moved.append((d, z.name))
    log(f"disabled {len(moved)} other mod zips")
    return moved


def restore_mods(moved):
    for d, name in moved:
        src = d / DISABLED / name
        if src.exists():
            shutil.move(str(src), str(d / name))
    for d in WORKSHOP.iterdir():
        p = d / DISABLED
        if p.is_dir() and not any(p.iterdir()):
            p.rmdir()
    log(f"restored {len(moved)} mod zips")


def install_test_mods():
    mod = find_mod_zip()
    for f in MOD_ITEM.glob("AutoBattler-*.zip"):
        f.unlink()
    shutil.copy2(mod, MOD_ITEM / mod.name)
    shutil.copy2(HARNESS_ZIP, MOD_ITEM / "LocalTest-Harness.zip")
    log(f"installed {mod.name} + LocalTest-Harness.zip")


def cleanup_test_mods():
    for name in ("LocalTest-Harness.zip",):
        p = MOD_ITEM / name
        if p.exists():
            p.unlink()
    for p in (OVERRIDES, SCENARIO, HARNESS_STATE, HARNESS_CURRENT):
        if p.exists():
            p.unlink()
    log("removed harness + tuning files")


def launch_and_wait(timeout=120):
    try:
        os.remove(LOG)
    except FileNotFoundError:
        pass
    subprocess.run(["open", "steam://rungameid/1942280"], check=False)
    started = False
    t0 = time.time()
    while time.time() - t0 < 30:
        if subprocess.run(["pgrep", "-f", "Brotato.app/Contents/MacOS/Brotato"],
                          capture_output=True).returncode == 0:
            started = True
            break
        time.sleep(1)
    if not started:
        return None, "NO_LAUNCH (Steam prompt/offline?)"
    while time.time() - t0 < timeout:
        if subprocess.run(["pgrep", "-f", "Brotato.app/Contents/MacOS/Brotato"],
                          capture_output=True).returncode != 0:
            time.sleep(1.5)
            try:
                return LOG.read_text(errors="ignore"), "OK"
            except FileNotFoundError:
                return None, "NO_LOG"
        time.sleep(1)
    subprocess.run(["pkill", "-f", "Brotato.app/Contents/MacOS/Brotato"], check=False)
    return None, "TIMEOUT"


def parse_run(text):
    out = {"reason": "", "wave": "", "move_ratio": "", "duration": "",
           "min_hp": "", "max_hp": "", "profile": ""}
    if not text:
        return out
    m = list(RESULT_RE.finditer(text))
    if m:
        last = m[-1]
        out.update(reason=last.group(2), wave=last.group(3),
                   move_ratio=last.group(4), duration=last.group(5))
    hps = [(int(a), int(b)) for a, b in HP_RE.findall(text)]
    if hps:
        out["min_hp"] = min(a for a, _ in hps)
        out["max_hp"] = max(b for _, b in hps)
    pm = list(PROFILE_RE.finditer(text))
    if pm:
        out["profile"] = pm[-1].group(2)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repeats", type=int, default=1)
    ap.add_argument("--scenarios", default="calibration/scenarios.json")
    ap.add_argument("--candidates", default="calibration/candidates.json")
    ap.add_argument("--out", default="calibration/results.csv")
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    candidates = json.loads((root / args.candidates).read_text())["candidates"]
    scenarios = json.loads((root / args.scenarios).read_text())["scenarios"]

    moved = []
    rows = []
    try:
        moved = disable_other_mods()
        install_test_mods()
        total = len(candidates) * len(scenarios) * args.repeats
        n = 0
        for cand in candidates:
            for rep in range(args.repeats):
                for scen in scenarios:
                    n += 1
                    log(f"[{n}/{total}] {cand['name']} / {scen['character']} d{scen['difficulty']} (rep {rep + 1})")
                    OVERRIDES.write_text(json.dumps(cand.get("overrides", {})))
                    SCENARIO.write_text(json.dumps(scen))
                    HARNESS_STATE.unlink(missing_ok=True)
                    text, status = launch_and_wait()
                    if status.startswith("NO_LAUNCH"):
                        log("    launch skipped (Steam prompt?), retrying once")
                        text, status = launch_and_wait()
                    metrics = parse_run(text)
                    runlog = root / "calibration/logs" / f"{cand['name']}_{scen['character']}_d{scen['difficulty']}_r{rep + 1}.log"
                    runlog.parent.mkdir(parents=True, exist_ok=True)
                    if text:
                        runlog.write_text(text)
                    row = {"candidate": cand["name"], "character": scen["character"],
                           "difficulty": scen["difficulty"], "repeat": rep + 1,
                           "status": status, **metrics}
                    rows.append(row)
                    log(f"    -> {status} reason={metrics['reason']} hp={metrics['min_hp']}/{metrics['max_hp']} "
                        f"move={metrics['move_ratio']} t={metrics['duration']}s")
                    (root / args.out).parent.mkdir(parents=True, exist_ok=True)
                    with open(root / args.out, "w", newline="") as f:
                        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
                        w.writeheader()
                        w.writerows(rows)
    finally:
        cleanup_test_mods()
        if moved:
            restore_mods(moved)
    # aggregate summary
    good = [r for r in rows if r["status"] == "OK" and r["min_hp"]]
    agg = {}
    for r in good:
        a = agg.setdefault(r["candidate"], {"n": 0, "clear": 0, "dmg": 0, "hp": []})
        a["n"] += 1
        a["clear"] += 1 if str(r["reason"]).startswith("WAVE_CLEARED") else 0
        a["dmg"] += int(r["max_hp"]) - int(r["min_hp"])
        a["hp"].append(int(r["min_hp"]))
    log("summary (candidate: n, clears, mean damage, min hp)")
    for name, a in agg.items():
        log(f"  {name:16} n={a['n']} clear={a['clear']} dmg={a['dmg']/a['n']:.2f} min_hp={min(a['hp'])}")
    log(f"done -> {root / args.out}")


if __name__ == "__main__":
    main()
