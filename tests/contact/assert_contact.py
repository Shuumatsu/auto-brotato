#!/usr/bin/env python3
"""Round-7 (v2.10.0) contact-suite gate.

Parses the three instrument logs written by run.sh and prints one parseable
`RESULT contact checks=N fails=0 PASS` line (exit non-zero on failure):

  fixed.log    -- shipped v2.10.0 defaults: every fixture must be contact-free
                  while still collecting the resource (the fix must not make the
                  bot simply refuse to play).
  v291.log     -- exact v2.9.1 control arm (--arb-pullsafe=0 --arb-econdl=1):
                  the designated sensitivity fixtures MUST reproduce contact,
                  otherwise the fixed-arm pass would be vacuous.
  econ_dl.log  -- wave-end deadline unit probe: must print its own RESULT PASS.

Column layout of the sim row (sim.gd print format):
  0 policy | 1 scenario | 2 alive | 3 t | 4 hp_min | 5 contact_s |
  6 surrounded_s | 7 nearest_end | 8 max_near | 9 breakout_s |
  10 items (N@Ts) | 11 edge_min | 12 edge_mean | 13 e<150 | 14 e<100 |
  15 sp_min | 16 firstC | 17 hits | 18 gap_min | 19 kills
"""

import re
import sys
from pathlib import Path


def parse_rows(path: Path):
    rows = {}
    if not path.exists():
        return rows
    for line in path.read_text(errors="replace").splitlines():
        if line.startswith("policy") or "|" not in line:
            continue
        cols = [c.strip() for c in line.split("|")]
        if len(cols) < 20:
            continue
        rows[cols[1]] = cols
    return rows


def main() -> int:
    logs = Path(sys.argv[1])
    fixtures = [s for s in sys.argv[2].split(",") if s]
    sensitive = [s for s in sys.argv[3].split(",") if s]

    fixed = parse_rows(logs / "fixed.log")
    v291 = parse_rows(logs / "v291.log")
    econ_dl_log = logs / "econ_dl.log"

    checks = 0
    fails = 0
    details = []

    def check(cond, what):
        nonlocal checks, fails
        checks += 1
        if not cond:
            fails += 1
            details.append("FAIL " + what)

    # -- fixed arm: no contact, no hits, resource still collected -------------
    for name in fixtures:
        row = fixed.get(name)
        check(row is not None, "fixed arm ran fixture %s" % name)
        if row is None:
            continue
        contact = float(row[5])
        hits = int(float(row[17]))
        check(contact == 0.0, "fixed arm %s: contact_s == 0 (got %.2f)" % (name, contact))
        check(hits == 0, "fixed arm %s: hits == 0 (got %d)" % (name, hits))

    for name in ("econ_meca_alone", "econ_meca_body_between_100"):
        row = fixed.get(name)
        if row is not None:
            picked = int(row[10].split("@")[0])
            check(picked >= 1, "fixed arm %s still collects the resource (picked=%d)" %
                  (name, picked))

    for name in ("econ_meca_body_between_100", "econ_meca_body_between_150",
                 "econ_meca_stillbody_150"):
        row = fixed.get(name)
        if row is not None:
            gap = float(row[18])
            check(gap > 0.0, "fixed arm %s keeps clearance from the body (gap_min=%.2f)" %
                  (name, gap))

    # -- v2.9.1 control arm: sensitivity (must reproduce contact) ------------
    for name in sensitive:
        row = v291.get(name)
        check(row is not None, "v2.9.1 arm ran sensitivity fixture %s" % name)
        if row is None:
            continue
        contact = float(row[5])
        hits = int(float(row[17]))
        check(contact > 0.0 or hits > 0, "v2.9.1 arm %s reproduces the bump "
              "(contact_s=%.2f hits=%d)" % (name, contact, hits))

    # -- wave-end deadline unit probe ---------------------------------------
    econ_text = econ_dl_log.read_text(errors="replace") if econ_dl_log.exists() else ""
    check("RESULT econ_dl checks=" in econ_text, "econ_dl probe printed a RESULT line")
    if "RESULT econ_dl checks=" in econ_text:
        line = [ln for ln in econ_text.splitlines() if ln.startswith("RESULT econ_dl")][-1]
        m = re.search(r"checks=(\d+) fails=(\d+)", line)
        check(m is not None and int(m.group(2)) == 0, "econ_dl probe all checks pass (%s)" % line)

    for d in details:
        print(d)
    verdict = "PASS" if fails == 0 else "FAIL"
    print("RESULT contact checks=%d fails=%d %s" % (checks, fails, verdict))
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
