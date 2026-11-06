# Offline verification suites (tracked, reproducible)

These tests run the **real shipped mod scripts** (`mod/mods-unpacked/Pasha-AutoBattler/**/*.gd`)
headlessly on Godot 3.6.1, with no game, no Steam and no `_research/` directory. Everything
needed is tracked in this repository: stub Godot projects, test scripts, and the frozen
references (regenerated from git history with `git show <pinned-commit>`).

```bash
GODOT_BIN=/path/to/godot-3.6.1 bash tests/run_all.sh
```

Expected output: one `PASS` line per suite followed by `ALL SUITES PASSED`. Logs are written to
`tests/.work/logs/<suite>.log` (gitignored).

> Requirements: Godot **3.6.x** and a **full git clone** (frozen references are git commits).
> A shallow clone (`--depth 1`) will fail the frozen references; use `fetch-depth: 0` in CI.

---

## 1. Suites

| # | Suite | Command | What it verifies | Expected result |
|---|---|---|---|---|
| 1 | `check_gd` | `tests/tools/check_gd.sh` | every `.gd` file shipped in `mod/` compiles against stub autoloads/classes (parse/compile gate; nothing is instantiated) | `RESULT check_gd targets=N loaded=N failed=0 PASS` |
| 2 | `check_gd --selftest` | `tests/tools/check_gd.sh --selftest` | the parse gate is not a rubber stamp: injects a syntax error into target scripts and an undeclared singleton, and requires the expected failure/line | `SELFTEST PASSED` (exit 0) |
| 3 | `planner` | `tests/planner/run.sh` | arbiter synthetic selftest (`proj/test.gd`, 470 checks: 143 frozen-implementation differential + design contract + internal invariants) and the independent seeded fuzz falsifier (`proj/falsify_v270.gd`, 2476 checks) | `RESULT planner checks=470 fails=0 PASS` + `RESULT falsifier checks=2476 fails=0 PASS` |
| 4 | `gate` | `tests/gate/run.sh` | closed-loop acceptance gate for the v2.5–v2.8 planning/coverage work (enclosure, item goals, control-arm equivalence vs frozen v2.4.0, bounty/opportunity probes, F1/F2/G1) | `RESULT gate checks=32 fails=0 PASS` |
| 5 | `worldview` | `tests/worldview/run.sh` | `world_view.gather()` tuple contract: Boss class 1 vs elite class 4, reward tags 1–5 at index 6, fire_wait_frames, dpsref, and exactness vs a pinned v2.7.0 reference with the same override set | `RESULT worldview checks=32 fails=0 PASS` |
| 6 | `sim` | `tests/sim/matrix.sh` | closed-loop synthetic simulation (real arbiter, deterministic 60 Hz world): 52 invocations across frozen v2.7.0 / live / frozen v2.6.1; `tests/sim/assert_no_regression.py` gates exact-row equality + an explicit whitelist + the documented headline numbers | `RESULT sim checks=N fails=0 PASS` |
| 7 | `econ` (future) | `tests/econ/run.sh` | closed-loop economic objective sim (added with the economy work). `run_all.sh` picks it up automatically when present; it must print a `RESULT econ ... (PASS|FAIL)` line and exit non-zero on failure. | `RESULT econ checks=N fails=0 PASS` |

Approximate wall time on an Apple M4 Pro: check_gd 1.4s, selftest 2.5s, planner 6s, gate 24s,
worldview 2.5s, sim ~2min → **~2.5 min total**.

## 2. Frozen references (why these exact commits)

Frozen references are **never** manual copies and **never** `HEAD` — they are generated with
`git show <commit>:<path>` at run time (each run script fails loudly if the commit is missing):

| Reference | Commit | Meaning |
|---|---|---|
| `arbiter_old.gd` | `0ac6ab5` | pre-v2.3 arbiter (control arm #1 in `test.gd`) |
| `arbiter_v261.gd` | `dcb6e39` | v2.6.1 arbiter (v2.7 opportunity-layer control arm) |
| `arbiter_v27.gd` | `e933740` | v2.7.0 arbiter (v2.8 coverage/tapcd control arm) |
| `arbiter_v240.gd` | `751f3c3` | v2.4.0 arbiter (gate scenario C control arm) |
| `ref_v270_world_view.gd` | `e933740` | v2.7.0 world_view (worldview exactness probe) |

Optional env overrides (for reverse validation / intentionally moving the baseline):
`REF_OLD_COMMIT`, `REF_V261_COMMIT`, `REF_V27_COMMIT`, `GATE_REF`, `REF_WORLDVIEW_COMMIT`.

## 3. Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `GODOT_BIN` | dev fallback `_research/tools/Godot.app/Contents/MacOS/Godot` (local checkout only) | Godot 3.6.x binary. **Required in CI/clean checkout.** |
| `GODOT_ARGS` | `--no-window` | Extra Godot flags. Set to `""` for a headless/server build that rejects `--no-window`. |
| `TESTS_WORK_DIR` | `tests/.work` | scratch directory for generated reference files/logs (gitignored). |
| `RUN_SUITES` | all | space-separated subset, e.g. `RUN_SUITES="check_gd planner"`. |
| `SIM_*` | — | forwarded to the sim (`SIM_ONLY`, `SIM_POLICIES`, `SIM_SCRIPT`, `SIM_ARBITER_REF`, ...). |

## 4. CI

`.github/workflows/build.yml` has a `test` job (ubuntu-latest) next to the existing `build` job:
it checks out with `fetch-depth: 0` (needed for `git show` pins), downloads the official
Godot 3.6.1 **linux_headless** build, and runs `GODOT_ARGS="" bash tests/run_all.sh`.
The job uploads `tests/.work/logs/` as an artifact when it fails.

## 5. Coverage matrix (what the tests actually assert)

| Claim / behaviour | Test | Real assertion | Limitation |
|---|---|---|---|
| Shipped scripts are syntactically loadable | `check_gd` | `load()`+`can_instance()` for every mod `.gd`; selftest injects errors and requires failure at the expected line | parse/compile only — no execution |
| Arbiter control arms reproduce frozen releases when switches are off | `planner` (143 of 470 checks) | exact direction/state equality vs arbiter at `dcb6e39`/`e933740`/`0ac6ab5` | differential vs historical code, not "good behaviour" |
| v2.8 coverage classes/values & reward tags are implemented as designed | `planner` (67 + 44 checks), `gate` (G1), `worldview` | hardcoded design values (class 50/40/18/30, tags 20/34/20/12/7), commit/no-commit decisions, reward[6] tag emission | design-contract, not calibrated against the real game |
| Opportunity planning/risk layer works | `gate` (E/F/G), `sim` (S1/S2/S3, v34) | closed-loop reach times/distances in synthetic worlds (`S1 1.77s/222.5px`, `S2 1.78s/39.0px`, loot-alien `11.3s→2.8s`, tagged `3.6s→2.9s`) | synthetic world; weapon/aiming not simulated |
| No regression vs v2.6.1/v2.7.0/v2.8 defaults | `planner` control arms, `gate` C, `sim` matrix | exact row/direction equality, whitelisted v2.8 sim diffs | only what the synthetic fixtures exercise |
| `world_view` live/ref tuple exactness | `worldview` | live(cov=0,tapcd=0) vs pinned e933740(cov=0,tapcd=0): targets/threats/rewards deep-equal | stub game objects; probe-level, not full gather scenarios |
| `world_view` produces v2.8 tags/fire_wait/dpsref | `worldview` | Boss class 1/elite class 4; crate/legendary/evo/loot/tree tags; `fire_wait_frames` 0/5/min/-1; `_kill_ref` 25.7/154.3/20 | not validated in a real game |
| Full-HP fruit / tree / gold pickup effects / wave-end collection / economy-vs-survival | **none yet** | — | known gap; the tracked gate does not cover the economic objective yet. `tests/econ/` will be added by the economy work. |
| Movement behaviour (`tap-CD` state machine) | **none** (parse only) | `check_gd` compiles `player_movement_behavior.gd` | behavioural test still missing; `worldview` only covers the `fire_wait_frames` value it consumes |
| Real-machine (Steam) behaviour | **not covered** | — | out of scope for offline tests; requires user-run A/B |

### Reverse validation (making sure the gates can fail)

Every gated suite can be made red on purpose:

```bash
# planner: use v2.8 as the "v2.7.0" reference -> control-arm checks must fail
REF_V27_COMMIT=HEAD GODOT_BIN=... bash tests/planner/run.sh           # expected: non-zero
# gate: use v2.8 as the "v2.4.0" reference -> scenario C must fail
GATE_REF=HEAD GODOT_BIN=... bash tests/gate/run.sh                    # expected: non-zero
# worldview: use v2.8 as the "v2.7.0" reference -> exactness checks must fail
REF_WORLDVIEW_COMMIT=HEAD GODOT_BIN=... bash tests/worldview/run.sh    # expected: non-zero
# check_gd: inject a syntax error (selftest) or break a mod file -> non-zero
```

`tests/run_all.sh` returns non-zero if any suite fails (verified by the reverse checks above).

## 6. Historical / retired suites (not part of the tracked gate)

These lived in the gitignored `_research/` tree during development. They are **deliberately not
migrated** into the tracked gate:

- **`_research/dlc-selftest/run.sh`** (v2.4.0 world_view self-test) — **red at v2.8.0**. Reasons:
  it hardcodes v2.4-era reward tuple arity (2-field drops / 4-field held rewards) while v2.5–v2.8
  moved to 5/6/7-field tuples and reward tags; it exports its "frozen" reference from `git HEAD`,
  which was the v2.3.0 script when the suite was written but is now v2.8.0 itself (so the
  sensitivity arm compares live against live); and its optional harness self-check is skipped
  because `proj/ref_world_view.gd` is not present. Its `SENSITIVITY`/`mutate.sh` self-checks are
  therefore not a usable gate.
- The old `_research/planning-v270/worldview-probe/run-v28.sh` probe had the same HEAD-as-frozen
  bug identified during the verification audit (live `cov=0` compared against a `HEAD` copy that
  defaults to `cov=1`). `tests/worldview/` is the fixed replacement: pinned commit + identical
  override sets on both arms + `RESULT`-gated exit code.
- Documentation claim "离线 297 条断言覆盖" (docs/TECHNICAL.md, v2.4.0 section) refers to that
  retired suite and is **outdated**; the tracked replacement numbers are the ones in §1 above.

## 7. Maintenance notes

- **Steering split (planned structural refactor):** the planner/gate/sim/worldview runners copy
  the whole `mod/mods-unpacked/Pasha-AutoBattler` tree into the scratch project **and** copy
  `steering/*.gd` to the project root, so both `res://mods-unpacked/...` and `res://arbiter.gd` /
  `res://world_view.gd` style preloads resolve if `steering/` is split into more files. If the
  entry-file names change (`arbiter.gd`/`world_view.gd`), update the `cp` lines in the run scripts.
- **Intentional check-count changes** (new tests): update the `EXPECT_*` constants in
  `tests/planner/run.sh`, `tests/gate/run.sh`, `tests/worldview/run.sh`, and (for sim) any
  changed documented rows in `tests/sim/assert_no_regression.py`.
- **Python 3** is required only by the sim assertion script (stdlib only).
- Generated files/logs go to `tests/.work/` (gitignored) — a test run never dirties the repo.
