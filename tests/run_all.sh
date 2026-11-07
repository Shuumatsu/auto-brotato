#!/usr/bin/env bash
# One entry point for the repository's offline verification suites.
#
#   GODOT_BIN=/path/to/godot-3.6.1 bash tests/run_all.sh
#
# Runs, in order:
#   1. check_gd              every mod .gd file parses/compiles (stub project)
#   2. check_gd --selftest   proves the parse gate actually catches bad scripts
#   3. planner               arbiter synthetic selftest (470 checks) + falsifier
#                            (2476 checks) against frozen refs from git
#   4. gate                  closed-loop acceptance gate (32 checks)
#   5. worldview             world_view probe vs pinned v2.7.0 (32 checks)
#   6. contact               round-7 sparse-scene contact suite (fixed vs v2.9.1)
#   7. sim                   closed-loop no-regression matrix + assertions
#   8. econ                  tests/econ/run.sh if present (closed-loop economic sim)
#
# Every suite must print at least one `RESULT ... PASS` line, exit 0, and (where
# the suite declares expected counts in its own run.sh) match those counts.
# Any failure makes this script exit non-zero.
#
# Nothing here touches the game, Steam, `_research/`, or `dist/`. Requirements:
# a Godot 3.6.x binary (GODOT_BIN; dev fallback to _research/tools on a local
# checkout) and full git history (frozen references are produced by `git show`).
#
# Env: GODOT_BIN, GODOT_ARGS (default --no-window; set "" for headless builds
#      that reject it), TESTS_WORK_DIR (default tests/.work), RUN_SUITES
#      (space-separated subset, e.g. RUN_SUITES="check_gd planner").

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/.." && pwd))"
WORK="${TESTS_WORK_DIR:-$REPO/tests/.work}"
LOGDIR="$WORK/logs"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

mkdir -p "$LOGDIR"

strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g'; }

# --- resolve Godot ---------------------------------------------------------
if [ -n "${GODOT_BIN:-}" ]; then
	[ -x "$GODOT_BIN" ] || { echo "run_all: GODOT_BIN is not executable: $GODOT_BIN" >&2; exit 2; }
else
	fallback="$REPO/_research/tools/Godot.app/Contents/MacOS/Godot"
	if [ -x "$fallback" ]; then
		GODOT_BIN="$fallback"
	else
		echo "run_all: GODOT_BIN is not set and no dev fallback found ($fallback)." >&2
		echo "         e.g. GODOT_BIN=/path/to/Godot_v3.6.1-stable_linux_headless.64 bash tests/run_all.sh" >&2
		exit 2
	fi
fi
export GODOT_BIN

if ! git -C "$REPO" rev-parse --verify -q HEAD >/dev/null 2>&1; then
	echo "run_all: not a git checkout; the frozen references need git history" >&2
	exit 2
fi

SELECTED="${RUN_SUITES:-}"

should_run() {
	[ -z "$SELECTED" ] && return 0
	case " $SELECTED " in *" $1 "*) return 0 ;; esac
	return 1
}

ROWS="$WORK/summary.tsv"
: >"$ROWS"
overall=0

# run_suite <name> <timeout-seconds> <command...>
run_suite() {
	local name="$1" tmo="$2"
	shift 2
	local log="$LOGDIR/$name.log"
	local start end elapsed rc
	start=$(date +%s)
	if [ -n "$TIMEOUT_BIN" ]; then
		timeout "$tmo" "$@" >"$log" 2>&1
		rc=$?
	else
		"$@" >"$log" 2>&1
		rc=$?
	fi
	end=$(date +%s)
	elapsed=$((end - start))

	local results
	results="$(strip_ansi <"$log" | grep -aoE '^RESULT .*(PASS|FAIL)$' | paste -sd ';' -)"
	local suite_ok=1
	[ "$rc" -eq 0 ] || suite_ok=0
	[ -n "$results" ] || suite_ok=0
	if [ "$suite_ok" -eq 1 ]; then
		case "$results" in *FAIL*) suite_ok=0 ;; esac
	fi
	if [ "$suite_ok" -eq 0 ]; then
		overall=1
		printf 'FAIL %-20s exit=%-3s %3ss  %s\n' "$name" "$rc" "$elapsed" "${results:-<no RESULT line>}"
		echo "--- last 30 log lines ($log) ---"
		strip_ansi <"$log" | tail -30
		echo "---"
	else
		printf 'PASS %-20s exit=%-3s %3ss  %s\n' "$name" "$rc" "$elapsed" "$results"
	fi
	printf '%s\t%s\t%s\t%s\n' "$name" "$rc" "${elapsed}s" "${results:-<no RESULT>}" >>"$ROWS"
}

echo "=================================================================="
echo " AutoBattler offline verification"
echo " repo:   $REPO"
echo " commit: $(git -C "$REPO" rev-parse --short HEAD)"
echo " godot:  $("$GODOT_BIN" --version 2>&1 | tail -1)"
echo "================================================================================"

should_run check_gd && run_suite check_gd 240 bash "$SCRIPT_DIR/tools/check_gd.sh"
should_run check_gd_selftest && run_suite check_gd_selftest 360 bash "$SCRIPT_DIR/tools/check_gd.sh" --selftest
should_run planner && run_suite planner 420 bash "$SCRIPT_DIR/planner/run.sh"
should_run gate && run_suite gate 480 bash "$SCRIPT_DIR/gate/run.sh"
should_run worldview && run_suite worldview 300 bash "$SCRIPT_DIR/worldview/run.sh"
should_run contact && run_suite contact 420 bash "$SCRIPT_DIR/contact/run.sh"
should_run sim && run_suite sim 1200 bash "$SCRIPT_DIR/sim/matrix.sh"
if [ -f "$SCRIPT_DIR/econ/run.sh" ]; then
	should_run econ && run_suite econ 1200 bash "$SCRIPT_DIR/econ/run.sh"
fi

echo "=================================================================================="
printf '%-20s %-6s %-6s %s\n' "suite" "exit" "time" "result lines"
awk -F'\t' '{printf "%-20s %-6s %-6s %s\n", $1, $2, $3, $4}' "$ROWS"
echo "=================================================================================="
echo "logs: $LOGDIR"
if [ "$overall" -eq 0 ]; then
	echo "ALL SUITES PASSED"
	exit 0
fi
echo "SUITE FAILURES: see logs above"
exit 1
