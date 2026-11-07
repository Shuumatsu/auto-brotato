extends SceneTree

# =============================================================================
# tests/contact/econ_dl_probe.gd -- v2.10.0 wave-end deadline unit probe.
#
# The round-7 bug had a second, independent root cause: the wave-end deadline
# factor was applied TWICE for the resources the horn takes away (LOST_AT_HORN
# evolution fruit, TREE): once inside economy.gd's price (price_consumable /
# price_tree) and again inside econ_planner._deadline. Near the horn that makes
# the planner value quadratic in the deadline factor (up to cap^2 = 9x), which
# let end-of-wave tree/fruit sweeps outbid the contact price and walk through
# bodies even on ordinary builds (real-game BOTLOG: tree value 14.02 for a
# base EV of ~3.0).
#
# This probe pins the fix with the real modules and pure data:
#   --arb-econdl=0 (shipped): planner value = base x deadline^1
#   --arb-econdl=1 (v2.9.1): planner value = base x deadline^2
# It checks both value classes (TREE and LOST_AT_HORN fruit) so a future change
# cannot silently move the deadline into the price again.
#
# Exit code = failures (0 = pass); run.sh additionally expects the RESULT line.
# =============================================================================

var checks = 0
var fails = 0


func check(cond, what):
	checks += 1
	if not cond:
		fails += 1
		print("CHECK_FAIL ", what)
	else:
		print("ok   ", what)


func approx(a, b, eps = 0.01):
	return abs(float(a) - float(b)) <= eps


func _ctx(wave_left):
	# Minimal pure-data ctx: the only live inputs price_tree / price_consumable
	# read for these classes are the wave clock, the item ETA and (for the
	# deadline) price_flags. No game state, no nodes.
	return {
		"effects": {},
		"missing_hp": 0.0,
		"max_hp": 10.0,
		"hp_ratio": 1.0,
		"wave": 5,
		"waves_total": 20,
		"wave_time_left": wave_left,
		"item_eta": 1.0,
		"price_flags": 0,
		"perm_effects": [],
		"hashes": {},
	}


func _planner_value(cfg, econ_mod, cand_value, flags, wave_left):
	var Epl = load("res://mods-unpacked/Pasha-AutoBattler/steering/econ_planner.gd")
	if Epl == null:
		return -1.0
	var planner = Epl.new()
	planner.apply_config(cfg)
	var dest = Vector2(320.0, 0.0)   # eta 1.0 s at speed 320
	var out = planner.update({
		"pos": Vector2.ZERO,
		"speed": 320.0,
		"hp_ratio": 1.0,
		"wave_time_left": wave_left,
		"threats": [],
		"candidates": [{"pos": dest, "value": cand_value, "flags": flags, "tag": 5}],
		"mitigation": 1.0,
		"body_radius": 21.0,
	})
	if out.empty():
		return 0.0
	return float(out.get("value", 0.0))


func _init():
	print("=== v2.10.0 wave-end deadline probe (economy.gd x econ_planner.gd) ===")
	var Cfg = load("res://mods-unpacked/Pasha-AutoBattler/steering/config.gd")
	var Econ = load("res://mods-unpacked/Pasha-AutoBattler/steering/economy.gd")
	var Contract = load("res://mods-unpacked/Pasha-AutoBattler/steering/contract.gd")
	if Cfg == null or Econ == null or Contract == null:
		print("RESULT econ_dl checks=0 fails=1 FAIL (modules did not load)")
		quit(1)
		return

	# -- shipped defaults -----------------------------------------------------
	var cfg_fixed = Cfg.new()
	cfg_fixed.parse({}, {})
	check(int(cfg_fixed.econ_dl) == 0, "default: econ_dl=0 (single deadline owner)")
	check(float(cfg_fixed.pull_safe) == 1.0, "default: pull_safe=1 (pull guard on)")

	# -- v2.9.1 control arm ---------------------------------------------------
	var cfg_legacy = Cfg.new()
	cfg_legacy.parse({}, {})
	cfg_legacy.override({"econdl": 1.0})
	check(int(cfg_legacy.econ_dl) == 1, "override: --arb-econdl=1 sets econ_dl (v2.9.1 arm)")

	var wave_left = 1.0
	var base_tree = 3.0          # TREE EV at these ctx values: 3 materials x 1.0
	var base_meca = 18.0         # economy EVO_VALUE
	var dl = 2.2                 # 1 + deadline_boost*(1 - wave_left/span) at these ctx values
	var ctx = _ctx(wave_left)

	var econ_fixed = Econ.new()
	econ_fixed.apply_config(cfg_fixed)
	var econ_legacy = Econ.new()
	econ_legacy.apply_config(cfg_legacy)
	check(approx(econ_fixed.deadline_in_price, 0.0), "fixed economy: deadline not in price")
	check(approx(econ_legacy.deadline_in_price, 1.0), "legacy economy: deadline in price (v2.9.1)")

	ctx["price_flags"] = Contract.ECON_TREE
	var tree_fixed = econ_fixed.price_tree(ctx)
	var tree_legacy = econ_legacy.price_tree(ctx)
	check(approx(tree_fixed, base_tree), "fixed: price_tree is the base EV %.2f (got %.2f)" %
			[base_tree, tree_fixed])
	check(approx(tree_legacy, base_tree * dl), "legacy: price_tree already carries deadline %.2f (got %.2f)" %
			[base_tree * dl, tree_legacy])

	var tree_planner_fixed = _planner_value(cfg_fixed, econ_fixed, tree_fixed,
			Contract.ECON_TREE, wave_left)
	var tree_planner_legacy = _planner_value(cfg_legacy, econ_legacy, tree_legacy,
			Contract.ECON_TREE, wave_left)
	check(approx(tree_planner_fixed, base_tree * dl),
			"fixed: planner tree value = base x deadline (%.2f, got %.2f)" %
			[base_tree * dl, tree_planner_fixed])
	check(approx(tree_planner_legacy, base_tree * dl * dl),
			"legacy: planner tree value = base x deadline^2 (%.2f, got %.2f)" %
			[base_tree * dl * dl, tree_planner_legacy])

	var meca_ctx = _ctx(wave_left)
	meca_ctx["price_flags"] = Contract.ECON_LOST_AT_HORN
	var meca_fixed = econ_fixed.price_consumable("meca", 0.0, meca_ctx)
	var meca_legacy = econ_legacy.price_consumable("meca", 0.0, meca_ctx)
	check(approx(meca_fixed, base_meca), "fixed: meca fruit price is EVO_VALUE %.2f (got %.2f)" %
			[base_meca, meca_fixed])
	var meca_planner_fixed = _planner_value(cfg_fixed, econ_fixed, meca_fixed,
			Contract.ECON_LOST_AT_HORN, wave_left)
	var meca_planner_legacy = _planner_value(cfg_legacy, econ_legacy, meca_legacy,
			Contract.ECON_LOST_AT_HORN, wave_left)
	check(approx(meca_planner_fixed, base_meca * dl),
			"fixed: planner meca value = EVO x deadline (%.2f, got %.2f)" %
			[base_meca * dl, meca_planner_fixed])
	check(approx(meca_planner_legacy, base_meca * dl * dl),
			"legacy: planner meca value = EVO x deadline^2 (%.2f, got %.2f)" %
			[base_meca * dl * dl, meca_planner_legacy])

	var verdict = "PASS" if fails == 0 else "FAIL"
	print("RESULT econ_dl checks=%d fails=%d %s" % [checks, fails, verdict])
	quit(0 if fails == 0 else 1)
