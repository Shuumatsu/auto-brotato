#!/usr/bin/env bash
# Closed-loop no-regression matrix + assertion gate for the planning/coverage
# work (v2.5-v2.8).
#
#   GODOT_BIN=/path/to/godot bash tests/sim/matrix.sh
#
# Runs the REAL arbiter.gd in a deterministic 60 Hz synthetic world, three ways:
#   * frozen v2.7.0 (git show e933740) with policies v26/v27/v28,
#   * live working-tree arbiter with the same policies,
#   * frozen v2.6.1 (git show dcb6e39) with policy v26.
# Then tests/sim/assert_no_regression.py compares the rows:
#   - v27(pinned v2.7.0) == v27(live) on all 19 scenarios (v2.8 cov=0 exactness),
#   - v28(live defaults) == v27(live) on the 14 legacy scenarios,
#   - an explicit whitelist of documented v2.8 differences on the 5 opportunity
#     scenarios (S1 sp_min/nearest/edge, opp_v34_tagged first-pick/lock),
#   - v26(live) == v26(pinned v2.6.1) on the 14 legacy scenarios,
#   - the documented headline timings/distances (S1/S2/S3/tagged/plain).
# Any other difference fails with a non-zero exit.
#
# Env: GODOT_BIN, GODOT_ARGS (default --no-window), TESTS_WORK_DIR.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="$(git -C "$TESTS_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$TESTS_DIR/.." && pwd))"
WORK="${TESTS_WORK_DIR:-$REPO/tests/.work}/sim"
OUT="$WORK/logs"
RUN="$SCRIPT_DIR/run.sh"

LEGACY="ring10_open ring14_fast ring20_walls ring16_walls crossfire soldier_herd \
melee_herd bullet_wall item_far_safe item_far_1slow item_far_ring8 item_lull \
bounty_egg bounty_cursed"
OPP="opp_s1_blocker1 opp_s2_blockers2 opp_s3_lootalien opp_v34_plain opp_v34_tagged"

die() { echo "sim-matrix: $*" >&2; exit 2; }

export GODOT_BIN

"$RUN" --prepare || die "could not prepare sim project"
mkdir -p "$OUT"
: >"$OUT/index.txt"

invocations=0
run_one() {
	local phase="$1" scenario="$2" policies="$3" ref="${4:-}"
	local rc=0 log="$OUT/${phase}_${scenario}.txt"
	if [ -n "$ref" ]; then
		env SIM_ARBITER_REF="$ref" SIM_ONLY="$scenario" SIM_POLICIES="$policies" \
			"$RUN" >"$log" 2>&1 || rc=$?
	else
		env SIM_ONLY="$scenario" SIM_POLICIES="$policies" "$RUN" >"$log" 2>&1 || rc=$?
	fi
	echo "sim-matrix: ${phase} ${scenario} policies=${policies} exit=${rc}" >>"$OUT/index.txt"
	if [ "$rc" -ne 0 ]; then
		echo "FAIL sim-matrix: ${phase} ${scenario} exited ${rc}" >&2
		tail -20 "$log" >&2
		exit 1
	fi
	invocations=$((invocations + 1))
}

echo "=== sim matrix: frozen v2.7.0 baseline + live + frozen v2.6.1 ==="
for s in $LEGACY; do
	run_one frozen270 "$s" "v26,v27,v28" e933740
done
for s in $OPP; do
	run_one frozen270 "$s" "v26,v27,v28" e933740
done
for s in $LEGACY; do
	run_one live280 "$s" "v26,v27,v28"
done
for s in $OPP; do
	run_one live280 "$s" "v26,v27,v28"
done
for s in $LEGACY; do
	run_one frozen261 "$s" "v26" dcb6e39
done
echo "sim-matrix: ${invocations} invocations complete"

echo "=== assert no regression (live vs pinned references) ==="
python3 "$SCRIPT_DIR/assert_no_regression.py" "$OUT"
