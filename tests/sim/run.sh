#!/usr/bin/env bash
# One closed-loop simulation invocation (helper for tests/sim/matrix.sh).
#
#   GODOT_BIN=... bash tests/sim/run.sh                  # live arbiter, sim.gd
#   SIM_ARBITER_REF=e933740 SIM_ONLY=opp_s1_blocker1 \
#     SIM_POLICIES=v27,v28 bash tests/sim/run.sh
#
# The scratch project is prepared once (tests/.work/sim/proj) and reused.
# SIM_ARBITER_REF is resolved with `git show <ref>:mod/.../arbiter.gd` (never a
# manual copy); unset = live working-tree arbiter. sim.gd itself always exits 0
# (research instrument) -- the gate is tests/sim/assert_no_regression.py.
#
# Env: GODOT_BIN, GODOT_ARGS (default --no-window), TESTS_WORK_DIR,
#      SIM_ARBITER_REF, SIM_SCRIPT, SIM_ONLY, SIM_POLICIES, SIM_TRACE.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="$(git -C "$TESTS_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$TESTS_DIR/.." && pwd))"
MOD="$REPO/mod/mods-unpacked/Pasha-AutoBattler"
WORK="${TESTS_WORK_DIR:-$REPO/tests/.work}/sim"
PROJ="$WORK/proj"
ARBITER_REL="mod/mods-unpacked/Pasha-AutoBattler/steering/arbiter.gd"

die() { echo "sim: $*" >&2; exit 2; }

if [ -n "${GODOT_BIN:-}" ]; then
	[ -x "$GODOT_BIN" ] || die "GODOT_BIN is not executable: $GODOT_BIN"
else
	fallback="$REPO/_research/tools/Godot.app/Contents/MacOS/Godot"
	[ -x "$fallback" ] || die "GODOT_BIN not set and no dev fallback ($fallback)"
	GODOT_BIN="$fallback"
fi
# Intentional word splitting: GODOT_ARGS is a whitespace-separated flag list
# (string form, not an array: macOS ships bash 3.2 where empty-array expansion
# under `set -u` fails, and CI sets GODOT_ARGS="").
EXTRA_ARGS="${GODOT_ARGS--no-window}"

prepare_project() {
	rm -rf "$WORK"
	mkdir -p "$PROJ/home" "$WORK/home" "$WORK/logs" "$PROJ/mods-unpacked"
	cp "$SCRIPT_DIR/sim.gd" "$SCRIPT_DIR/probe_opportunity.gd" \
		"$SCRIPT_DIR/test_bounty.gd" "$SCRIPT_DIR/test_rollout.gd" \
		"$SCRIPT_DIR/project.godot" "$PROJ/" || die "could not copy sim project"
	cp -R "$MOD" "$PROJ/mods-unpacked/" || die "could not copy mod tree"
	cp "$MOD/steering/"*.gd "$PROJ/" || die "could not copy steering sources"
}

if [ "${1:-}" = "--prepare" ]; then
	prepare_project
	echo "sim: prepared $PROJ"
	exit 0
fi

[ -d "$PROJ" ] || prepare_project

# arbiter under test
if [ -n "${SIM_ARBITER_REF:-}" ]; then
	tmp="$PROJ/arbiter.gd.tmp.$$"
	if ! git -C "$REPO" show "$SIM_ARBITER_REF:$ARBITER_REL" >"$tmp" 2>"$tmp.err"; then
		echo "sim: git show $SIM_ARBITER_REF:$ARBITER_REL failed:" >&2
		cat "$tmp.err" >&2
		rm -f "$tmp" "$tmp.err"
		exit 2
	fi
	rm -f "$tmp.err"
	[ -s "$tmp" ] || { echo "sim: empty frozen arbiter for $SIM_ARBITER_REF" >&2; rm -f "$tmp"; exit 2; }
	mv "$tmp" "$PROJ/arbiter.gd"
else
	cp "$MOD/steering/arbiter.gd" "$PROJ/arbiter.gd" || die "could not copy live arbiter"
fi

exec env HOME="$WORK/home" "$GODOT_BIN" --path "$PROJ" $EXTRA_ARGS \
	--script "${SIM_SCRIPT:-res://sim.gd}"
