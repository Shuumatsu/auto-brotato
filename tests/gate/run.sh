#!/usr/bin/env bash
# Closed-loop acceptance gate (v2.5-v2.8 planning/coverage work).
#
#   GODOT_BIN=/path/to/godot bash tests/gate/run.sh
#
# Builds a scratch Godot project from tests/gate + the live mod tree, freezes the
# v2.4.0 arbiter from git (`git show 751f3c3`, NOT HEAD) as the control-arm
# reference, then runs gate.gd. Success = Godot exit 0 AND
# `RESULT checks=32 fails=0 PASS` (exit code of gate.gd is the number of fails).
#
# Reverse validation: GATE_REF=HEAD makes scenario C compare the live control arm
# against v2.8 defaults, so the gate must fail.
#
# Env: GODOT_BIN (required unless dev fallback), GODOT_ARGS (default --no-window),
#      TESTS_WORK_DIR, GATE_REF (default 751f3c3 = v2.4.0).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="$(git -C "$TESTS_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$TESTS_DIR/.." && pwd))"
MOD="$REPO/mod/mods-unpacked/Pasha-AutoBattler"
WORK="${TESTS_WORK_DIR:-$REPO/tests/.work}/gate"
PROJ="$WORK/proj"
GATE_REF="${GATE_REF:-751f3c3}"
STEERING_REL="mod/mods-unpacked/Pasha-AutoBattler/steering/arbiter.gd"
EXPECT_CHECKS=32

TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

die() { echo "gate: $*" >&2; exit 2; }
strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g'; }
sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

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

[ -f "$SCRIPT_DIR/gate.gd" ] || die "missing tests/gate/gate.gd"
[ -d "$MOD" ] || die "missing mod sources: $MOD"

rm -rf "$WORK"
mkdir -p "$PROJ/home" "$WORK/home" "$PROJ/mods-unpacked"
cp "$SCRIPT_DIR/gate.gd" "$SCRIPT_DIR/project.godot" "$PROJ/" || die "could not copy gate project"
cp -R "$MOD" "$PROJ/mods-unpacked/" || die "could not copy mod tree"
cp "$MOD/steering/"*.gd "$PROJ/" || die "could not copy steering sources"

# Frozen v2.4.0 control-arm reference, reproducible from git history.
tmp="$PROJ/arbiter_v240.gd.tmp.$$"
if ! git -C "$REPO" show "$GATE_REF:$STEERING_REL" >"$tmp" 2>"$tmp.err"; then
	echo "gate: git show $GATE_REF:$STEERING_REL failed (is the full git history present?):" >&2
	cat "$tmp.err" >&2
	rm -f "$tmp" "$tmp.err"
	exit 2
fi
rm -f "$tmp.err"
[ -s "$tmp" ] || { echo "gate: frozen reference is empty ($GATE_REF)" >&2; rm -f "$tmp"; exit 2; }
mv "$tmp" "$PROJ/arbiter_v240.gd"
echo "gate: live arbiter sha256=$(sha256_file "$PROJ/arbiter.gd")"
echo "gate: frozen v2.4.0 arbiter <- $GATE_REF ($(wc -l <"$PROJ/arbiter_v240.gd" | tr -d ' ') lines)"

echo "=== closed-loop gate (live arbiter vs frozen v2.4.0 control arm) ==="
LOG="$WORK/gate.log"
t=""
if [ -n "$TIMEOUT_BIN" ]; then t="300"; fi
( cd "$PROJ" && HOME="$WORK/home" \
	${TIMEOUT_BIN:+$TIMEOUT_BIN "$t"} "$GODOT_BIN" --path "$PROJ" $EXTRA_ARGS \
	--script res://gate.gd ) >"$LOG" 2>&1
GATE_EXIT=$?

line="$(strip_ansi <"$LOG" | grep -aoE 'RESULT checks=[0-9]+ fails=[0-9]+ (PASS|FAIL)' | tail -1)"
echo "gate: exit=$GATE_EXIT ${line:-<no RESULT line>}"
if [ -z "$line" ]; then
	echo "FAIL gate: gate.gd produced no RESULT line"
	strip_ansi <"$LOG" | tail -40
	exit 1
fi
checks="$(sed -E 's/.*checks=([0-9]+).*/\1/' <<<"$line")"
fails="$(sed -E 's/.*fails=([0-9]+).*/\1/' <<<"$line")"
verdict="$(sed -E 's/.*(PASS|FAIL)$/\1/' <<<"$line")"
if [ "$GATE_EXIT" -ne 0 ] || [ "$verdict" != "PASS" ] || [ "$fails" != "0" ] || [ "$checks" != "$EXPECT_CHECKS" ]; then
	echo "FAIL gate: '$line' (exit=$GATE_EXIT, expected checks=$EXPECT_CHECKS fails=0 PASS)"
	grep -aE '^FAIL ' <(strip_ansi <"$LOG") | head -20 || true
	echo "--- last 40 lines ---"
	strip_ansi <"$LOG" | tail -40
	exit 1
fi
echo "RESULT gate checks=${checks} fails=0 PASS"
exit 0
