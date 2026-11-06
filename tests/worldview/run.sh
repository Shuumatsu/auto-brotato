#!/usr/bin/env bash
# World-view probe: v2.8 coverage values/tags, fire_wait_frames, dpsref, and
# exactness against a PINNED v2.7.0 reference (not HEAD).
#
#   GODOT_BIN=/path/to/godot bash tests/worldview/run.sh
#
# Builds a scratch Godot project from tests/worldview/proj + the live mod tree,
# then:
#   * copies the working-tree world_view.gd        -> res://live_world_view.gd
#   * generates the v2.7.0 world_view from git     -> res://ref_v270_world_view.gd
#                              (`git show e933740:.../world_view.gd`, never HEAD)
# and runs v28probe.gd. The exactness probes compare live vs ref with the SAME
# override set ({"cov":0,"tapcd":0} / {"opp":0}); v2.7 ignores the v2.8-only keys.
#
# Success = Godot exit 0 AND `RESULT checks=32 fails=0 PASS`.
# Reverse validation: REF_WORLDVIEW_COMMIT=HEAD must make this script fail.
#
# Env: GODOT_BIN (required unless dev fallback), GODOT_ARGS (default --no-window),
#      TESTS_WORK_DIR, REF_WORLDVIEW_COMMIT (default e933740 = v2.7.0).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="$(git -C "$TESTS_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$TESTS_DIR/.." && pwd))"
MOD="$REPO/mod/mods-unpacked/Pasha-AutoBattler"
WORK="${TESTS_WORK_DIR:-$REPO/tests/.work}/worldview"
PROJ="$WORK/proj"
REF_WORLDVIEW_COMMIT="${REF_WORLDVIEW_COMMIT:-e933740}"
WORLDVIEW_REL="mod/mods-unpacked/Pasha-AutoBattler/steering/world_view.gd"
EXPECT_CHECKS=32

TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

die() { echo "worldview: $*" >&2; exit 2; }
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

[ -f "$SCRIPT_DIR/proj/v28probe.gd" ] || die "missing tests/worldview/proj/v28probe.gd"
[ -d "$MOD" ] || die "missing mod sources: $MOD"

rm -rf "$WORK"
mkdir -p "$PROJ/home" "$WORK/home" "$PROJ/mods-unpacked"
cp -R "$SCRIPT_DIR/proj/." "$PROJ/" || die "could not copy worldview project"
cp -R "$MOD" "$PROJ/mods-unpacked/" || die "could not copy mod tree"
# Full mod tree copy already contains steering/*.gd under the res:// path the
# extensions preload; root copies keep res://arbiter.gd / res://world_view.gd
# loadable if the steering split adds sibling preloads.
cp "$MOD/steering/"*.gd "$PROJ/" || die "could not copy steering sources"
cp "$MOD/steering/world_view.gd" "$PROJ/live_world_view.gd" || die "could not copy live world_view"

tmp="$PROJ/ref_v270_world_view.gd.tmp.$$"
if ! git -C "$REPO" show "$REF_WORLDVIEW_COMMIT:$WORLDVIEW_REL" >"$tmp" 2>"$tmp.err"; then
	echo "worldview: git show $REF_WORLDVIEW_COMMIT:$WORLDVIEW_REL failed (is the full git history present?):" >&2
	cat "$tmp.err" >&2
	rm -f "$tmp" "$tmp.err"
	exit 2
fi
rm -f "$tmp.err"
[ -s "$tmp" ] || { echo "worldview: frozen reference is empty ($REF_WORLDVIEW_COMMIT)" >&2; rm -f "$tmp"; exit 2; }
mv "$tmp" "$PROJ/ref_v270_world_view.gd"
echo "worldview: live sha256=$(sha256_file "$PROJ/live_world_view.gd")"
echo "worldview: frozen v2.7.0 world_view <- $REF_WORLDVIEW_COMMIT ($(wc -l <"$PROJ/ref_v270_world_view.gd" | tr -d ' ') lines)"

echo "=== world_view probe (live v2.8 vs pinned v2.7.0 reference) ==="
LOG="$WORK/probe.log"
t=""
if [ -n "$TIMEOUT_BIN" ]; then t="180"; fi
( cd "$PROJ" && HOME="$WORK/home" \
	${TIMEOUT_BIN:+$TIMEOUT_BIN "$t"} "$GODOT_BIN" --path "$PROJ" $EXTRA_ARGS \
	--script res://v28probe.gd ) >"$LOG" 2>&1
PROBE_EXIT=$?

line="$(strip_ansi <"$LOG" | grep -aoE 'RESULT checks=[0-9]+ fails=[0-9]+ (PASS|FAIL)' | tail -1)"
echo "worldview: exit=$PROBE_EXIT ${line:-<no RESULT line>}"
if [ -z "$line" ]; then
	echo "FAIL worldview: probe produced no RESULT line"
	strip_ansi <"$LOG" | tail -40
	exit 1
fi
checks="$(sed -E 's/.*checks=([0-9]+).*/\1/' <<<"$line")"
fails="$(sed -E 's/.*fails=([0-9]+).*/\1/' <<<"$line")"
verdict="$(sed -E 's/.*(PASS|FAIL)$/\1/' <<<"$line")"
if [ "$PROBE_EXIT" -ne 0 ] || [ "$verdict" != "PASS" ] || [ "$fails" != "0" ] || [ "$checks" != "$EXPECT_CHECKS" ]; then
	echo "FAIL worldview: '$line' (exit=$PROBE_EXIT, expected checks=$EXPECT_CHECKS fails=0 PASS)"
	grep -aE '^FAIL ' <(strip_ansi <"$LOG") | head -20 || true
	echo "--- last 40 lines ---"
	strip_ansi <"$LOG" | tail -40
	exit 1
fi
echo "RESULT worldview checks=${checks} fails=0 PASS"
exit 0
