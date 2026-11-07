#!/usr/bin/env bash
# Offline GDScript parse/compile gate for every .gd file shipped in mod/.
#
#   GODOT_BIN=/path/to/godot bash tests/tools/check_gd.sh
#   GODOT_BIN=/path/to/godot bash tests/tools/check_gd.sh --selftest
#
# Why a stub SceneTree script instead of `godot --check-only --script`:
# in check-only mode Godot parses the target before the project's autoload
# singletons / global classes exist, so every Keys/RunData/Boss/... reference
# reports "identifier isn't declared". We copy the stub project + the real mod
# files into a scratch project and run runner.gd, which load()s every target and
# calls can_instance() (compile check only; nothing is instantiated or executed).
#
# The target list is generated from the working tree, so new mod scripts are
# picked up automatically (no hardcoded file list).
#
# Before the Godot parse pass, tests/tools/static_guard.py scans every shipped
# .gd for hazards that compile in the stub project but fail in the real game
# (autoload `"key" in RunData` is a PARSE error in-game; v2.9.0 regression).
#
# --selftest proves the checker is not a rubber stamp:
#   1. current sources must pass (baseline),
#   2. injecting a syntax error into EVERY target must fail at the expected line,
#   3. an undeclared singleton reference must be detected,
#   4. the static guard must catch the known in-game-only pattern.
#
# Env:
#   GODOT_BIN   Godot 3.6.x binary (required in CI / clean checkout).
#               Dev fallback: _research/tools/Godot.app/Contents/MacOS/Godot
#   GODOT_ARGS  override the extra Godot flags (default: --no-window);
#               set GODOT_ARGS="" for a headless/server build if it rejects it.
#   TESTS_WORK_DIR  scratch directory (default: <repo>/tests/.work)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="$(git -C "$TESTS_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$TESTS_DIR/.." && pwd))"
STUBS="$SCRIPT_DIR/stubs"
MOD="$REPO/mod/mods-unpacked/Pasha-AutoBattler"
WORK="${TESTS_WORK_DIR:-$REPO/tests/.work}/check_gd"

TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

die() { echo "check_gd: $*" >&2; exit 2; }

resolve_godot() {
	if [ -n "${GODOT_BIN:-}" ]; then
		[ -x "$GODOT_BIN" ] || die "GODOT_BIN is not executable: $GODOT_BIN"
		return
	fi
	local fallback="$REPO/_research/tools/Godot.app/Contents/MacOS/Godot"
	if [ -x "$fallback" ]; then
		GODOT_BIN="$fallback"
		return
	fi
	die "GODOT_BIN is not set and no dev fallback found ($fallback). Set GODOT_BIN=/path/to/godot-3.6.1"
}
resolve_godot

# Intentional word splitting: GODOT_ARGS is a whitespace-separated flag list
# (string form, not an array: macOS ships bash 3.2 where empty-array expansion
# under `set -u` fails, and CI sets GODOT_ARGS="").
EXTRA_ARGS="${GODOT_ARGS--no-window}"

[ -d "$STUBS" ] || die "missing stub project: $STUBS"
[ -d "$MOD" ] || die "missing mod sources: $MOD"

strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g'; }

# Copy the stub project + every tracked/untracked mod file into the scratch
# project, preserving the mod's res:// layout so preload("res://mods-unpacked/...")
# paths inside the extensions resolve exactly like in the game project.
prepare_work() {
	rm -rf "$WORK"
	mkdir -p "$WORK/home" "$WORK/mods-unpacked"
	cp -R "$STUBS/." "$WORK/" || die "could not copy stub project"
	cp -R "$MOD" "$WORK/mods-unpacked/" || die "could not copy mod sources"
}

# Generate res:// targets.txt from every .gd under the mod directory.
make_targets() {
	: >"$WORK/targets.txt"
	local f rel
	while IFS= read -r f; do
		rel="${f#"$MOD"/}"
		printf 'res://mods-unpacked/Pasha-AutoBattler/%s\n' "$rel" >>"$WORK/targets.txt"
	done < <(find "$MOD" -name '*.gd' -type f | sort)
	local n
	n="$(grep -c . "$WORK/targets.txt" || true)"
	[ "$n" -gt 0 ] || die "no .gd targets found under $MOD"
}

run_check() {
	local t=""
	if [ -n "$TIMEOUT_BIN" ]; then t="120"; fi
	( cd "$WORK" && HOME="$WORK/home" \
		${TIMEOUT_BIN:+$TIMEOUT_BIN "$t"} "$GODOT_BIN" --path "$WORK" $EXTRA_ARGS \
		--script res://runner.gd ) >"$WORK/check.log" 2>&1
	CHECK_EXIT=$?
}

print_log() {
	echo "--- Godot output (last 60 lines) ---"
	strip_ansi <"$WORK/check.log" | tail -60
	echo "--- end of Godot output ---"
}

target_count() { grep -c . "$WORK/targets.txt"; }
ok_count() { strip_ansi <"$WORK/check.log" | grep -ac '^CHECK_OK ' || true; }

# --- normal mode -----------------------------------------------------------
main_check() {
	# Static guards first: hazards that COMPILE in the stub project but fail in
	# the real game. v2.9.0 shipped `"nb_of_waves" in RunData` -- the stub parse
	# gate passed, the real mod-loader compile failed at parse time, world_view
	# never loaded and the autopilot never moved. See static_guard.py.
	if ! python3 "$SCRIPT_DIR/static_guard.py" "$MOD"; then
		echo "STATIC GUARD FAILED" >&2
		echo "RESULT check_gd targets=0 loaded=0 failed=1 FAIL" >&2
		exit 1
	fi
	prepare_work
	make_targets
	run_check
	local total ok
	total="$(target_count)"
	ok="$(ok_count)"
	local engine
	engine="$(strip_ansi <"$WORK/check.log" | grep -a 'Godot Engine v' | head -1 | sed 's/.*Godot Engine/Godot Engine/')"
	echo "=== offline parse gate: ${total} GDScript files (${engine:-Godot unknown}) ==="
	strip_ansi <"$WORK/check.log" | grep -aE '^CHECK_(OK|FAIL) ' || true
	echo "targets=${total} loaded=${ok}"
	if [ "$CHECK_EXIT" -eq 0 ] && [ "$ok" -eq "$total" ]; then
		echo "RESULT check_gd targets=${total} loaded=${ok} failed=0 PASS"
		exit 0
	fi
	print_log
	echo "RESULT check_gd targets=${total} loaded=${ok} failed=$((total - ok)) FAIL" >&2
	exit 1
}

# --- self test -------------------------------------------------------------
selftest() {
	local fails=0 checks=0

	echo "== selftest 1/4: current sources parse (expect PASS) =="
	prepare_work
	make_targets
	run_check
	local total ok
	total="$(target_count)"
	ok="$(ok_count)"
	if [ "$CHECK_EXIT" -eq 0 ] && [ "$ok" -eq "$total" ] && grep -aq '^CHECK_TOTAL ' "$WORK/check.log"; then
		echo "PASS baseline (${total} targets)"
	else
		echo "FAIL baseline: exit=$CHECK_EXIT loaded=$ok/$total"
		print_log
		fails=$((fails + 1))
	fi
	checks=$((checks + 1))

	echo "== selftest 2/4: inject a syntax error into every target (expect FAIL + line) =="
	local target i=0
	while IFS= read -r target; do
		i=$((i + 1))
		prepare_work
		make_targets
		local rel="${target#res://}"
		local file="$WORK/$rel"
		local expected_line
		expected_line="$(grep -an '^extends ' "$file" | head -1 | cut -d: -f1)"
		if [ -z "$expected_line" ]; then
			echo "SKIP $target (no top-level 'extends' line)"
			checks=$((checks + 1))
			continue
		fi
		expected_line=$((expected_line + 1))
		awk -v want="$expected_line" -v bad='!!!injected_selftest_syntax!!!' \
			'{ print } NR == want - 1 { print bad }' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
		run_check
		local reported_line
		reported_line="$(strip_ansi <"$WORK/check.log" \
			| grep -aEo "$target:[0-9]+" | head -1 | sed -E 's/.*:([0-9]+)$/\1/')"
		if [ "$CHECK_EXIT" -ne 0 ] \
			&& grep -aq "^CHECK_FAIL $target$" "$WORK/check.log" \
			&& [ "$reported_line" = "$expected_line" ]; then
			echo "PASS $target: exit=$CHECK_EXIT, error reported at line $reported_line (expected $expected_line)"
		else
			echo "FAIL $target: exit=$CHECK_EXIT, reported line '${reported_line:-none}' (expected $expected_line)"
			print_log
			fails=$((fails + 1))
		fi
		checks=$((checks + 1))
	done < <(grep . "$WORK/targets.txt" 2>/dev/null || true)

	# targets.txt may not exist if the baseline block failed early; regenerate.
	[ -s "$WORK/targets.txt" ] || { prepare_work; make_targets; }
	local first_target first_rel
	first_target="$(head -1 "$WORK/targets.txt")"
	first_rel="${first_target#res://}"

	echo "== selftest 3/4: undeclared singleton in a copy (expect FAIL + identifier) =="
	prepare_work
	make_targets
	printf '\nvar __selftest_unknown = NoSuchService_xyz.value\n' >>"$WORK/$first_rel"
	run_check
	if [ "$CHECK_EXIT" -ne 0 ] \
		&& strip_ansi <"$WORK/check.log" | grep -aq "NoSuchService_xyz"; then
		echo "PASS undeclared singleton detected ($first_target)"
	else
		echo "FAIL undeclared singleton not detected: exit=$CHECK_EXIT"
		print_log
		fails=$((fails + 1))
	fi
	checks=$((checks + 1))

	echo "== selftest 4/4: static guard catches autoload \`in\` (expect PASS) =="
	if python3 "$SCRIPT_DIR/static_guard.py" --selftest; then
		echo "PASS static guard selftest"
	else
		echo "FAIL static guard selftest"
		fails=$((fails + 1))
	fi
	checks=$((checks + 1))

	echo
	if [ "$fails" -eq 0 ]; then
		echo "SELFTEST PASSED"
		echo "RESULT check_gd_selftest checks=${checks} fails=0 PASS"
		return 0
	fi
	echo "SELFTEST FAILED ($fails failure(s))"
	echo "RESULT check_gd_selftest checks=${checks} fails=${fails} FAIL"
	return 1
}

# --- entry -----------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
	selftest
	exit $?
fi
main_check
