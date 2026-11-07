#!/usr/bin/env bash
# Round-7 (v2.10.0) contact-avoidance regression suite.
#
#   GODOT_BIN=/path/to/godot-3.6.1 bash tests/contact/run.sh
#
# Reproduces the seventh play-test report -- "in relatively simple/sparse
# situations the character walks into a monster" -- in a deterministic 60 Hz
# closed-loop world with the REAL shipped modules:
#
#   * economy-committed reward behind a body on the route (v2.9 economy layer),
#   * the exact real-game user loadout (Survivor max HP 10, 2x ghost flint
#     melee, so weapon_range 170 / kite_frac 0).
#
# Three invocations, all on the live arbiter through the shipped config path
# (Config.parse({}, {}) + apply_config):
#
#   1. fixed   -- shipped v2.10.0 defaults (pull guard ON, single deadline)
#   2. v291    -- exact v2.9.1 arm  (SIM_OVR="pullsafe=0,econdl=1")
#   3. econ_dl -- wave-end deadline unit probe (double vs single scaling)
#
# Then assert_contact.py gates the results:
#   * fixed arm: 0 contact / 0 hits on every fixture, and the resources are
#     still collected (the fix must not simply refuse to play),
#   * v2.9.1 arm: contact > 0 on the two designated sensitivity fixtures
#     (proves the fixtures can fail and the guard is what prevents them),
#   * econ_dl: the single-scale value is exactly the base price while the
#     v2.9.1 double-scale value is base x deadline (and the planner value is
#     base x deadline^2), i.e. no value is inflated more than once.
#
# Env: GODOT_BIN, GODOT_ARGS, TESTS_WORK_DIR. Prints RESULT lines; non-zero
# exit on any failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="$(git -C "$TESTS_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$TESTS_DIR/.." && pwd))"
MOD="$REPO/mod/mods-unpacked/Pasha-AutoBattler"
WORK="${TESTS_WORK_DIR:-$REPO/tests/.work}/contact"
PROJ="$WORK/proj"
LOGS="$WORK/logs"

die() { echo "contact: $*" >&2; exit 2; }

if [ -n "${GODOT_BIN:-}" ]; then
	[ -x "$GODOT_BIN" ] || die "GODOT_BIN is not executable: $GODOT_BIN"
else
	fallback="$REPO/_research/tools/Godot.app/Contents/MacOS/Godot"
	[ -x "$fallback" ] || die "GODOT_BIN not set and no dev fallback ($fallback)"
	GODOT_BIN="$fallback"
fi
# Intentional word splitting: whitespace-separated flag list.
EXTRA_ARGS="${GODOT_ARGS--no-window}"

prepare_project() {
	rm -rf "$WORK"
	mkdir -p "$PROJ/home" "$PROJ/mods-unpacked/Pasha-AutoBattler/steering" "$LOGS"
	cp "$SCRIPT_DIR/sim.gd" "$SCRIPT_DIR/econ_dl_probe.gd" "$SCRIPT_DIR/project.godot" \
		"$PROJ/" || die "could not copy contact project"
	# HEAD-era steering modules preload each other at their real res:// paths.
	cp "$MOD/steering/"*.gd "$PROJ/mods-unpacked/Pasha-AutoBattler/steering/" \
		|| die "could not copy steering tree"
	cp "$MOD/steering/arbiter.gd" "$PROJ/arbiter.gd" || die "could not copy live arbiter"
}

prepare_project

# run_arm <name> <script> [ENV=value ...]
run_arm() {
	local name="$1" script="$2"; shift 2
	local log="$LOGS/$name.log"
	if ! env HOME="$PROJ/home" "$@" "$GODOT_BIN" --path "$PROJ" $EXTRA_ARGS \
			--script "res://$script" >"$log" 2>&1; then
		echo "contact: arm '$name' exited non-zero (log: $log)" >&2
		tail -20 "$log" >&2
		exit 2
	fi
}

FIXTURES="econ_meca_body_between_100,econ_meca_body_between_150,econ_meca_stillbody_150,econ_tree_body_between_v6,econ_meca_alone,user_melee_meca_behind,user_melee_tree_behind,user_melee_fruit_behind"
SENSITIVE="econ_meca_body_between_100,user_melee_meca_behind"

echo "=== contact suite: fixed arm (shipped v2.10.0 defaults) ==="
run_arm fixed sim.gd SIM_CFG=shipped SIM_POLICIES=v26 SIM_SET="$FIXTURES"
echo "=== contact suite: v2.9.1 control arm (--arb-pullsafe=0 --arb-econdl=1) ==="
run_arm v291 sim.gd SIM_CFG=shipped SIM_POLICIES=v26 SIM_SET="$SENSITIVE" \
	SIM_OVR="pullsafe=0,econdl=1"
echo "=== contact suite: wave-end deadline unit probe ==="
run_arm econ_dl econ_dl_probe.gd

python3 "$SCRIPT_DIR/assert_contact.py" "$LOGS" "$FIXTURES" "$SENSITIVE" || exit 1
