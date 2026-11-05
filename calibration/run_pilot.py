#!/usr/bin/env python3
"""Local benchmark driver for AutoBattler (runs the real game via Steam).

What it does
------------
1. Temporarily disables the other Workshop mods (restores them on exit) and
   installs the selected mod zip (--build, default = newest dist/AutoBattler-*.zip)
   + the local test harness.
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
    # v2.3.0 strategy A/B: explicit build + new scenarios/candidates + own CSV
    python3 calibration/run_pilot.py --repeats 3 \
        --build dist/AutoBattler-2.3.0-fork.zip \
        --scenarios calibration/scenarios_strategy.json \
        --candidates calibration/candidates_strategy.json \
        --out calibration/results_strategy.csv
"""
import argparse
import csv
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
import zipfile
from pathlib import Path

HOME = Path.home()
GAME = HOME / "Library/Application Support/Steam/steamapps/common/Brotato"
STEAM = HOME / "Library/Application Support/Steam"
WORKSHOP = STEAM / "steamapps/workshop/content/1942280"
MOD_ITEM = WORKSHOP / "3598984651"          # local injection target, set dynamically in main()
WORKSHOP_ACF = STEAM / "steamapps/workshop/appworkshop_1942280.acf"
# The user's own published AutoBattler Workshop item: never inject there and
# never load it during a benchmark (a second copy of the same mod namespace
# would shadow the build under test).
OWN_WORKSHOP_ITEM = "3834096920"
USER_DATA = HOME / "Library/Application Support/Brotato"
LOGDIR = USER_DATA / "logs"
LOG = LOGDIR / "godot.log"
OVERRIDES = USER_DATA / "auto-battler-overrides.json"
SCENARIO = USER_DATA / "harness_scenario.json"
HARNESS_STATE = USER_DATA / "harness_state.cfg"
HARNESS_CURRENT = USER_DATA / "harness_current.txt"
HARNESS_ZIP = Path(__file__).resolve().parents[1] / "_research/harness-mod/dist/LocalTest-Harness.zip"
DISABLED = "._disabled_by_calibration"

RESULT_RE = re.compile(r"\[HARNESS\] RESULT (.+)")
KV_RE = re.compile(r"(\w+)=(\S+)")
HP_RE = re.compile(r"\[HARNESS\] t=\d+ wave=\d+ t_left=[0-9.]+ hp=(\d+)/(\d+)")
# Per-second line, v2.3.0 harness: ... nearE=<px> wrange=<px> ...
SAMPLE_RE = re.compile(r"\[HARNESS\] t=\d+ .*?nearE=(-?\d+) wrange=(\d+)")
PROFILE_RE = re.compile(r"BOTLOG PROFILE char=(\S+) (\{.*\})")

# CSV columns in order. The legacy prefix stays untouched; the v2.3.0 strategy
# metrics are appended so old result files remain readable by the same code.
FIELDS = ["candidate", "character", "difficulty", "repeat", "status",
          "reason", "wave", "move_ratio", "duration", "min_hp", "max_hp", "profile",
          "trees", "fruit", "gold", "nearE_median", "us_avg"]


def log(msg):
    print(f"[calib] {msg}", flush=True)


def _num(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _mean(values):
    return sum(values) / len(values) if values else float("nan")


def _median(values):
    return statistics.median(values) if values else float("nan")


def pick_mod_item() -> Path:
    """Pick a SUBSCRIBED Workshop item folder as the local injection target.

    ModLoader only loads zips from items listed in Steam's
    WorkshopItemsInstalled (Platform.get_subscribed_mods()). The old hardcoded
    Mod Options item (3598984651) may not be subscribed any more, so pick the
    first installed item that exists on disk, never the user's own AutoBattler
    item (it would load a second copy of the same mod namespace).
    """
    ids = []
    try:
        txt = WORKSHOP_ACF.read_text(errors="ignore")
        m = re.search(r'"WorkshopItemsInstalled"\s*\{(.*?)\n\t\}', txt, re.S)
        block = m.group(1) if m else txt
        ids = re.findall(r'^\s*"(\d{6,})"\s*$', block, re.M)
    except FileNotFoundError:
        pass
    for item_id in ids:
        if item_id == OWN_WORKSHOP_ITEM:
            continue
        path = WORKSHOP / item_id
        if path.is_dir():
            return path
    raise SystemExit("no subscribed workshop item found to inject the build into")


def find_mod_zip() -> Path:
    dist = Path(__file__).resolve().parents[1] / "dist"
    # AutoBattler-v<version>.zip is the release bundle (mod + preview + docs);
    # the plain AutoBattler-<version>-fork.zip is the thing to install into the
    # workshop item folder.
    zips = [z for z in dist.glob("AutoBattler-*.zip") if "-v" not in z.name]
    if not zips:
        raise SystemExit("no dist/AutoBattler-*-fork.zip (release bundles excluded); run ./build.sh first")
    return max(zips, key=lambda p: (p.stat().st_mtime, p.name))


def resolve_build(raw, root: Path) -> Path:
    """Resolve --build (absolute / cwd-relative / repo-relative) and sanity-check it."""
    if not raw:
        return find_mod_zip()
    p = Path(raw).expanduser()
    if not p.is_absolute():
        cwd_try = Path.cwd() / p
        root_try = root / p
        p = cwd_try if cwd_try.exists() else root_try
    p = p.resolve()
    if not p.is_file():
        raise SystemExit(f"--build zip not found: {p}")
    try:
        with zipfile.ZipFile(p) as zf:
            names = zf.namelist()
    except zipfile.BadZipFile:
        raise SystemExit(f"--build is not a valid zip: {p}")
    if not any(n.startswith("mods-unpacked/") for n in names):
        raise SystemExit(f"--build does not look like a ModLoader mod (no mods-unpacked/): {p}")
    return p


def disable_other_mods():
    moved = []
    for d in WORKSHOP.iterdir():
        if not d.is_dir():
            continue
        for z in d.glob("*.zip"):
            # Move EVERY zip, including the injection item's own content: the
            # benchmark must load only the build under test (+ harness), and the
            # user's published AutoBattler item is itself an AutoBattler bundle
            # that would shadow it. Everything is restored in restore_mods().
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


def install_test_mods(build: Path):
    for f in MOD_ITEM.glob("AutoBattler-*.zip"):
        f.unlink()
    shutil.copy2(build, MOD_ITEM / build.name)
    shutil.copy2(HARNESS_ZIP, MOD_ITEM / "LocalTest-Harness.zip")
    log(f"installed {build.name} + LocalTest-Harness.zip")


def cleanup_test_mods():
    for name in ("LocalTest-Harness.zip",):
        p = MOD_ITEM / name
        if p.exists():
            p.unlink()
    # The injection target is another Workshop item: our build zip must not be
    # left behind there (restore_mods puts the item's own content back).
    for p in MOD_ITEM.glob("AutoBattler-*.zip"):
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
    """Parse one game log into CSV metrics.

    Keys starting with "_" are internal to the aggregate summary and are not
    written to the CSV (see FIELDS).
    """
    out = {"reason": "", "wave": "", "move_ratio": "", "duration": "",
           "min_hp": "", "max_hp": "", "profile": "",
           "trees": "", "fruit": "", "gold": "", "nearE_median": "", "us_avg": "",
           "_nearE_wrange": []}
    if not text:
        return out
    results = list(RESULT_RE.finditer(text))
    if results:
        # v2.3.0 RESULT line is a flat key=value list; parse by key so the v2.2
        # format (without the new fields) still works via empty defaults.
        fields = dict(KV_RE.findall(results[-1].group(1)))
        out["reason"] = fields.get("reason", "")
        out["wave"] = fields.get("wave", "")
        out["move_ratio"] = fields.get("move_ratio", "")
        out["duration"] = fields.get("t", "")
        for key in ("trees", "fruit", "gold", "nearE_median", "us_avg"):
            out[key] = fields.get(key, "")
    hps = [(int(a), int(b)) for a, b in HP_RE.findall(text)]
    if hps:
        out["min_hp"] = min(a for a, _ in hps)
        out["max_hp"] = max(b for _, b in hps)
    # §5 kiting metric: nearE/wrange. Per-second samples only; seconds without
    # a live enemy have nearE=-1 and are skipped (should be none on Hard).
    ratios = []
    for near_e, wrange in SAMPLE_RE.findall(text):
        near_i, wrange_i = int(near_e), int(wrange)
        if near_i >= 0 and wrange_i > 0:
            ratios.append(near_i / wrange_i)
    out["_nearE_wrange"] = ratios
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
    ap.add_argument("--build", default=None,
                    help="mod zip to install (default: newest dist/AutoBattler-*.zip; "
                         "release bundles AutoBattler-v*.zip are excluded)")
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    candidates = json.loads((root / args.candidates).read_text())["candidates"]
    scenarios = json.loads((root / args.scenarios).read_text())["scenarios"]
    build = resolve_build(args.build, root)
    log(f"build: {build}")
    log(f"scenarios: {args.scenarios}  candidates: {args.candidates}  repeats: {args.repeats}")

    global MOD_ITEM
    MOD_ITEM = pick_mod_item()
    log(f"injection item: {MOD_ITEM}")
    moved = []
    rows = []
    try:
        moved = disable_other_mods()
        install_test_mods(build)
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
                    if status.startswith(("NO_LAUNCH", "NO_LOG")):
                        log(f"    {status}, retrying once")
                        text, status = launch_and_wait()
                    metrics = parse_run(text)
                    # start_wave in the filename: two scenarios can share
                    # character+difficulty (e.g. D6 wave3 vs D6 wave6) and would
                    # otherwise overwrite each other's per-second log.
                    wave_tag = f"_w{int(scen.get('start_wave', 1))}" if "start_wave" in scen else ""
                    runlog = root / "calibration/logs" / f"{cand['name']}_{scen['character']}_d{scen['difficulty']}{wave_tag}_r{rep + 1}.log"
                    runlog.parent.mkdir(parents=True, exist_ok=True)
                    if text:
                        runlog.write_text(text)
                    row = {"candidate": cand["name"], "character": scen["character"],
                           "difficulty": scen["difficulty"],
                           "start_wave": int(scen.get("start_wave", 1)),
                           "speed": float(scen.get("speed", 1.0)),
                           "repeat": rep + 1, "status": status, **metrics}
                    rows.append(row)
                    log(f"    -> {status} reason={metrics['reason']} hp={metrics['min_hp']}/{metrics['max_hp']} "
                        f"move={metrics['move_ratio']} t={metrics['duration']}s "
                        f"trees={metrics['trees']} fruit={metrics['fruit']} gold={metrics['gold']} "
                        f"nearE={metrics['nearE_median']} us={metrics['us_avg']}")
                    (root / args.out).parent.mkdir(parents=True, exist_ok=True)
                    with open(root / args.out, "w", newline="") as f:
                        w = csv.DictWriter(f, fieldnames=FIELDS, extrasaction="ignore")
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
        a = agg.setdefault(r["candidate"], {
            "n": 0, "clear": 0, "dmg": 0, "hp": [],
            "trees": [], "fruit": [], "gold": [], "nearE": [], "us": [], "ratio": []})
        a["n"] += 1
        a["clear"] += 1 if str(r["reason"]).startswith("WAVE_CLEARED") else 0
        a["dmg"] += int(r["max_hp"]) - int(r["min_hp"])
        a["hp"].append(int(r["min_hp"]))
        for key in ("trees", "fruit", "gold", "nearE_median", "us_avg"):
            value = _num(r.get(key))
            if value is not None:
                # nearE_median/us_avg aggregate as mean-of-per-run-metric.
                a[{"nearE_median": "nearE", "us_avg": "us"}.get(key, key)].append(value)
        a["ratio"].extend(r.get("_nearE_wrange") or [])
    log("summary (candidate: n, clears, mean damage, min hp, mean trees/fruit/gold, "
        "mean nearE_median, nearE/wrange median, mean us)")
    for name, a in agg.items():
        log(f"  {name:16} n={a['n']} clear={a['clear']} dmg={a['dmg']/a['n']:.2f} "
            f"min_hp={min(a['hp'])} trees={_mean(a['trees']):.1f} fruit={_mean(a['fruit']):.1f} "
            f"gold={_mean(a['gold']):.1f} nearE={_mean(a['nearE']):.0f} "
            f"nearE/wrange={_median(a['ratio']):.2f} us={_mean(a['us']):.0f}")
    log(f"done -> {root / args.out}")


if __name__ == "__main__":
    main()
