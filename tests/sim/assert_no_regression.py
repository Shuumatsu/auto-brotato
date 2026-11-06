#!/usr/bin/env python3
"""Assertion gate for the closed-loop sim matrix (tests/sim/matrix.sh).

Parses the per-invocation logs and turns the exploratory sim into a real gate:

  A. v2.7.0 exactness: live v2.8 arbiter with cov=0/tapcd=0 (policy v27) must
     produce byte-identical rows to the PINNED v2.7.0 arbiter (git e933740)
     on all 19 scenarios.
  B. 14 legacy scenarios: live v28 (defaults) must be row-identical to live v27
     -- no alive/hp_min/contact/edge regression.
  C. 5 opportunity scenarios: only the documented v2.8 differences are allowed
     (S1: sp_min/nearest/edge; opp_v34_tagged: first-pick/lock/edge); anything
     else fails.
  D. v2.6.1 control arm: live v26 (opp=0) must be row-identical to the PINNED
     v2.6.1 arbiter (git dcb6e39) on all 14 legacy scenarios.
  E. Documented baseline rows (README/TECHNICAL sim tables) must hold for the
     14 legacy scenarios.
  F. Documented headline numbers must hold with a tolerance: S1/S2 reach times
     and distances, S3 loot-alien intercept 11.3s -> 2.8s, opp_v34_tagged
     3.6s -> 2.9s, opp_v34_plain 2.6s.

Exit code 0 only when every check passes. Usage: assert_no_regression.py LOG_DIR
"""

import glob
import os
import re
import sys

LEGACY = [
    "ring10_open", "ring14_fast", "ring20_walls", "ring16_walls", "crossfire",
    "soldier_herd", "melee_herd", "bullet_wall", "item_far_safe",
    "item_far_1slow", "item_far_ring8", "item_lull", "bounty_egg",
    "bounty_cursed",
]
OPP = [
    "opp_s1_blocker1", "opp_s2_blockers2", "opp_s3_lootalien",
    "opp_v34_plain", "opp_v34_tagged",
]

COLS = [
    "scenario", "alive", "t", "hp_min", "contact_s", "surrounded_s",
    "nearest_end", "max_near", "breakout_s", "items", "edge_min", "edge_mean",
    "e150", "e100", "sp_min", "sp_reach", "lock_s",
]

# Allowed live-v28 vs live-v27 differences on the v2.7-era opportunity
# scenarios; everything else must be identical. (Documented in tests/README.md.)
ALLOWED_OPP_DIFFS = {
    # v2.8 Boss class-1 value 30 -> 50 changes the approach path/lock slightly.
    "opp_s1_blocker1": {"nearest_end", "edge_min", "edge_mean", "sp_min"},
    # v2.8 reward tag 2 (crate raw 10 -> 34) makes the detour commit 0.7s earlier.
    "opp_v34_tagged": {"nearest_end", "items", "edge_mean", "lock_s"},
    "opp_s2_blockers2": set(),
    "opp_s3_lootalien": set(),
    "opp_v34_plain": set(),
}

# Documented 14-scenario baseline (docs/TECHNICAL.md §five-point-ten and
# sim/README.md): alive / t / hp_min / contact_s / edge_min for policy v27.
BASELINE = {
    "ring10_open":     (True, 30.0, 94.0, 0.18, 365.6),
    "ring14_fast":     (True, 30.0, 88.0, 0.25, 300.9),
    "ring20_walls":    (True, 30.0, 70.0, 0.27, 268.7),
    "ring16_walls":    (True, 30.0, 82.0, 0.22, 297.2),
    "crossfire":       (True, 30.0, 94.0, 0.18, 236.2),
    "soldier_herd":    (False, 16.6, 0.0, 0.80, 111.4),
    "melee_herd":      (True, 30.0, 70.0, 0.25, 121.1),
    "bullet_wall":     (True, 25.0, 100.0, 0.00, 172.0),
    "item_far_safe":   (True, 20.0, 100.0, 0.00, 293.3),
    "item_far_1slow":  (True, 20.0, 100.0, 0.00, 250.2),
    "item_far_ring8":  (True, 25.0, 100.0, 0.00, 336.8),
    "item_lull":       (True, 25.0, 100.0, 0.00, 337.0),
    "bounty_egg":      (True, 12.0, 100.0, 0.00, 430.1),
    "bounty_cursed":   (True, 12.0, 100.0, 0.00, 324.6),
}

failures = 0
checks = 0


def check(cond, what):
    global checks, failures
    checks += 1
    if cond:
        print("ok   " + what)
    else:
        failures += 1
        print("FAIL " + what)


def parse(path):
    rows = {}
    with open(path, errors="ignore") as fh:
        for line in fh:
            line = re.sub(r"\x1b\[[0-9;]*m", "", line).rstrip("\n")
            if " | " not in line or line.startswith("policy |"):
                continue
            fields = [x.strip() for x in line.split("|")]
            if len(fields) >= 18:
                rows[fields[0]] = tuple(fields[1:])
    return rows


def num(row, col):
    if not row:
        return None
    idx = COLS.index(col)
    if idx >= len(row):
        return None
    try:
        return float(row[idx])
    except (TypeError, ValueError):
        return None


def pick_t(item_field):
    m = re.match(r"(\d+)@(-?[0-9.]+)s$", item_field)
    if not m:
        return None
    return int(m.group(1)), float(m.group(2))


def diff_cols(a, b):
    return [COLS[i] for i in range(len(COLS)) if a[i] != b[i]]


def load_all(log_dir):
    data = {}
    for phase in ("frozen270", "live280", "frozen261"):
        for path in glob.glob(os.path.join(log_dir, f"{phase}_*.txt")):
            scenario = os.path.basename(path)[len(phase) + 1:-4]
            data[(phase, scenario)] = parse(path)
    return data


def main():
    if len(sys.argv) != 2:
        print("usage: assert_no_regression.py LOG_DIR", file=sys.stderr)
        return 2
    log_dir = sys.argv[1]
    data = load_all(log_dir)

    # -- A. v2.7.0 exactness on all 19 scenarios ---------------------------
    for scn in LEGACY + OPP:
        f = data.get(("frozen270", scn), {})
        l = data.get(("live280", scn), {})
        a, b = f.get("v27"), l.get("v27")
        if a is None or b is None:
            check(False, f"v2.7.0 exactness [{scn}]: missing row (frozen={a is not None} live={b is not None})")
            continue
        d = diff_cols(a, b)
        check(not d, f"v2.7.0 exactness [{scn}]: live cov=0 == pinned e933740" +
              ("" if not d else f" diff={d} frozen={a} live={b}"))

    # -- B/C. live v28 vs live v27 ----------------------------------------
    for scn in LEGACY:
        v27 = data.get(("live280", scn), {}).get("v27")
        v28 = data.get(("live280", scn), {}).get("v28")
        if v27 is None or v28 is None:
            check(False, f"v28 no-regression [{scn}]: missing row")
            continue
        d = diff_cols(v27, v28)
        check(not d, f"v28 no-regression [{scn}]: live v28 row-identical to v27" +
              ("" if not d else f" diff={d} v27={v27} v28={v28}"))
    for scn in OPP:
        v27 = data.get(("live280", scn), {}).get("v27")
        v28 = data.get(("live280", scn), {}).get("v28")
        if v27 is None or v28 is None:
            check(False, f"v28 opp diff [{scn}]: missing row")
            continue
        d = set(diff_cols(v27, v28))
        allowed = ALLOWED_OPP_DIFFS[scn]
        check(d <= allowed,
              f"v28 opp diffs [{scn}]: only documented columns differ ({sorted(d)})" +
              ("" if d <= allowed else f" unexpected={sorted(d - allowed)} v27={v27} v28={v28}"))

    # -- D. v2.6.1 control arm --------------------------------------------
    for scn in LEGACY:
        f = data.get(("frozen261", scn), {}).get("v26")
        l = data.get(("live280", scn), {}).get("v26")
        if f is None or l is None:
            check(False, f"v2.6.1 control [{scn}]: missing row")
            continue
        d = diff_cols(f, l)
        check(not d, f"v2.6.1 control [{scn}]: live opp=0 == pinned dcb6e39" +
              ("" if not d else f" diff={d} frozen={f} live={l}"))

    # -- E. documented baseline rows --------------------------------------
    for scn, (alive, t, hp_min, contact, edge_min) in BASELINE.items():
        row = data.get(("frozen270", scn), {}).get("v27")
        if row is None:
            check(False, f"baseline [{scn}]: missing frozen v27 row")
            continue
        alive_field = row[COLS.index("alive")]
        ok = (
            (alive_field == "True") == alive
            and abs(num(row, "t") - t) <= 0.15
            and abs(num(row, "hp_min") - hp_min) <= 0.5
            and abs(num(row, "contact_s") - contact) <= 0.03
            and abs(num(row, "edge_min") - edge_min) <= 1.0
        )
        check(ok, f"baseline row [{scn}]: alive={alive_field} t={num(row, 't')} "
                  f"hp_min={num(row, 'hp_min')} contact={num(row, 'contact_s')} "
                  f"edge_min={num(row, 'edge_min')} (documented {alive}/{t}/"
                  f"{hp_min}/{contact}/{edge_min})")

    # -- F. documented headline numbers (tolerance) ------------------------
    def fetch(phase, scn, policy):
        return data.get((phase, scn), {}).get(policy)

    def near(v, want, tol):
        return v is not None and abs(v - want) <= tol

    s1_v28 = fetch("live280", "opp_s1_blocker1", "v28")
    s1_v27 = fetch("frozen270", "opp_s1_blocker1", "v27")
    check(s1_v28 is not None and near(num(s1_v28, "sp_reach"), 1.77, 0.10)
          and near(num(s1_v28, "sp_min"), 222.5, 2.0),
          f"S1 v28 special reach 1.77s / min 222.5px (got {num(s1_v28, 'sp_reach')}s / {num(s1_v28, 'sp_min')}px)")
    check(s1_v27 is not None and near(num(s1_v27, "sp_reach"), 1.77, 0.10)
          and near(num(s1_v27, "sp_min"), 224.4, 2.0),
          f"S1 v2.7 baseline reach 1.77s / min 224.4px (got {num(s1_v27, 'sp_reach')}s / {num(s1_v27, 'sp_min')}px)")

    s2 = fetch("live280", "opp_s2_blockers2", "v28")
    check(s2 is not None and near(num(s2, "sp_reach"), 1.78, 0.10)
          and near(num(s2, "sp_min"), 39.0, 2.0),
          f"S2 v28 special reach 1.78s / min 39.0px (got {num(s2, 'sp_reach')}s / {num(s2, 'sp_min')}px)")

    def first_pick(row):
        if row is None:
            return None
        return pick_t(row[COLS.index("items")])

    s3_v26 = fetch("live280", "opp_s3_lootalien", "v26")
    s3_v27 = fetch("live280", "opp_s3_lootalien", "v27")
    p26, p27 = first_pick(s3_v26), first_pick(s3_v27)
    check(p26 is not None and p26[0] == 1 and near(p26[1], 11.3, 0.4),
          f"S3 v2.6.1 loot-alien intercept ~11.3s (got {p26})")
    check(p27 is not None and p27[0] == 1 and near(p27[1], 2.8, 0.3),
          f"S3 v2.7/v2.8 loot-alien intercept ~2.8s (got {p27})")

    tagged27 = first_pick(fetch("live280", "opp_v34_tagged", "v27"))
    tagged28 = first_pick(fetch("live280", "opp_v34_tagged", "v28"))
    check(tagged27 is not None and near(tagged27[1], 3.6, 0.4),
          f"opp_v34_tagged v2.7 first pick ~3.6s (got {tagged27})")
    check(tagged28 is not None and near(tagged28[1], 2.9, 0.4),
          f"opp_v34_tagged v2.8 first pick ~2.9s (got {tagged28})")
    plain27 = first_pick(fetch("live280", "opp_v34_plain", "v27"))
    plain28 = first_pick(fetch("live280", "opp_v34_plain", "v28"))
    check(plain27 is not None and near(plain27[1], 2.6, 0.4)
          and plain28 is not None and near(plain28[1], 2.6, 0.4),
          f"opp_v34_plain v27/v28 first pick ~2.6s (got {plain27} / {plain28})")

    print(f"\nRESULT sim checks={checks} fails={failures} "
          f"{'PASS' if failures == 0 else 'FAIL'}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
