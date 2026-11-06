extends SceneTree

# Quantifies the v2.6 opportunity gates with the REAL arbiter script:
#   - bounty: which distances / nearby-body distances still let it arm?
#   - goal:   same for a high-value walk-on reward (evo item / crate / loot).
# Prints a table of (feature, target distance, nearest body distance, armed).
# No world simulation: one choose() call per row, deterministic.
#
# v2.7 addition: when the arbiter carries the opp layer (--arb-opp), the third
# section sweeps the unified planner instead: a class-1 special (value 30) at
# 620/800/1000 px, a single static body whose geometry is either PERPENDICULAR
# (the old probe geometry, mimics the v2.6 nearest-body veto) or ON ROUTE
# (design F1: body 250 px straight in the way), for agg 0/1/2. On a v2.6.1
# arbiter the section prints "feature absent" and the two legacy tables above
# are the reproducible baseline.

const BODY_R = 18.0
const FAR = Vector2(2400, 1600)
const P0 = Vector2(600, 800)
const BODY_SPEED = 0.0    # static blocker: the v2.6/v2.7 probes are about gates


func _init():
	var A = load("res://arbiter.gd")
	if A == null:
		print("LOAD FAIL")
		quit(1)
		return
	print("== bounty (special target tag, v2.6/v2.7 opp=0) ==")
	print("target_px | body_px | armed | dir_dot")
	for td in [400, 600, 620, 700, 850, 1000, 1200]:
		for bd in [5000, 400, 320, 300, 220, 170]:
			var a = A.new()
			var target_pos = P0 + Vector2(1, 0) * float(td)
			var targets = [[target_pos, 60.0, false, 2]]
			var threats = []
			if bd < 5000:
				threats.push_back([P0 + Vector2(0, 1) * float(bd), Vector2.ZERO,
						14.0, 6.0, 1, 0.0, 1.6, 1e9, 0.0])
			var d = a.choose(P0, 320.0, BODY_R, FAR, threats, [], targets, [],
					300.0, false, 100.0, 1.0, {"kite_frac": 0.75})
			var dot = d.dot(Vector2(1, 0))
			print("%9d | %7d | %-5s | %+.2f" % [td, bd if bd < 5000 else -1,
					str(a.last_bounty), dot])

	print("")
	print("== goal (high-value walk-on reward, v2.6/v2.7 opp=0) ==")
	print("item_px | body_px | armed | dir_dot")
	for td in [300, 500, 700, 900, 1000]:
		for bd in [5000, 500, 400, 320, 300, 220, 170]:
			var a = A.new()
			var item_pos = P0 + Vector2(1, 0) * float(td)
			var rewards = [[item_pos, 9.0, false, 45.0, 1.0]]
			var threats = []
			if bd < 5000:
				threats.push_back([P0 + Vector2(0, 1) * float(bd), Vector2.ZERO,
						14.0, 6.0, 1, 0.0, 1.6, 1e9, 0.0])
			var d = a.choose(P0, 320.0, BODY_R, FAR, threats, rewards, [], [],
					300.0, false, 100.0, 1.0, {"kite_frac": 0.75})
			var dot = d.dot(Vector2(1, 0))
			print("%9d | %7d | %-5s | %+.2f" % [td, bd if bd < 5000 else -1,
					str(a.last_goal), dot])

	print("")
	print("== opp (v2.7 unified planner: class-1 special value 30, weapon_range 260) ==")
	var probe = A.new()
	if not ("opp_enable" in probe):
		print("FEATURE ABSENT: this arbiter has no --arb-opp layer (v2.6.1 baseline)")
		quit(0)
		return
	print("agg | target_px | body_px | geom      | armed | kind   | value | risk")
	for agg in [0, 1, 2]:
		for td in [620, 800, 1000]:
			for bd in [5000, 300, 250, 220, 170]:
				for geom in ["perp", "route"]:
					var a = A.new()
					# set the switches directly: apply_overrides would print the
					# whole weight set once per row (the sweep is deterministic,
					# and planner-selftest covers the --arb-opp CLI path itself).
					a.opp_enable = 1.0
					a.opp_agg = clamp(float(agg), 0.0, 2.0)
					var target_pos = P0 + Vector2(1, 0) * float(td)
					var threats = []
					if bd < 5000:
						var off = Vector2(0, 1) if geom == "perp" else Vector2(1, 0)
						threats.push_back([P0 + off * float(bd), Vector2.ZERO,
								14.0, 6.0, 1, 0.0, 1.6, 1e9, 0.0])
					var d = a.choose(P0, 320.0, BODY_R, FAR, threats, [],
							[[target_pos, 30.0, false, 1]], [], 260.0, false,
							100.0, 1.0, {"kite_frac": 0.75})
					print("%3d | %9d | %7d | %-9s | %-5s | %-6s | %5.0f | %5.1f" % [
							agg, td, bd if bd < 5000 else -1, geom,
							str(a.last_opp), a.last_opp_kind, a.last_opp_value,
							a.last_opp_risk])
	quit(0)
