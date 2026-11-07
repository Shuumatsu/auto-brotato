extends SceneTree

# =============================================================================
# planning acceptance gate (v2.5 A-D, v2.6/v2.7 E/F, v2.8 G)
# =============================================================================
# Closed-loop synthetic acceptance gate for the planning/opportunity layers:
#   breakout  (--arb-breakout, default 1)  pre-emptive ring break-out
#   goal      (--arb-goal,     default 1)  committed high-value item goal
#   pursuit   (--arb-pursuit,  default 1)  pursuit forecast in the 2nd ply
#   walk      (--arb-walk,     default 1)  walk-on one-shot reward semantics
#   opp/agg   (v2.7 --arb-opp/--arb-agg)   unified opportunity planner
#   cov/tapcd (v2.8 --arb-cov/--arb-tapcd) high-value produce coverage values &
#                                          live-cooldown tap (tapcd is
#                                          world_view-only, so the gate arms
#                                          only pass it through harmlessly)
#
# The bot under test is the REAL mod script: run.sh copies the live
# mod/mods-unpacked/Pasha-AutoBattler/steering/arbiter.gd into this project
# before every run (never inline/scoring-copy it). The world around it is a
# deterministic toy: contact pursuers (and, in one scenario, straight bullets)
# on a walled rectangle, fixed 60 Hz, contact/bullet damage exactly as the mod
# prices them (see world_view's threat tuples). The reference for the control
# arm is the frozen git-HEAD v2.4.0 script (run.sh `git show HEAD:...`).
#
# Scenarios and pass criteria (thresholds leave margin, see README.md):
#   A. enclosure
#      A1 ring20_walls   : 1200x900 arena, 20 pursuers r14/speed280/dmg6,
#                          player speed 320.
#                          control (breakout=0): dead <=10 s OR surrounded>1 s
#                          default             : alive 30 s AND surrounded<1 s
#      A2 ring_shooters  : 1600x1200, 9 pursuers speed 250 dmg 6, every 3rd
#                          ranged (1.6 s cadence, 4 dmg bullets, speed 300).
#                          default             : alive 30 s AND surrounded<1 s
#                          control is reported for comparison (the "control
#                          must fail" criterion is enforced on A1, the
#                          scenario where the 2.4.0 control demonstrably
#                          breaks; see README "A2" note).
#   B. item goal
#      B1: open field + 1 slow pursuer (190) + one value-9 walk-on evolution
#          item (rim 45) 520 px away, simulated end-of-wave urgency.
#                          default: ALIVE and picks it within 20 s
#                          control: must NOT solve it (else no discrimination)
#      B2: open field, ZERO threats, value-9 walk-on item 650 px away (the
#          purest "plan a detour for a high-value item" case).
#                          default: picks it within 20 s (~2 s expected)
#                          control: v2.4 held-rim parking -- walks to the
#                                   45 px rim, nearest >pickup, 0 pickups
#   C. control-arm equivalence: with all four v2.5 switches at 0, the 30 s
#      per-frame direction sequence must be identical to the frozen v2.4.0
#      reference on 3 scenarios (open ring, shooters, held item). This proves
#      "off == old behaviour" for the whole closed loop, not just one call.
#   D. performance: choose() average us in A1/A2, default vs control; target
#      <=2.5x. Recorded, NOT a hard fail (print only).
#   E. v2.6/v2.7 one-frame probes (behavioural, telemetry only):
#      E1  far special target (850 px): default bounty/opportunity heading is
#          aligned with it; the all-zero control arm does not approach.
#      E2  (v2.7 semantics) the opp=0 fallback arm keeps the v2.6.1 binary safe
#          gate: a 120 px near body still vetoes bounty acquisition.
#      E2b a PURSUING body dead on the route to a class-1 special prices the
#          crossing as too much expected damage: default and agg=0 must not
#          commit (route-risk veto; the tuple carries world_view's per-speed
#          contact T_TICKS = 6.4, not the closed-loop flat 1.6 simplification).
#      E2c a STATIC body 120 px to the SIDE of the same route is an acceptable
#          detour for agg=1 (its closest approach is outside the risk taper, so
#          route risk is 0 while the old 300 px binary bubble still vetoes):
#          default must arm the special, the opp=0 legacy arm must still veto.
#      E3  near-wall crowd arms the CORNER breakout; control must not.
#   F. v2.7 unified opportunity planner, closed loop:
#      F1  one STATIC body 250 px dead ahead + class-1 special 800 px
#          (weapon_range 260, 20 s). A static body is world_view's 1.6-tick
#          brush, so route risk is 9.6; the class-1 value is 30 in v2.7.0
#          (agg=1 budget 11, agg=0 budget 3) and 50 under v2.8 cov=1 (17 / 5),
#          so default must enter the firing-range edge (target_min <=
#          desired+40 = 274 px) within 20 s while agg=0 and control keep away.
#      F2  5 pursuers 200 px around the start + class-1 special 700 px (25 s):
#          default survival/HP must not regress vs control (alive equal AND
#          hp_min >= control hp_min - 10). The "did it dive into the pack"
#          numbers (nearest_min/contact/surrounded/opp_s) are printed only.
#   G. v2.8 high-value produce coverage (closed loop):
#      G1  legendary item crate (raw r[1]=5, v2.8 reward tag r[6]=2 -> table
#          value 34) 530 px out behind one STATIC body 250 px on the route.
#          default (opp=1 cov=1) must upgrade the value, commit and pick within
#          20 s; legacy27 (opp=1 cov=0 = exact v2.7.0) and control must NOT
#          detour/pick; a no-tag variant under the default arbiter is the
#          raw-value-5 comparison and must also not detour.
#
# Exit code = number of hard FAILs (0 = gate passed), like planner-selftest.
# Env:
#   GATE_ARBITER=res://arbiter_v240.gd   run the v2.4 baseline (A/B must fail)
#   GATE_REFERENCE=res://other.gd        override the C reference script
#   GATE_ONLY=A,B,C                      run a subset (E/F/G always run, like D)
# =============================================================================

const DT = 1.0 / 60.0
const INF_TIME = 1e9

# -- toy world constants (see README.md "world model") --
const BODY_R = 18.0              # player body radius given to the arbiter
const BODY_STOP_PAD = 20.0       # a body walks until distance == radius + this
const CONTACT_SLACK = 2.0        # ...and this (px) counts as touching
const CONTACT_CD = 0.7           # s between two contact hits (world_view model)
const CONTACT_TICKS = 1.6        # T_TICKS passed for contact bodies
const PROJ_TICKS = 1.0           # T_TICKS passed for bullets
const PROJ_END = 3.0             # T_END passed for bullets
const PICKUP_R = 30.0            # physical walk-on pickup radius in the sim
const SURROUND_R = 260.0         # px: a body this near counts for "surrounded"
const SURROUND_SECTORS = 6       # occupied 8-sectors that mean "surrounded"
const RANGED_FIRE_R = 480.0      # px: melee-shooter opens fire inside this
const RANGED_CD = 1.6            # s between shots
const RANGED_BULLET_SPEED = 300.0
const RANGED_BULLET_DMG = 4.0
const ENEMY_THREAT_R = 900.0     # px: world_view's threat gather radius
const WAVEEND_MARGIN = 1.5       # world_view v2.5 wave-end urgency constants
const WAVEEND_BOOST = 3.0
const WAVEEND_CAP = 4.0

const KIND_PROJ = 0
const KIND_CONTACT = 1

# -- state ---------------------------------------------------------------
var fails = 0
var checks = 0
var _rows = []
var _arb_path = "res://arbiter.gd"
var _ref_path = "res://arbiter_v240.gd"


func _init():
	_arb_path = OS.get_environment("GATE_ARBITER")
	if _arb_path == "":
		_arb_path = "res://arbiter.gd"
	_ref_path = OS.get_environment("GATE_REFERENCE")
	if _ref_path == "":
		_ref_path = "res://arbiter_v240.gd"

	print("=== v2.5 planning gate ===")
	print("arbiter under test: " + _arb_path)
	print("C reference:        " + _ref_path)
	if load(_arb_path) == null:
		print("FAIL cannot load arbiter under test: " + _arb_path)
		fails += 1
		quit(fails)
		return
	print_switch_defaults()

	var only = OS.get_environment("GATE_ONLY")
	var do_a = only == "" or only.find("A") >= 0
	var do_b = only == "" or only.find("B") >= 0
	var do_c = only == "" or only.find("C") >= 0

	var a = {}
	if do_a:
		a = run_area_a()
	if do_b:
		run_area_b()
	if do_c:
		run_area_c()
	run_area_e()
	run_area_f()
	run_area_g()
	if do_a:
		report_perf(a)

	print("")
	print("=== GATE SUMMARY ===")
	for row in _rows:
		print("  %-4s %s" % [row[0], row[1]])
	var verdict = "PASS" if fails == 0 else "FAIL"
	print("RESULT checks=%d fails=%d %s" % [checks, fails, verdict])
	quit(fails)


# -- small helpers -------------------------------------------------------

func check(cond, what):
	checks += 1
	if cond:
		_rows.push_back(["PASS", what])
		print("ok   " + what)
	else:
		fails += 1
		_rows.push_back(["FAIL", what])
		print("FAIL " + what)


func note(what):
	print("note " + what)


func approx(a, b, eps = 0.0000001):
	return abs(float(a) - float(b)) <= eps


func vec_approx(a, b, eps = 0.0000001):
	return approx(a.x, b.x, eps) and approx(a.y, b.y, eps)


func make_arb(kind):
	var script
	if kind == "reference":
		script = load(_ref_path)
	else:
		script = load(_arb_path)
	if script == null:
		print("LOAD_FAIL " + ("reference" if kind == "reference" else _arb_path))
		return null
	var a = script.new()
	# The exact all-zero control arm: every v2.5/v2.6/v2.7 switch at 0 plus the
	# v2.8 cov/tapcd switches. Applied through the frozen --arb-* override
	# contract, so a script that has not landed a switch yet simply ignores it
	# (that is the "not ready" baseline behaviour).
	if kind == "control" or kind == "zero":
		a.apply_overrides({"breakout": 0, "goal": 0, "pursuit": 0, "walk": 0,
			"bounty": 0, "space": 0, "roomtrack": 0, "opp": 0,
			"cov": 0, "tapcd": 0, "pullsafe": 0})
	# v2.7 arms (ignored by a pre-v2.7 script, which then behaves as the
	# v2.7.0/v2.6.1 baseline -- exactly what the test-first baseline runs need):
	#   legacy = old switches untouched, unified opportunity layer at 0: the
	#            v2.6.1 binary-safe-gate behaviour E2/E2c keep asserting.
	#   agg0   = new layer on at the conservative risk-dial position.
	if kind == "legacy":
		a.apply_overrides({"opp": 0})
	if kind == "agg0":
		a.apply_overrides({"opp": 1, "agg": 0})
	# v2.8 arm: unified opportunity layer on, high-value coverage layer off ->
	# exact v2.7.0 values (class1=30, raw produce prices, no reward tags). This
	# is also the "raw value" comparison arm for the G1 crate scenario.
	if kind == "legacy27":
		a.apply_overrides({"opp": 1, "cov": 0, "tapcd": 0, "pullsafe": 0})
	return a


# v2.8 high-value coverage layer on: the plain arms leave --arb-cov at its 1.0
# default. world_view only attaches reward[6] tags when opp && cov are both on,
# so every other arm sees the v2.7.0 untagged reward tuples.
func arm_cov(arm):
	return arm == "default" or arm == "agg0" or arm == "agg2"


# Reports the switch defaults the loaded script exposes (probe only; never a
# hard requirement on internal names -- the hard checks are behavioural).
# --arb-tapcd is world_view-side only (no arbiter variable), so it is not
# probed here; the world_view probe suite checks fire_wait_frames/tap_cd.
func print_switch_defaults():
	var a = make_arb("default")
	var names = ["breakout_enable", "goal_enable", "pursuit_enable", "walk_enable",
			"bounty_enable", "room_track", "opp_enable", "opp_agg", "cov_enable"]
	var msg = ""
	for n in names:
		var v = a.get(n)
		msg += "%s=%s " % [n, "MISSING" if v == null else str(v)]
	note("switch defaults: " + msg)


# Telemetry flag read that also works on arms whose script does not have the
# property yet (the frozen v2.4/v2.6.1 baselines): Object.get returns null for
# a missing property, so a "not ready" script reads false instead of erroring.
func arb_flag(obj, name):
	var v = obj.get(name)
	return v != null and bool(v)


# v2.5+ world_view reward form (5-tuple walk-on tag + wave-end urgency): every
# arm except the all-zero v2.4-equivalent control and the frozen v2.4 reference.
func arm_modern(arm):
	return arm != "control" and arm != "zero" and arm != "reference"


# world_view attaches the 4th "special class" field to a target tuple only when
# the special-target tag is on: --arb-bounty != 0 (v2.6) or --arb-opp != 0
# (v2.7). The gate's arms mirror that so each arm sees the world it expects.
func arm_special_tag(arm):
	return arm == "default" or arm == "agg0" or arm == "agg2" or arm == "legacy"


# -- scenario C: per-frame direction comparison --------------------------

func compare_dirs(a, b):
	var n = min(a.size(), b.size())
	for i in range(n):
		if not vec_approx(a[i], b[i], 1e-9):
			return {"same": false, "first_bad": i, "frames": n}
	if a.size() != b.size():
		return {"same": false, "first_bad": n, "frames": n}
	return {"same": true, "first_bad": -1, "frames": n}


func run_area_c():
	print("")
	print("== C. control-arm equivalence (4 x --arb-*=0 vs git-HEAD v2.4.0) ==")
	var scns = [scenario_c1(), scenario_c2(), scenario_c3()]
	for scn in scns:
		var rz = run_scenario(scn, "zero", true, false)
		var rr = run_scenario(scn, "reference", true, false)
		var cmp = compare_dirs(rz["dirs"], rr["dirs"])
		var detail = "frames=%d" % cmp["frames"]
		if cmp["first_bad"] >= 0:
			detail += " first_mismatch_frame=%d t=%.2fs" % [cmp["first_bad"], float(cmp["first_bad"]) * DT]
		detail += " zero(t=%.2f alive=%s hp_min=%.1f) ref(t=%.2f alive=%s hp_min=%.1f)" % [
			rz["t"], str(rz["alive"]), rz["hp_min"],
			rr["t"], str(rr["alive"]), rr["hp_min"]]
		check(cmp["same"], "C dirs identical [%s] %s" % [scn["name"], detail])
		# The metrics must agree too, not just the direction stream.
		check(rz["alive"] == rr["alive"] and approx(rz["t"], rr["t"], 0.000001)
				and approx(rz["hp_min"], rr["hp_min"], 0.000001),
				"C end state identical [%s]" % scn["name"])


# -- area A: enclosure ---------------------------------------------------

func run_area_a():
	print("")
	print("== A. enclosure ==")
	var out = {}
	var a1 = scenario_a1()
	var a1c = run_scenario(a1, "control", false, true)
	var a1d = run_scenario(a1, "default", false, true)
	print_row("A1_ring20_walls", "control", a1c)
	print_row("A1_ring20_walls", "default", a1d)
	out["a1_control"] = a1c
	out["a1_default"] = a1d

	var ctrl_bad = (not a1c["alive"] and a1c["t"] <= 10.0) or a1c["surrounded_s"] > 1.0
	check(ctrl_bad, "A1 control arm reproduces the failure (dead<=10s or surrounded>1s): %s" %
			metric_summary(a1c))
	check(a1d["alive"] and a1d["t"] >= 29.99 and a1d["surrounded_s"] < 1.0,
			"A1 new default survives 30s with surrounded<1s: %s" % metric_summary(a1d))

	var a2 = scenario_a2()
	var a2c = run_scenario(a2, "control", false, true)
	var a2d = run_scenario(a2, "default", false, true)
	print_row("A2_ring_shooters", "control", a2c)
	print_row("A2_ring_shooters", "default", a2d)
	out["a2_control"] = a2c
	out["a2_default"] = a2d
	check(a2d["alive"] and a2d["t"] >= 29.99 and a2d["surrounded_s"] < 1.0,
			"A2 new default survives 30s with surrounded<1s: %s" % metric_summary(a2d))
	note("A2 control arm (reference, not a gate criterion): " + metric_summary(a2c))
	return out


# -- area B: committed item goal ----------------------------------------

func run_area_b():
	print("")
	print("== B. high-value walk-on item goal ==")
	var rows = [["B1_item_walkon", scenario_b()],
			["B2_item_open", scenario_b2()]]
	for row in rows:
		var name = row[0]
		var scn = row[1]
		var c = run_scenario(scn, "control", false, false)
		var d = run_scenario(scn, "default", false, false)
		print_row(name, "control", c)
		print_row(name, "default", d)
		check(d["alive"] and d["items_picked"] >= 1 and d["first_pick_t"] <= 20.0,
				"%s new default picks the walk-on item within 20s and survives: %s" %
				[name, metric_summary(d)])
		var ctrl_solved = c["alive"] and c["items_picked"] >= 1 and c["first_pick_t"] <= 20.0
		check(not ctrl_solved,
				"%s control arm does NOT solve it (discrimination): control %s" %
				[name, metric_summary(c)])
		if name == "B2_item_open":
			# v2.4 behaviour on a 650 px open-field item: the control arm DOES
			# walk toward the reward (it is not indifferent) but stops ~106 px
			# out and never picks it. NOTE: with the full-speed horizon step
			# (0.8 s * 320 = 256 px) an approach inside ~118-211 px overshoots
			# the item, so no candidate ends inside the 45 px held rim and the
			# gradient goes negative -- the bot parks in that dead band before
			# the rim. This is EXACTLY what the frozen v2.4.0 reference does
			# (same 106.0 px, gate-baseline cross-check), and it is the
			# action-space defect the v2.5 goal layer's close-range candidate
			# fixes (default picks at ~1.95 s). B1's 520 px + chaser geometry
			# happens to park at the rim (41.6 px) instead. The hard criterion
			# is therefore "approaches, but 0 pickups", not a literal rim
			# distance.
			check(c["items_picked"] == 0 and c["item_nearest"] < 250.0,
					"B2 control approaches but never picks (v2.4 failure; nearest=%.1fpx)" %
					c["item_nearest"])
			note("B2 control parking distance %.1fpx vs ~45px rim: v2.4 hop-free full-speed horizon overshoot dead band (frozen v2.4 reference reproduces exactly); default picks at %.2fs" %
					[c["item_nearest"], d["first_pick_t"]])


# -- area D: performance -------------------------------------------------

# -- area E: v2.6.0 / v2.7.0 one-frame probes -----------------------------
# Deterministic behavioural probes for the special-target layers. E1: a far
# special target (850 px) arms the bounty/opportunity approach, control does
# not. E2 (v2.7 semantics): the opp=0 fallback keeps the v2.6.1 binary
# near-body veto. E2b/E2c: the v2.7 route-risk model replaces that binary gate
# (a pursuing body ON the route vetoes the commit, a static body 120 px BESIDE
# it is an acceptable detour). E3: a near-wall crowd arms the CORNER breakout
# (reason "corner"), which the all-zero control arm must not do.
func run_area_e():
	print("-- area E: v2.6/v2.7 bounty / opportunity / corner probes")
	var far = Vector2(2000, 1800)
	var p0 = Vector2(500, 600)
	var target = Vector2(900, 1350)       # 850 px: outside acquire band+step
	var to_t = (target - p0).normalized()
	var targets = [[target, 60.0, false, 2]]
	var dflt = make_arb("default")
	var dflt_dir = dflt.choose(p0, 320.0, BODY_R, far, [], [], targets, [],
			260.0, false, 100.0, 1.0, {})
	check((arb_flag(dflt, "last_bounty") or arb_flag(dflt, "last_opp"))
			and dflt_dir.dot(to_t) > 0.95,
			"E1 default bounty/opportunity: heading aligned with a far special target")
	var ctl = make_arb("control")
	var ctl_dir = ctl.choose(p0, 320.0, BODY_R, far, [], [], targets, [],
			260.0, false, 100.0, 1.0, {})
	check(not arb_flag(ctl, "last_bounty") and ctl_dir.dot(to_t) < 0.5,
			"E1 control arm does not approach the far special target")

	# E2 (v2.7 semantics): the binary safe window still IS the behaviour on the
	# opp=0 fallback arm, so the original near-body veto assertion moves there.
	var close_threats = [[Vector2(620, 600), Vector2.ZERO, 14.0, 6.0,
			KIND_CONTACT, 0.0, CONTACT_TICKS, INF_TIME]]
	var legacy = make_arb("legacy")
	legacy.choose(p0, 320.0, BODY_R, far, close_threats, [], targets, [],
			260.0, false, 100.0, 1.0, {})
	check(not arb_flag(legacy, "last_bounty"),
			"E2 legacy (opp=0) binary safe gate vetoes bounty for a close body")

	# E2b: a PURSUING body dead on the straight route to a class-1 special.
	var p1 = Vector2(500, 600)
	var tgt1 = [[Vector2(1300, 600), 60.0, true, 1]]   # 800 px, class 1
	# The tuple carries world_view's per-speed contact T_TICKS for a 250 px/s
	# pursuer against a 320 px/s player: CONTACT_RATE / max(1 - 250/320, 1/4)
	# = 1.6 / 0.25 = 6.4. Crossing prices 6 dmg * 6.4 = 38.4 HP-equivalent,
	# above the agg=1 allowance on BOTH baselines (v2.7.0 class1=30 ->
	# 30*0.30+2 = 11; v2.8 cov=1 Boss=50 -> 50*0.30+2 = 17): must be refused.
	var block_ticks = 6.4
	var blocking = [[Vector2(750, 600), Vector2(-250, 0), 14.0, 6.0,
			KIND_CONTACT, 0.0, block_ticks, INF_TIME]]
	var e2b = make_arb("default")
	e2b.choose(p1, 320.0, BODY_R, far, blocking, [], tgt1, [],
			260.0, false, 100.0, 1.0, {})
	check(not arb_flag(e2b, "last_opp") and not arb_flag(e2b, "last_bounty"),
			"E2b default does not commit through a body-blocked route (risk too high)")
	var e2b0 = make_arb("agg0")
	e2b0.choose(p1, 320.0, BODY_R, far, blocking, [], tgt1, [],
			260.0, false, 100.0, 1.0, {})
	check(not arb_flag(e2b0, "last_opp"), "E2b agg=0 also refuses the blocked route")

	# E2c: a STATIC body 120 px to the side of the same route. Its closest
	# approach (120 px) is outside the risk taper (hit radius 32 + 60), so the
	# route risk is 0 and the agg=1 arm may commit -- while the opp=0 legacy
	# binary bubble (300 px) still vetoes exactly as v2.6.1 did.
	var side_body = [[Vector2(750, 720), Vector2.ZERO, 14.0, 6.0,
			KIND_CONTACT, 0.0, CONTACT_TICKS, INF_TIME]]
	var e2c = make_arb("default")
	e2c.choose(p1, 320.0, BODY_R, far, side_body, [], tgt1, [],
			260.0, false, 100.0, 1.0, {})
	var e2c_kind = e2c.get("last_opp_kind")
	check(arb_flag(e2c, "last_opp") and e2c_kind != null and str(e2c_kind) == "target",
			"E2c default arms the class-1 special past a side body 120px off-route")
	# v2.8 value premise: cov=1 splits Boss (class 1) from Elite (class 4) and
	# the class-1 table value becomes 50 (v2.7.0 kept Boss+Elite at class 1 =
	# 30). Only a script exposing cov_enable can be held to the new table, so
	# the frozen v2.7.0 baseline SKIPS this check and keeps its single expected
	# failure (the G1 feature-missing proof).
	var cov_var = e2c.get("cov_enable")
	var e2c_val = e2c.get("last_opp_value")
	var e2c_risk = e2c.get("last_opp_risk")
	if cov_var != null and float(cov_var) != 0.0:
		check(approx(float(e2c_val), 50.0),
				"E2c premise cov=1: class-1 Boss value = 50 (last_opp_value=%.1f risk=%.1f)" % [
					float(e2c_val), float(e2c_risk)])
	else:
		note("E2c v2.8 value premise skipped (no cov_enable on this script; v2.7.0 class1=30)")
	var legacy_c = make_arb("legacy")
	legacy_c.choose(p1, 320.0, BODY_R, far, side_body, [], tgt1, [],
			260.0, false, 100.0, 1.0, {})
	check(not arb_flag(legacy_c, "last_bounty"),
			"E2c legacy (opp=0) arm is still vetoed by the 277px side body")

	var p_wall = Vector2(160, 600)        # 142 px from the left wall (<150 band)
	var crowd = []
	for i in range(7):
		var ang = float(i) * TAU / 7.0
		crowd.push_back([p_wall + Vector2(cos(ang), sin(ang)) * 300.0,
				Vector2.ZERO, 14.0, 6.0, KIND_CONTACT, 0.0, CONTACT_TICKS,
				INF_TIME])
	var cor = make_arb("default")
	cor.choose(p_wall, 320.0, BODY_R, far, crowd, [], [], [],
			260.0, false, 100.0, 1.0, {})
	check(bool(cor.last_breakout) and str(cor.last_breakout_reason) == "corner",
			"E3 near-wall crowd arms the corner breakout")
	var corc = make_arb("control")
	corc.choose(p_wall, 320.0, BODY_R, far, crowd, [], [], [],
			260.0, false, 100.0, 1.0, {})
	check(not bool(corc.last_breakout), "E3 control arm has no breakout")


func report_perf(a):
	print("")
	print("== D. choose() performance (A. enclosure, default vs control) ==")
	var pairs = [["A1_ring20_walls", a["a1_control"], a["a1_default"]],
			["A2_ring_shooters", a["a2_control"], a["a2_default"]]]
	for p in pairs:
		var cu = float(p[1]["perf_us"])
		var du = float(p[2]["perf_us"])
		var ratio = du / max(cu, 0.001)
		print("   %-19s control=%7.0f us  default=%7.0f us  ratio=%.2fx  (target<=2.5x, informational)" %
				[p[0], cu, du, ratio])
		note("D %s ratio %.2fx %s" % [p[0], ratio, "(within target)" if ratio <= 2.5 else "(above target, not a hard fail)"])


# -- area F: v2.7 unified opportunity planner, closed loop ------------------
# F1 checks that the unified layer WILL accept a small, priced detour: one
# STATIC body 250 px dead ahead prices at world_view's 1.6-tick brush, so the
# straight route costs 6 dmg * 1.6 = 9.6 HP-equivalent. Value premise: class 1 =
# 30 in v2.7.0 (agg=1 allowance 11, agg=0 allowance 3) and 50 under v2.8
# cov=1 where it is a Boss (allowance 17 / 5). So the default keeps committing
# on both baselines while agg=0 keeps its distance on both, exactly the design's
# "relax the binary gate by one priced notch" intent. The control arm has no
# opportunity layer at all.
func run_area_f():
	print("")
	print("== F. v2.7 unified opportunity planner (closed loop) ==")
	print("-- F1: static body 250px on the route, class-1 special 800px, weapon_range 260 --")
	var f1 = scenario_f1()
	var f1c = run_scenario(f1, "control", false, false)
	var f1a = run_scenario(f1, "agg0", false, false)
	var f1d = run_scenario(f1, "default", false, false)
	print_row("F1_blocker_special", "control", f1c)
	print_row("F1_blocker_special", "agg0", f1a)
	print_row("F1_blocker_special", "default", f1d)
	var edge = max(260.0 * 0.9, 70.0) + 40.0
	check(f1d["target_reach_t"] >= 0.0 and f1d["target_reach_t"] <= 20.0,
			"F1 default (agg=1) enters the firing-range edge within 20s: target_min=%.1fpx (edge<=%.0f) reach_t=%s opp_s=%.2fs" % [
				f1d["target_min"], edge,
				("-" if f1d["target_reach_t"] < 0.0 else "%.2fs" % f1d["target_reach_t"]),
				f1d["opp_s"]])
	check(f1a["target_min"] > edge,
			"F1 agg=0 keeps its distance (never inside %.0fpx): target_min=%.1fpx opp_s=%.2fs" % [
				edge, f1a["target_min"], f1a["opp_s"]])
	check(f1c["target_min"] > edge,
			"F1 control keeps its distance (never inside %.0fpx): target_min=%.1fpx opp_s=%.2fs" % [
				edge, f1c["target_min"], f1c["opp_s"]])
	note("F1 detail: default end_dist=%.1fpx opp_s=%.2fs | agg0 end_dist=%.1fpx opp_s=%.2fs | control end_dist=%.1fpx opp_s=%.2fs" % [
			f1d["target_dist_end"], f1d["opp_s"],
			f1a["target_dist_end"], f1a["opp_s"],
			f1c["target_dist_end"], f1c["opp_s"]])

	print("-- F2: 5 pursuers 200px around the start, class-1 special 700px --")
	var f2 = scenario_f2()
	var f2c = run_scenario(f2, "control", false, false)
	var f2d = run_scenario(f2, "default", false, false)
	print_row("F2_surround_special", "control", f2c)
	print_row("F2_surround_special", "default", f2d)
	check(f2d["alive"] == f2c["alive"] and f2d["hp_min"] >= f2c["hp_min"] - 10.0,
			"F2 default survival/HP not materially worse than control: default alive=%s t=%.1fs hp_min=%.1f vs control alive=%s t=%.1fs hp_min=%.1f" % [
				str(f2d["alive"]), f2d["t"], f2d["hp_min"],
				str(f2c["alive"]), f2c["t"], f2c["hp_min"]])
	# The "did it dive into the pack" question is informational by contract.
	note("F2 detail (report only): default nearest_min=%.1fpx contact=%.2fs surrounded=%.2fs opp_s=%.2fs target_min=%.1fpx | control nearest_min=%.1fpx contact=%.2fs surrounded=%.2fs opp_s=%.2fs target_min=%.1fpx" % [
			f2d["nearest_min"], f2d["contact_s"], f2d["surrounded_s"],
			f2d["opp_s"], f2d["target_min"],
			f2c["nearest_min"], f2c["contact_s"], f2c["surrounded_s"],
			f2c["opp_s"], f2c["target_min"]])


# -- area G: v2.8 high-value produce coverage (closed loop) ----------------
# G1: a legendary item crate is a reward whose raw r[1] price is low (the gate
# uses 5.0; world_view's own LEGENDARY_BOX_VALUE is 10.0) but whose v2.8 reward
# tag r[6]=2 prices it at table value 34. One STATIC body sits 250 px dead on
# the route, so the straight route costs 6*1.6 = 9.6 HP-equivalent:
#   default (opp=1 cov=1): _opp_reward_value = max(5, 34) = 34 ->
#     agg=1 allowance 34*0.30+2 = 12.2 > 9.6 -> commits, approaches, picks.
#   legacy27 (opp=1 cov=0, exact v2.7.0): value 5 -> allowance 3.5 < 9.6 ->
#     no commitment; only the old weak pickup gradient remains (B2-style
#     parking), so no pickup inside 20 s.
#   control (opp=0): no opportunity layer at all -> no pickup.
#   no-tag variant under the default arbiter: same scenario with the tag
#     omitted -> value 5 untagged, so the same "do not detour" outcome. This is
#     the raw-value-5 comparison arm and proves the TAG (not some other v2.8
#     movement change) is what makes the default pick the crate.
func run_area_g():
	print("")
	print("== G. v2.8 high-value produce coverage (closed loop) ==")
	print("-- G1: legendary crate (tag 2, value 34) behind a static body 250px on the route --")
	var g1 = scenario_g1()
	var g1c = run_scenario(g1, "control", false, false)
	var g1l = run_scenario(g1, "legacy27", false, false)
	var g1d = run_scenario(g1, "default", false, false)
	print_row("G1_legendary_crate", "control", g1c)
	print_row("G1_legendary_crate", "legacy27", g1l)
	print_row("G1_legendary_crate", "default", g1d)
	check(g1d["first_pick_t"] >= 0.0 and g1d["first_pick_t"] <= 20.0
			and g1d["item_nearest"] <= 60.0,
			"G1 default (cov=1) upgrades the crate to value 34 and picks it within 20s: pick=%s nearest=%.1fpx opp_s=%.2fs" % [
				("no" if g1d["first_pick_t"] < 0.0 else "%.2fs" % g1d["first_pick_t"]),
				g1d["item_nearest"], g1d["opp_s"]])
	check(g1l["items_picked"] == 0 and g1l["item_nearest"] > 60.0,
			"G1 cov=0 arm (raw value 5, exact v2.7.0) does NOT detour for the crate: pick=%d nearest=%.1fpx opp_s=%.2fs" % [
				g1l["items_picked"], g1l["item_nearest"], g1l["opp_s"]])
	check(g1c["items_picked"] == 0 and g1c["opp_s"] == 0.0,
			"G1 control arm has no opportunity layer: pick=%d nearest=%.1fpx opp_s=%.2fs" % [
				g1c["items_picked"], g1c["item_nearest"], g1c["opp_s"]])
	var g1nt = scenario_g1_notag()
	var g1ntd = run_scenario(g1nt, "default", false, false)
	print_row("G1_legendary_crate", "d(no-tag)", g1ntd)
	check(g1ntd["items_picked"] == 0 and g1ntd["item_nearest"] > 60.0,
			"G1 raw-value-5 comparison (no tag, default arbiter) does NOT detour: pick=%d nearest=%.1fpx opp_s=%.2fs" % [
				g1ntd["items_picked"], g1ntd["item_nearest"], g1ntd["opp_s"]])
	note("G1 detail: default item_min=%.1fpx opp_s=%.2fs | legacy27 item_min=%.1fpx opp_s=%.2fs | control item_min=%.1fpx opp_s=%.2fs | no-tag item_min=%.1fpx opp_s=%.2fs" % [
			g1d["item_nearest"], g1d["opp_s"],
			g1l["item_nearest"], g1l["opp_s"],
			g1c["item_nearest"], g1c["opp_s"],
			g1ntd["item_nearest"], g1ntd["opp_s"]])


# -- one closed-loop run -------------------------------------------------
# scn keys: name, far, start, player_speed, enemies[], duration,
#           items[] (optional: pos/value/rim/walk + v2.8 `tag` reward class),
#           wave_end (optional bool), targets[] (optional:
#           [pos, value, is_boss, special_class]) and weapon_range (optional
#           px, default 0 = pre-v2.7 behaviour), contact_ticks (optional:
#           threat T_TICKS for contact bodies; default CONTACT_TICKS = the flat
#           closed-loop simplification).
# arm:      default  = script defaults (v2.7 opportunity + v2.8 cov/tapcd on)
#           control  = script + all v2.5/v2.6/v2.7/v2.8 switches 0 (v2.4 compat)
#           zero     = same as control (C)
#           reference= frozen v2.4.0 script, no v2.5+ switches at all
#           legacy   = script defaults + opp=0 (v2.6.1 binary-safe-gate path)
#           agg0     = script defaults + opp=1 agg=0 (conservative risk dial)
#           legacy27 = script defaults + opp=1 cov=0 tapcd=0 (exact v2.7.0)
func run_scenario(scn, arm, record_dirs = false, want_perf = false):
	var arb = make_arb(arm)
	if arb == null:
		check(false, "could not build arm " + arm)
		return _empty_result()

	var far = scn["far"]
	var p = scn["start"]
	var speed = float(scn["player_speed"])
	var duration = float(scn["duration"])
	var wave_end = bool(scn.get("wave_end", false))
	var weapon_range = float(scn.get("weapon_range", 0.0))
	var contact_ticks = float(scn.get("contact_ticks", CONTACT_TICKS))

	# Threat-side targets. The 4th field is world_view's special class; the
	# all-zero/reference arms see the untagged 3-tuple like their world_view.
	var targets = []
	for tg in scn.get("targets", []):
		var tup = [tg[0], float(tg[1]), bool(tg[2])]
		if arm_special_tag(arm):
			tup.push_back(int(tg[3]) if tg.size() > 3 else 0)
		targets.push_back(tup)
	var has_target = targets.size() > 0
	var target_pos = targets[0][0] if has_target else Vector2.ZERO
	# "in firing range" for a special-target commitment: desired = max(wr*0.9,
	# 70) px, plus the 40 px acceptance margin the design contract specifies.
	var target_reach_r = max(weapon_range * 0.9, 70.0) + 40.0

	var enemies = []
	for e in scn["enemies"]:
		enemies.push_back({
			"pos": e["pos"], "speed": float(e["speed"]),
			"radius": float(e["radius"]), "dmg": float(e["dmg"]),
			"cd": 0.0, "ranged": bool(e.get("ranged", false)),
			"shot_cd": 0.7,
		})
	var items = []
	for it in scn.get("items", []):
		items.push_back({
			"pos": it["pos"], "value": float(it["value"]),
			"rim": float(it.get("rim", 0.0)),
			"walk": bool(it.get("walk", false)), "picked": false,
			# v2.8: optional reward tag class, packed by world_view at r[6]
			# only when --arb-opp and --arb-cov are both on.
			"tag": int(it.get("tag", 0)),
		})

	var hp = 100.0
	var hp_min = 100.0
	var t = 0.0
	var steps = int(round(duration / DT))
	var contact_s = 0.0
	var surrounded_s = 0.0
	var nearest_min = INF_TIME
	var items_picked = 0
	var first_pick_t = -1.0
	var item_nearest = INF_TIME
	var bullets = []
	var dirs = []
	var perf_sum = 0
	var perf_n = 0
	var frames = 0
	# v2.7 metrics: distance to the first scenario target and the arm's own
	# commitment telemetry (last_opp / last_bounty, taken from the live script).
	var target_min = INF_TIME
	var target_min_t = -1.0
	var target_reach_t = -1.0
	var target_dist_end = INF_TIME
	var opp_s = 0.0
	var bounty_s = 0.0

	for step in range(steps):
		frames += 1
		# -- threat set (same shape world_view hands the arbiter) --
		var threats = []
		var sectors = []
		for _k in range(8):
			sectors.push_back(false)
		for e in enemies:
			var epos = e["pos"]
			var dist = p.distance_to(epos)
			nearest_min = min(nearest_min, dist)
			if dist > ENEMY_THREAT_R:
				continue
			var vel = Vector2.ZERO
			if dist > 0.001:
				vel = (p - epos) / dist * float(e["speed"])
			threats.push_back([epos, vel, float(e["radius"]), float(e["dmg"]),
					KIND_CONTACT, 0.0, contact_ticks, INF_TIME])
			if dist < SURROUND_R:
				var ang = (epos - p).angle()
				var sec = int(floor((ang + PI) / TAU * 8.0)) % 8
				sectors[sec] = true
		for b in bullets:
			threats.push_back([b["pos"], b["vel"], float(b["radius"]),
					float(b["dmg"]), KIND_PROJ, 0.0, PROJ_TICKS, PROJ_END])
		var occ = 0
		for sflag in sectors:
			if sflag:
				occ += 1
		if occ >= SURROUND_SECTORS:
			surrounded_s += DT

		# -- reward set: the world_view form depends on the arm --
		# default = v2.5+ world_view (5-tuple walk-on tag + wave-end urgency on
		# the value); control/reference = v2.4 world_view (4-tuple, held rim).
		# v2.8: default/agg arms ALSO get r[6] reward tags (--arb-cov=1), packed
		# exactly like world_view's _opp_reward_tag(): a 2-field drop becomes
		# [pos,v,true,0,0,0,tag], a walk-on 5-field becomes
		# [pos,v,false,rim,1.0,0.0,tag]. cov=0 arms get the untagged v2.7.0 form.
		var rewards = []
		for it in items:
			if bool(it["picked"]):
				continue
			var v = float(it["value"])
			if wave_end and arm_modern(arm):
				v *= waveend_scale(duration - t, p.distance_to(it["pos"]), speed)
			var tag = int(it["tag"]) if arm_cov(arm) else 0
			if it["rim"] > 0.0:
				if arm_modern(arm) and bool(it["walk"]):
					if tag != 0:
						rewards.push_back([it["pos"], v, false, float(it["rim"]),
								1.0, 0.0, float(tag)])
					else:
						rewards.push_back([it["pos"], v, false, float(it["rim"]), 1.0])
				else:
					# Held reward (revive zone): never tagged, by design.
					rewards.push_back([it["pos"], v, false, float(it["rim"])])
			else:
				if tag != 0:
					# Attracted drop form: r[2]=true keeps the attract reading.
					rewards.push_back([it["pos"], v, true, 0.0, 0.0, 0.0, float(tag)])
				elif arm_modern(arm):
					# v2.7.0 world_view drop form: 2 fields, r[2] default true.
					rewards.push_back([it["pos"], v])
				else:
					rewards.push_back([it["pos"], v, false])

		# -- the decision under test --
		var dir
		if want_perf:
			var t0 = OS.get_ticks_usec()
			dir = arb.choose(p, speed, BODY_R, far, threats, rewards, targets, [],
					weapon_range, false, hp, 1.0, {})
			if step >= 30:    # skip the first half second (warm-up)
				perf_sum += OS.get_ticks_usec() - t0
				perf_n += 1
		else:
			dir = arb.choose(p, speed, BODY_R, far, threats, rewards, targets, [],
					weapon_range, false, hp, 1.0, {})
		if record_dirs:
			dirs.push_back(dir)
		# v2.7 telemetry: seconds under a unified-opportunity / legacy-bounty
		# commitment (arb_flag is null-safe on pre-v2.7 arms -> 0.00 s).
		if arb_flag(arb, "last_opp"):
			opp_s += DT
		if arb_flag(arb, "last_bounty"):
			bounty_s += DT

		# -- move --
		p += dir * speed * DT
		p.x = clamp(p.x, BODY_R, far.x - BODY_R)
		p.y = clamp(p.y, BODY_R, far.y - BODY_R)
		if has_target:
			var td = p.distance_to(target_pos)
			if td < target_min:
				target_min = td
				target_min_t = t + DT
			if target_reach_t < 0.0 and td <= target_reach_r:
				target_reach_t = t + DT
			target_dist_end = td

		# -- enemies: pursuit, contact, ranged fire --
		var touching = false
		for e in enemies:
			var stop = float(e["radius"]) + BODY_STOP_PAD
			var to = p - e["pos"]
			var d = to.length()
			if d > stop and d > 0.0001:
				e["pos"] += to / d * float(e["speed"]) * DT
			if d <= stop + CONTACT_SLACK:
				touching = true
				e["cd"] = float(e["cd"]) - DT
				if float(e["cd"]) <= 0.0:
					hp -= float(e["dmg"])
					e["cd"] = CONTACT_CD
			if bool(e["ranged"]) and d < RANGED_FIRE_R:
				e["shot_cd"] = float(e["shot_cd"]) - DT
				if float(e["shot_cd"]) <= 0.0:
					e["shot_cd"] = RANGED_CD
					var bv = (p - e["pos"]).normalized() * RANGED_BULLET_SPEED
					bullets.push_back({"pos": e["pos"], "vel": bv,
							"dmg": RANGED_BULLET_DMG, "radius": 4.0})
		if touching:
			contact_s += DT
		hp_min = min(hp_min, hp)
		if hp <= 0.0:
			return _result(false, t, hp_min, contact_s, surrounded_s, nearest_min,
					items_picked, first_pick_t, item_nearest, dirs, perf_sum,
					perf_n, frames, target_min, target_min_t, target_reach_t,
					target_dist_end, opp_s, bounty_s)

		# -- bullets --
		var keep = []
		for b in bullets:
			b["pos"] += b["vel"] * DT
			var bp = b["pos"]
			if p.distance_to(bp) < float(b["radius"]) + 20.0:
				hp -= float(b["dmg"])
				continue
			if bp.x < -100.0 or bp.x > far.x + 100.0 \
					or bp.y < -100.0 or bp.y > far.y + 100.0:
				continue
			keep.push_back(b)
		bullets = keep
		hp_min = min(hp_min, hp)
		if hp <= 0.0:
			return _result(false, t, hp_min, contact_s, surrounded_s, nearest_min,
					items_picked, first_pick_t, item_nearest, dirs, perf_sum,
					perf_n, frames, target_min, target_min_t, target_reach_t,
					target_dist_end, opp_s, bounty_s)

		# -- walk-on pickup: the game takes the item when the body is on it --
		for it in items:
			if bool(it["picked"]):
				continue
			var idist = p.distance_to(it["pos"])
			item_nearest = min(item_nearest, idist)
			if idist < PICKUP_R:
				it["picked"] = true
				items_picked += 1
				if first_pick_t < 0.0:
					first_pick_t = t + DT

		t += DT

	return _result(true, t, hp_min, contact_s, surrounded_s, nearest_min,
			items_picked, first_pick_t, item_nearest, dirs, perf_sum, perf_n, frames,
			target_min, target_min_t, target_reach_t, target_dist_end, opp_s,
			bounty_s)


func _empty_result():
	return {"alive": false, "t": 0.0, "hp_min": 0.0, "contact_s": 0.0,
			"surrounded_s": 0.0, "nearest_min": 0.0, "items_picked": 0,
			"first_pick_t": -1.0, "item_nearest": -1.0,
			"target_min": INF_TIME, "target_min_t": -1.0,
			"target_reach_t": -1.0, "target_dist_end": INF_TIME,
			"opp_s": 0.0, "bounty_s": 0.0,
			"dirs": [], "perf_us": -1.0, "frames": 0}


func _result(alive, t, hp_min, contact_s, surrounded_s, nearest_min,
		items_picked, first_pick_t, item_nearest, dirs, perf_sum, perf_n, frames,
		target_min = INF_TIME, target_min_t = -1.0, target_reach_t = -1.0,
		target_dist_end = INF_TIME, opp_s = 0.0, bounty_s = 0.0):
	var us = -1.0
	if perf_n > 0:
		us = float(perf_sum) / float(perf_n)
	return {
		"alive": alive, "t": t, "hp_min": max(hp_min, 0.0),
		"contact_s": contact_s, "surrounded_s": surrounded_s,
		"nearest_min": nearest_min, "items_picked": items_picked,
		"first_pick_t": first_pick_t, "item_nearest": item_nearest,
		"target_min": target_min, "target_min_t": target_min_t,
		"target_reach_t": target_reach_t, "target_dist_end": target_dist_end,
		"opp_s": opp_s, "bounty_s": bounty_s,
		"dirs": dirs, "perf_us": us, "frames": frames,
	}


# world_view v2.5 wave-end urgency, verbatim shape:
# scale = clamp(1 + BOOST * (1 - wave_left / (eta + MARGIN)), 1, CAP).
func waveend_scale(wave_left, dist, speed):
	var eta = dist / max(speed, 1.0)
	var span = eta + WAVEEND_MARGIN
	if wave_left >= span:
		return 1.0
	return clamp(1.0 + WAVEEND_BOOST * (1.0 - wave_left / span),
			1.0, WAVEEND_CAP)


func print_row(name, arm, r):
	var pick = " " if r["items_picked"] == 0 else "pick@%.2fs" % r["first_pick_t"]
	var extra = ""
	if float(r["target_min"]) < 1e8:
		extra = " tgt_min=%6.1f tgt_reach=%-6s tgt_end=%6.1f opp=%5.2fs bounty=%5.2fs" % [
			r["target_min"],
			("-" if r["target_reach_t"] < 0.0 else "%.2fs" % r["target_reach_t"]),
			r["target_dist_end"], r["opp_s"], r["bounty_s"]]
	print("   %-16s %-7s alive=%-5s t=%5.1f hp_min=%5.1f contact=%6.2fs surrounded=%6.2fs nearest=%6.1f %s perf=%s%s" % [
		name, arm, str(r["alive"]), r["t"], r["hp_min"], r["contact_s"],
		r["surrounded_s"], r["nearest_min"], pick,
		("-" if r["perf_us"] < 0.0 else "%.0fus" % r["perf_us"]), extra])


func metric_summary(r):
	return "alive=%s t=%.1fs hp_min=%.1f contact=%.2fs surrounded=%.2fs picked=%d@%.2fs item_nearest=%.1fpx" % [
		str(r["alive"]), r["t"], r["hp_min"], r["contact_s"],
		r["surrounded_s"], r["items_picked"], r["first_pick_t"], r["item_nearest"]]


# -- scenario builders ---------------------------------------------------

func ring(center, radius, n, speed, dmg, shooter_every = 0):
	var out = []
	for i in range(n):
		var a = float(i) * TAU / float(n)
		out.push_back({
			"pos": center + Vector2(cos(a), sin(a)) * radius,
			"speed": float(speed), "radius": 14.0, "dmg": float(dmg),
			"ranged": shooter_every > 0 and (i % shooter_every) == 0,
		})
	return out


# A1: the reported "about to be surrounded" case (Lead's exploration repro).
func scenario_a1():
	return {
		"name": "A1_ring20_walls",
		"far": Vector2(1200, 900),
		"start": Vector2(600, 450),
		"player_speed": 320.0,
		"enemies": ring(Vector2(600, 450), 380.0, 20, 280.0, 6.0),
		"duration": 30.0,
	}


# A2: 9 pursuers, every 3rd a ranged shooter (4 dmg / 1.6 s bullets).
func scenario_a2():
	return {
		"name": "A2_ring_shooters",
		"far": Vector2(1600, 1200),
		"start": Vector2(800, 600),
		"player_speed": 320.0,
		"enemies": ring(Vector2(800, 600), 440.0, 9, 250.0, 6.0, 3),
		"duration": 30.0,
	}


# B: open field, 1 slow pursuer 320 px behind, value-9 walk-on item 520 px
# ahead (rim 45, i.e. exactly the world_view EVO_WALK_RIM). The simulated
# end-of-wave urgency scales the value in the last seconds of the 20 s run.
func scenario_b():
	return {
		"name": "B1_item_walkon",
		"far": Vector2(2048, 1536),
		"start": Vector2(1024, 768),
		"player_speed": 320.0,
		"enemies": [{
			"pos": Vector2(1024.0 - 320.0, 768.0), "speed": 190.0,
			"radius": 14.0, "dmg": 6.0,
		}],
		"items": [{
			"pos": Vector2(1024.0 + 520.0, 768.0), "value": 9.0,
			"rim": 45.0, "walk": true,
		}],
		"duration": 20.0,
		"wave_end": true,
	}


# B2 (Lead requested): the purest "does it plan a detour for a high-value
# item" case -- open field, ZERO threats, value-9 walk-on item 650 px away.
# Default must walk straight to it and pick it (~2 s = 620 px / 320 px/s);
# the v2.4 held-rim control arm walks to the rim (45 px) and parks: the
# physical pickup is 30 px, so it never collects. Cross-checks the Lead's
# exploration sim item_far_safe (default 1.9 s, control 0).
func scenario_b2():
	return {
		"name": "B2_item_open",
		"far": Vector2(2048, 1536),
		"start": Vector2(1024, 768),
		"player_speed": 320.0,
		"enemies": [],
		"items": [{
			"pos": Vector2(1024.0 + 650.0, 768.0), "value": 9.0,
			"rim": 45.0, "walk": true,
		}],
		"duration": 20.0,
	}


# C1: open ring, no bullets -- a long full-speed run over the planner path.
func scenario_c1():
	return {
		"name": "C1_ring10_open",
		"far": Vector2(2048, 1536),
		"start": Vector2(1024, 768),
		"player_speed": 320.0,
		"enemies": ring(Vector2(1024, 768), 500.0, 10, 200.0, 6.0),
		"duration": 30.0,
	}


# C2: the shooter scenario (projectiles go through the same cost path).
func scenario_c2():
	var s = scenario_a2()
	s["name"] = "C2_ring_shooters"
	return s


# C3: a held-rim reward: exercises the reward branch of _cost, where the
# --arb-walk=0 fallback must keep the 2.4.0 held reading.
func scenario_c3():
	return {
		"name": "C3_item_held",
		"far": Vector2(2048, 1536),
		"start": Vector2(1024, 768),
		"player_speed": 320.0,
		"enemies": ring(Vector2(1024, 768), 420.0, 8, 200.0, 6.0),
		"items": [{
			"pos": Vector2(1024.0 + 620.0, 768.0), "value": 9.0,
			"rim": 45.0, "walk": false,
		}],
		"duration": 30.0,
	}


# F1 (design contract §4): one STATIC body 250 px dead ahead, class-1 special
# 800 px away, weapon_range 260 -> desired = max(234,70) = 234 px, acceptance
# edge desired+40 = 274 px. A static body is exactly the flat 1.6-tick brush the
# closed-loop gate uses (world_view _contact_ticks(0) = 1.6 too), so route risk
# is 9.6 HP-equivalent. Default (agg=1) allowance: value 30 in v2.7.0 -> 11; v2.8
# cov=1 makes class 1 a Boss worth 50 -> 17. Both are ABOVE 9.6, so the default
# arm must keep committing; agg=0 allowance is 30*0.10 = 3 (v2.7.0) / 50*0.10 = 5
# (v2.8), both BELOW 9.6, so agg=0 must keep its distance on either baseline.
func scenario_f1():
	return {
		"name": "F1_blocker_special",
		"far": Vector2(2048, 1536),
		"start": Vector2(1024, 768),
		"player_speed": 320.0,
		"enemies": [{
			"pos": Vector2(1274.0, 768.0), "speed": 0.0,
			"radius": 14.0, "dmg": 6.0,
		}],
		"targets": [[Vector2(1824.0, 768.0), 60.0, true, 1]],
		"weapon_range": 260.0,
		"duration": 20.0,
	}


# F2 (design contract §4): 5 pursuers 200 px around the start + a value-30
# special 700 px away. The threat tuples carry world_view's REAL per-speed
# contact persistence for these 250 px/s bodies against a 320 px/s player:
# _contact_ticks(250) = CONTACT_RATE / max(1 - 250/320, 1/persist_max) = 6.4.
# That is deliberately NOT the flat-1.6 closed-loop simplification used by the
# A/B/C comparability scenarios: F2 exists precisely to test the risk model, so
# it must see the price world_view would actually send. (For the static body in
# F1 both conventions coincide at 1.6, so no divergence there.)
func scenario_f2():
	return {
		"name": "F2_surround_special",
		"far": Vector2(2048, 1536),
		"start": Vector2(1024, 768),
		"player_speed": 320.0,
		"enemies": ring(Vector2(1024, 768), 200.0, 5, 250.0, 6.0),
		"targets": [[Vector2(1724.0, 768.0), 60.0, true, 1]],
		"weapon_range": 260.0,
		"contact_ticks": 6.4,
		"duration": 25.0,
	}


# G1 (v2.8 design contract §2): legendary item crate behind one STATIC body
# 250 px on the route. Raw reward price 5.0 (low, below the v2.7.0 opportunity
# screen for this route), tag r[6]=2 = legendary crate -> v2.8 table value 34.
# Crate 530 px out; player 320 px/s; weapon_range 260 so the reward-candidate
# desired range is 0 (rewards commit on GOAL_DONE_R/arrival, not weapon range).
func scenario_g1():
	return {
		"name": "G1_legendary_crate",
		"far": Vector2(2048, 1536),
		"start": Vector2(1024, 768),
		"player_speed": 320.0,
		"enemies": [{
			"pos": Vector2(1274.0, 768.0), "speed": 0.0,
			"radius": 14.0, "dmg": 6.0,
		}],
		"items": [{
			"pos": Vector2(1554.0, 768.0), "value": 5.0, "tag": 2,
		}],
		"weapon_range": 260.0,
		"duration": 20.0,
	}


# Raw-value-5 comparison variant of G1: identical world, tag omitted. Run with
# the default arm this isolates the TAG from any other v2.8 movement change --
# a cov=1 world without the crate tag must behave like the v2.7.0 raw price.
func scenario_g1_notag():
	var s = scenario_g1()
	s["name"] = "G1_legendary_crate_notag"
	s["items"] = [{
		"pos": Vector2(1554.0, 768.0), "value": 5.0,
	}]
	return s

