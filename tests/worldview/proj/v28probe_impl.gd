extends Reference

# v2.8.0 world_view probe: class 1 (Boss) vs class 4 (Elite) split,
# produce reward tags (crate/legendary/evo/loot/tree), fire_wait_frames for the
# CD-synced tap, and the opt-in current_stats killability mode. Loads the LIVE
# world_view plus a PINNED v2.7.0 reference generated from git (`git show
# e933740:.../world_view.gd`) through the stub harness in tests/worldview/proj.
# Run: GODOT_BIN=... bash tests/worldview/run.sh

var fails = 0
var checks = 0
var h = null
var live = null
var ref = null
const P = Vector2(600, 600)


func approx(a, b, eps = 0.0000001):
	return abs(float(a) - float(b)) <= eps


func check(cond, what):
	checks += 1
	if cond:
		print("ok   " + what)
	else:
		fails += 1
		print("FAIL " + what)


func run():
	var hs = load("res://harness.gd")
	if hs == null:
		print("LOAD FAIL harness.gd")
		return 2
	h = hs.new()
	live = load("res://live_world_view.gd")
	ref = load("res://ref_v270_world_view.gd")
	print("=== v2.8 world_view probe ===")
	if live == null or ref == null:
		print("LOAD FAIL live/ref world_view (run.sh copies the pinned ref in)")
		return 2
	probe_class_split()
	probe_reward_tags()
	probe_fire_wait()
	probe_dpsref()
	probe_v27_exact()
	probe_control_arm()
	print("RESULT checks=%d fails=%d %s" % [checks, fails, "PASS" if fails == 0 else "FAIL"])
	return fails


func make_world(enemies = [], bosses = [], neutrals = [], consumables = []):
	var sp = h._new_spawner()
	for e in enemies:
		sp.enemies.push_back(e)
	for b in bosses:
		sp.bosses.push_back(b)
	for n in neutrals:
		sp.neutrals.push_back(n)
	var m = h._new_main(sp)
	m._consumables = consumables
	var p = h._new_player(P, 60.0, 100.0, 300.0)
	return [m, p]


func gather_with(script, overrides, main, player):
	# v2.9 (task-8): this probe's expectations are the v2.8.0 world_view contract.
	# The econ objective layer defaults to ON since v2.9 and intentionally changes
	# food/gold/tree/box pricing and appends a reward flags field, so the legacy
	# arms pin the exact v2.8.0 control arm here (the frozen ref ignores the key).
	# --arb-econ=1 is covered by the economy suite (tests/econ).
	var merged = {"econ": 0}
	if overrides is Dictionary:
		for k in overrides.keys():
			merged[k] = overrides[k]
	return h._gather(script, main, player, merged)


func target_at(view, pos):
	for t in view.targets:
		if t[0] == pos:
			return t
	return []


func reward_at(view, pos):
	for r in view.rewards:
		if r[0] == pos:
			return r
	return []


func probe_class_split():
	print("-- Boss class 1 vs Elite class 4 (cov=1) --")
	var boss_p = P + Vector2(500, 0)
	var elite_p = P + Vector2(500, 120)
	var boss = h._new_boss(boss_p, 800.0, 15.0)
	boss.is_elite = false
	var elite = h._new_boss(elite_p, 800.0, 15.0)
	elite.is_elite = true
	var w = make_world([], [boss, elite])
	var v_def = gather_with(live, {}, w[0], w[1])
	var tb = target_at(v_def, boss_p)
	var te = target_at(v_def, elite_p)
	check(tb.size() == 4 and int(tb[3]) == 1, "cov=1: Boss is class 1 (boss/elite target)")
	check(te.size() == 4 and int(te[3]) == 4, "cov=1: Elite is class 4 (split value class)")
	var v_cov0 = gather_with(live, {"cov": 0}, w[0], w[1])
	var tb0 = target_at(v_cov0, boss_p)
	var te0 = target_at(v_cov0, elite_p)
	check(tb0.size() == 4 and int(tb0[3]) == 1 and te0.size() == 4 and int(te0[3]) == 1,
			"cov=0: Boss and Elite both class 1 (exact v2.7.0)")
	var w_off = make_world([], [boss, elite])
	var v_off = gather_with(live, {"opp": 0}, w_off[0], w_off[1])
	var tbo = target_at(v_off, boss_p)
	var teo = target_at(v_off, elite_p)
	check(tbo.size() == 4 and int(tbo[3]) == 1 and teo.size() == 4 and int(teo[3]) == 1,
			"opp=0: both class 1 (exact v2.6.1)")


func probe_reward_tags():
	print("-- produce reward tags (index 6) --")
	h._set_camp(1.0, false, false, false)
	var crate_p = P + Vector2(150, 150)
	var leg_p = P + Vector2(250, 150)
	var evo_p = P + Vector2(350, 150)
	var fruit_p = P + Vector2(150, -150)
	var poison_p = P + Vector2(250, -150)
	var loot_p = P + Vector2(-300, 100)
	var tree_p = P + Vector2(-300, -100)
	var crate = h._new_consumable(crate_p, "consumable_item_box", true)
	var leg = h._new_consumable(leg_p, "consumable_legendary_item_box", true)
	var evo = h._new_consumable(evo_p, "meca_consumable_fruit", false)
	var fruit = h._new_consumable(fruit_p, "consumable_fruit", true)
	var poison = h._new_consumable(poison_p, "consumable_poisoned_fruit", false)
	var loot = h._new_enemy(loot_p, 6.0, 0.0)
	loot.is_loot = true
	var tree = h._new_enemy(tree_p, 30.0, 0.0)
	var w = make_world([loot], [], [tree], [crate, leg, evo, fruit, poison])
	# Full HP: the food value of a healing crate is a bank tie-breaker, so the
	# RAW reward value is the item-box price (5/10) exactly as v2.7.0.
	w[1].current_stats.health = 100.0
	var v = gather_with(live, {}, w[0], w[1])
	var rc = reward_at(v, crate_p)
	var rl = reward_at(v, leg_p)
	var re = reward_at(v, evo_p)
	var rloot = reward_at(v, loot_p)
	var rt = reward_at(v, tree_p)
	var rf = reward_at(v, fruit_p)
	check(rc.size() == 7 and int(rc[6]) == 1, "normal crate tagged 1 (7-field tuple)")
	check(rc.size() == 7 and float(rc[1]) == 5.0, "crate raw reward value still 5 (box pricing)")
	check(rl.size() == 7 and int(rl[6]) == 2, "legendary crate tagged 2")
	check(rl.size() == 7 and float(rl[1]) == 10.0, "legendary crate raw value still 10")
	check(re.size() == 7 and int(re[6]) == 3, "evolution item tagged 3 (walk-on preserved)")
	check(re.size() == 7 and float(re[4]) == 1.0, "evolution item r[4] walk-on marker preserved")
	check(rloot.size() == 7 and int(rloot[6]) == 4, "loot alien tagged 4")
	check(rloot.size() == 7 and typeof(rloot[5]) == TYPE_VECTOR2,
			"loot alien keeps velocity at index 5, tag at 6")
	check(rt.size() == 7 and int(rt[6]) == 5, "tree tagged 5")
	check(rf.size() == 2, "healing fruit stays untagged 2-field (raw food value)")
	check(reward_at(v, poison_p).empty(), "poisoned fruit still not a reward")

	var v_cov0 = gather_with(live, {"cov": 0}, w[0], w[1])
	check(reward_at(v_cov0, crate_p).size() == 2, "cov=0: crate back to 2-field v2.7.0 tuple")
	check(reward_at(v_cov0, tree_p).size() == 3, "cov=0: tree back to 3-field v2.7.0 tuple")
	check(reward_at(v_cov0, loot_p).size() == 6, "cov=0: loot back to 6-field v2.7.0 tuple")


func make_weapon(cd, stats = null, cur = null):
	var wscript = load("res://fixtures/fake_weapon.gd")
	var w = wscript.new()
	w._current_cooldown = float(cd)
	w.stats = stats if stats != null else load("res://fixtures/fake_weapon_stats.gd").new()
	w.current_stats = cur if cur != null else load("res://fixtures/fake_weapon_stats.gd").new()
	return w


func probe_fire_wait():
	print("-- fire_wait_frames (--arb-tapcd) --")
	var base = h._new_player(P, 60.0, 100.0, 300.0)
	var w0 = make_weapon(0)
	var w5 = make_weapon(5)
	var w60 = make_weapon(60)
	var m = h._new_main(h._new_spawner())
	base.current_weapons = [w0]
	var v0 = gather_with(live, {}, m, base)
	check(float(v0.fire_wait_frames) == 0.0, "weapon ready -> fire_wait_frames 0")
	base.current_weapons = [w5]
	var v5 = gather_with(live, {}, m, base)
	check(float(v5.fire_wait_frames) == 5.0, "5-frame cooldown -> fire_wait_frames 5")
	base.current_weapons = [w60, w5]
	var vmin = gather_with(live, {}, m, base)
	check(float(vmin.fire_wait_frames) == 5.0, "min over weapons (60,5) -> 5")
	base.current_weapons = []
	var vnone = gather_with(live, {}, m, base)
	check(float(vnone.fire_wait_frames) == -1.0, "no weapons -> fire_wait_frames -1")
	base.current_weapons = [w0]
	var voff = gather_with(live, {"tapcd": 0}, m, base)
	check(float(voff.fire_wait_frames) == -1.0, "tapcd=0 -> fire_wait_frames -1 (fixed cycle)")


func probe_dpsref():
	print("-- --arb-dpsref=2 current_stats killability --")
	var stats = load("res://fixtures/fake_weapon_stats.gd").new()
	stats.damage = 3.0
	stats.cooldown = 7.0
	stats.nb_projectiles = 1
	stats.max_range = 300.0
	var cur = load("res://fixtures/fake_weapon_stats.gd").new()
	cur.damage = 9.0
	cur.cooldown = 7.0
	cur.nb_projectiles = 2
	cur.max_range = 300.0
	var wk = make_weapon(0, stats, cur)
	var p = h._new_player(P, 60.0, 100.0, 300.0)
	p.current_weapons = [wk]
	var m = h._new_main(h._new_spawner())
	var v1 = gather_with(live, {}, m, p)
	var v2 = gather_with(live, {"dpsref": 2}, m, p)
	var k1 = float(v1._kill_ref)
	var k2 = float(v2._kill_ref)
	check(approx(k1, 25.714, 0.1), "dpsref=1 legacy base stats kill_ref ~25.7 (got %.1f)" % k1)
	check(approx(k2, 154.286, 0.1), "dpsref=2 live current_stats kill_ref ~154.3 (got %.1f)" % k2)
	var v0 = gather_with(live, {"dpsref": 0}, m, p)
	check(approx(float(v0._kill_ref), 20.0), "dpsref=0 static KILL_HP_REF stays 20")


func probe_v27_exact():
	print("-- cov=0 vs frozen v2.7.0 (e933740) with the same override set (tuples value-identical) --")
	h._set_camp(1.0, false, false, false)
	var sp = h._new_spawner()
	var boss = h._new_boss(P + Vector2(400, 0), 300.0, 10.0)
	boss.is_elite = true
	sp.bosses.push_back(boss)
	var egg = h._new_enemy(P + Vector2(520, 80), 40.0, 8.0)
	var egg_bh = load("res://stubs/class_spawning_attack_behavior.gd").new()
	egg._current_attack_behavior = egg_bh
	egg._attack_behavior = egg_bh
	sp.enemies.push_back(egg)
	var loot = h._new_enemy(P + Vector2(-260, 180), 6.0, 0.0)
	loot.is_loot = true
	sp.enemies.push_back(loot)
	var tree = h._new_enemy(P + Vector2(-260, -180), 30.0, 0.0)
	sp.neutrals.push_back(tree)
	var m = h._new_main(sp)
	m._consumables = [
		h._new_consumable(P + Vector2(200, 150), "consumable_item_box", true),
		h._new_consumable(P + Vector2(300, 150), "meca_consumable_fruit", false),
		h._new_consumable(P + Vector2(320, -150), "consumable_fruit", true),
	]
	var p = h._new_player(P, 60.0, 100.0, 300.0)
	var v_live = gather_with(live, {"cov": 0, "tapcd": 0}, m, p)
	var v_ref = gather_with(ref, {"cov": 0, "tapcd": 0}, m, p)
	check(h._deep_diff(v_live.targets, v_ref.targets, "targets") == "",
			"v2.7.0 exact (cov=0): targets identical to frozen v2.7.0")
	check(h._deep_diff(v_live.threats, v_ref.threats, "threats") == "",
			"v2.7.0 exact (cov=0): threats identical to frozen v2.7.0")
	check(h._deep_diff(v_live.rewards, v_ref.rewards, "rewards") == "",
			"v2.7.0 exact (cov=0): rewards identical to frozen v2.7.0")


func probe_control_arm():
	print("-- opp=0 vs frozen v2.7.0 (e933740) with the same override set (tuples value-identical) --")
	h._set_camp(1.0, false, false, false)
	var sp = h._new_spawner()
	var boss = h._new_boss(P + Vector2(400, 0), 300.0, 10.0)
	boss.is_elite = true
	sp.bosses.push_back(boss)
	var cursed = h._new_enemy(P + Vector2(500, 120), 40.0, 8.0)
	cursed.add_outline(Utils.CURSE_COLOR)
	sp.enemies.push_back(cursed)
	var loot = h._new_enemy(P + Vector2(-260, 180), 6.0, 0.0)
	loot.is_loot = true
	sp.enemies.push_back(loot)
	var tree = h._new_enemy(P + Vector2(-260, -180), 30.0, 0.0)
	sp.neutrals.push_back(tree)
	var m = h._new_main(sp)
	m._consumables = [
		h._new_consumable(P + Vector2(200, 150), "consumable_item_box", true),
		h._new_consumable(P + Vector2(300, 150), "meca_consumable_fruit", false),
		h._new_consumable(P + Vector2(320, -150), "consumable_fruit", true),
	]
	var p = h._new_player(P, 60.0, 100.0, 300.0)
	var v_live = gather_with(live, {"opp": 0}, m, p)
	var v_ref = gather_with(ref, {"opp": 0}, m, p)
	check(h._deep_diff(v_live.targets, v_ref.targets, "targets") == "",
			"opp=0 control arm targets identical to frozen v2.7.0")
	check(h._deep_diff(v_live.threats, v_ref.threats, "threats") == "",
			"opp=0 control arm threats identical to frozen v2.7.0")
	check(h._deep_diff(v_live.rewards, v_ref.rewards, "rewards") == "",
			"opp=0 control arm rewards identical to frozen v2.7.0")
