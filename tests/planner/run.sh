#!/usr/bin/env bash
# Synthetic arbiter selftest + independent falsifier (v2.8.0 acceptance).
#
#   GODOT_BIN=/path/to/godot bash tests/planner/run.sh
#
# What it does:
#   1. builds a scratch Godot project from tests/planner/proj + the live mod tree;
#   2. generates EVERY frozen reference from git history with `git show <pin>`
#      (never HEAD, never a manual copy):
#        arbiter_old.gd  <- 0ac6ab5 (pre-v2.3 behaviour; control arm #1)
#        arbiter_v261.gd <- dcb6e39 (v2.6.1; v2.7 opportunity control arm)
#        arbiter_v27.gd  <- e933740 (v2.7.0; v2.8 coverage control arm)
#   3. runs proj/test.gd           -> must print RESULT checks=470 fails=0 PASS
#   4. runs proj/falsify_v270.gd   -> must print RESULT falsify checks=2476 fails=0 PASS
#
# Success = Godot exit 0 AND fails==0 AND the exact check count (so a silently
# skipped/disabled suite cannot pass). Reverse validation: set
# REF_V27_COMMIT=HEAD (or any non-v2.7 commit) and this script must fail.
#
# Env: GODOT_BIN (required unless dev fallback), GODOT_ARGS (default --no-window),
#      TESTS_WORK_DIR, REF_OLD_COMMIT / REF_V261_COMMIT / REF_V27_COMMIT.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="$(git -C "$TESTS_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$TESTS_DIR/.." && pwd))"
MOD="$REPO/mod/mods-unpacked/Pasha-AutoBattler"
WORK="${TESTS_WORK_DIR:-$REPO/tests/.work}/planner"
PROJ="$WORK/proj"
STEERING_REL="mod/mods-unpacked/Pasha-AutoBattler/steering/arbiter.gd"

REF_OLD_COMMIT="${REF_OLD_COMMIT:-0ac6ab5}"
REF_V261_COMMIT="${REF_V261_COMMIT:-dcb6e39}"
REF_V27_COMMIT="${REF_V27_COMMIT:-e933740}"
EXPECT_PLANNER_CHECKS=470
EXPECT_FALSIFIER_CHECKS=2476

TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

die() { echo "planner: $*" >&2; exit 2; }
strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g'; }

# --- resolve Godot ---------------------------------------------------------
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

run_godot() {
	local script="$1" log="$2" t=""
	if [ -n "$TIMEOUT_BIN" ]; then t="180"; fi
	( cd "$PROJ" && HOME="$WORK/home" \
		${TIMEOUT_BIN:+$TIMEOUT_BIN "$t"} "$GODOT_BIN" --path "$PROJ" $EXTRA_ARGS \
		--script "$script" ) >"$log" 2>&1
	return $?
}

fail_with_log() {
	local log="$1"
	echo "--- last 40 lines of $log ---"
	strip_ansi <"$log" | tail -40
	echo "--- end ---"
	exit 1
}

# --- build scratch project -------------------------------------------------
[ -f "$SCRIPT_DIR/proj/test.gd" ] || die "missing tests/planner/proj/test.gd"
[ -d "$MOD" ] || die "missing mod sources: $MOD"

rm -rf "$WORK"
mkdir -p "$PROJ/home" "$WORK/home" "$PROJ/mods-unpacked"
cp "$SCRIPT_DIR/proj/project.godot" "$SCRIPT_DIR/proj/test.gd" \
	"$SCRIPT_DIR/proj/falsify_v270.gd" "$PROJ/" || die "could not copy planner project"
cp -R "$MOD" "$PROJ/mods-unpacked/" || die "could not copy mod tree"

# Live script under test (working tree) + the full mod tree for any
# preload("res://mods-unpacked/...") a future steering split may introduce.
cp "$MOD/steering/"*.gd "$PROJ/" || die "could not copy steering sources"

freeze_ref() {
	local commit="$1" out="$2" label="$3" tmp
	tmp="$out.tmp.$$"
	if ! git -C "$REPO" show "$commit:$STEERING_REL" >"$tmp" 2>"$tmp.err"; then
		echo "planner: git show $commit:$STEERING_REL failed (is the full git history present?):" >&2
		cat "$tmp.err" >&2
		rm -f "$tmp" "$tmp.err"
		return 1
	fi
	rm -f "$tmp.err"
	[ -s "$tmp" ] || { echo "planner: frozen reference is empty ($commit)" >&2; rm -f "$tmp"; return 1; }
	mv "$tmp" "$out" || return 1
	echo "planner: frozen $label arbiter <- $commit:$STEERING_REL ($(wc -l <"$out" | tr -d ' ') lines)"
}
freeze_ref "$REF_OLD_COMMIT" "$PROJ/arbiter_old.gd" "pre-v2.3" || exit 2
freeze_ref "$REF_V261_COMMIT" "$PROJ/arbiter_v261.gd" "v2.6.1" || exit 2
freeze_ref "$REF_V27_COMMIT" "$PROJ/arbiter_v27.gd" "v2.7.0" || exit 2

# --- run planner selftest --------------------------------------------------
echo "=== planner-selftest (live arbiter + frozen refs from git) ==="
LOG="$WORK/planner.log"
run_godot "res://test.gd" "$LOG"
PLANNER_EXIT=$?
line="$(strip_ansi <"$LOG" | grep -aoE 'RESULT checks=[0-9]+ fails=[0-9]+ (PASS|FAIL)' | tail -1)"
if [ "$PLANNER_EXIT" -ne 0 ] || [ -z "$line" ]; then
	echo "FAIL planner: exit=$PLANNER_EXIT, RESULT line: '${line:-<missing>}'"
	grep -aE '^FAIL ' "$LOG" | head -20 || true
	fail_with_log "$LOG"
fi
checks="$(sed -E 's/.*checks=([0-9]+).*/\1/' <<<"$line")"
fails="$(sed -E 's/.*fails=([0-9]+).*/\1/' <<<"$line")"
verdict="$(sed -E 's/.*(PASS|FAIL)$/\1/' <<<"$line")"
if [ "$verdict" != "PASS" ] || [ "$fails" != "0" ] || [ "$checks" != "$EXPECT_PLANNER_CHECKS" ]; then
	echo "FAIL planner: RESULT '$line' (expected checks=$EXPECT_PLANNER_CHECKS fails=0 PASS)"
	grep -aE '^FAIL ' "$LOG" | head -20 || true
	fail_with_log "$LOG"
fi
echo "RESULT planner checks=${checks} fails=0 PASS"

# --- run independent falsifier --------------------------------------------
echo "=== independent falsifier (seeded fuzz vs frozen refs) ==="
FLOG="$WORK/falsify.log"
run_godot "res://falsify_v270.gd" "$FLOG"
FALSIFY_EXIT=$?
fline="$(strip_ansi <"$FLOG" | grep -aoE 'RESULT falsify checks=[0-9]+ fails=[0-9]+ (PASS|FAIL)' | tail -1)"
if [ "$FALSIFY_EXIT" -ne 0 ] || [ -z "$fline" ]; then
	echo "FAIL falsifier: exit=$FALSIFY_EXIT, RESULT line: '${fline:-<missing>}'"
	grep -aE '^FAIL ' "$FLOG" | head -20 || true
	fail_with_log "$FLOG"
fi
fchecks="$(sed -E 's/.*checks=([0-9]+).*/\1/' <<<"$fline")"
ffails="$(sed -E 's/.*fails=([0-9]+).*/\1/' <<<"$fline")"
fverdict="$(sed -E 's/.*(PASS|FAIL)$/\1/' <<<"$fline")"
if [ "$fverdict" != "PASS" ] || [ "$ffails" != "0" ] || [ "$fchecks" != "$EXPECT_FALSIFIER_CHECKS" ]; then
	echo "FAIL falsifier: RESULT '$fline' (expected checks=$EXPECT_FALSIFIER_CHECKS fails=0 PASS)"
	grep -aE '^FAIL ' "$FLOG" | head -20 || true
	fail_with_log "$FLOG"
fi
echo "RESULT falsifier checks=${fchecks} fails=0 PASS"
exit 0
