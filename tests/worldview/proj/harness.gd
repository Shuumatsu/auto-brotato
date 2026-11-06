extends Reference

# Offline self-test for the v2.4.0 world_view.gd DLC change (Brotato 1.2.0.1).
#
# Runs three copies of world_view.gd against the same fake world:
#   live  -- the working-tree file (copied in by run.sh): MUST pass everything
#   head  -- git HEAD (2.3.0, copied in by run.sh): must show the OLD behaviour
#            (no curse/evolved engagement, evolution items priced as food), which
#            proves the suite is sensitive to the feature actually existing
#   ref   -- a spec-conforming reference implementation kept beside this test in
#            proj/ref_world_view.gd: MUST pass everything. This is the harness
#            self-check: it proves the expectations are satisfiable per the
#            design doc, independent of whatever tactics-dev wrote.
#
# Everything is a hand-built fake (fixtures/): no game, no nodes in the scene
# tree, no mod source modified. World_view is instantiated directly and gather()
# is called with fake main / spawner / player / enemies / consumables.
#
# Tuple contract under test (design _research/dlc-v240-design.md v2.4.0):
#   threats  = [pos, vel, radius, damage, kind, start, ticks, end, (kill)]
#   targets  = [pos, kill_value, is_boss]
#   rewards  = [pos, value]                      food: rim = pickup_radius
#              [pos, value, false, EVO_WALK_RIM] evolution pickup: held rim 45
#   arbiter  _cost: r.size()>3 and r[3]>0 -> rim=r[3] + "inside the rim" bonus,
#                   else rim = pickup_radius if (r.size()<3 or r[2]) else 0.
#
# Output markers (consumed by run.sh):
#   CHECK_FAIL [target] ...
#   P2_NOTE ...
#   SUITE target name checks=N failures=M
#   SUMMARY target checks=N failures=M
#   SENSITIVITY ...
#   TEST RESULT: PASS|FAIL

const KIND_CONTACT = 1
const PICKUP_RADIUS = 150.0
const EVO_WALK_RIM = 45.0
const EPS = 1e-6

var target = ""
var failures = {}
var checks = {}
var p2notes = []

var _stats_script = load("res://fixtures/fake_stats.gd")
var _enemy_script = load("res://fixtures/fake_enemy.gd")
var _enemy_min_script = load("res://fixtures/fake_enemy_min.gd")
var _charmed_script = load("res://fixtures/fake_charmed_enemy.gd")
var _boss_script = load("res://fixtures/fake_boss.gd")
var _player_script = load("res://fixtures/fake_player.gd")
var _spawner_script = load("res://fixtures/fake_spawner.gd")
var _main_script = load("res://fixtures/fake_main.gd")
var _timer_script = load("res://fixtures/fake_wave_timer.gd")
var _consumable_script = load("res://fixtures/fake_consumable.gd")
var _consumable_data_script = load("res://fixtures/fake_consumable_data.gd")
var _effect_script = load("res://fixtures/fake_effect.gd")
var _gold_script = load("res://fixtures/fake_gold.gd")
var _character_script = load("res://fixtures/fake_character.gd")


func run() -> int:

	var head = _load_script("res://head_world_view.gd")
	if head == null:
		print("TEST RESULT: FAIL infra: res://head_world_view.gd missing (run.sh exports it)")
		return 1
	var live = _load_script("res://live_world_view.gd")
	var ref = _load_script("res://ref_world_view.gd")

	# HEAD must look exactly like the pre-change 2.3.0 script; if not, the
	# control-arm baseline is not a baseline and every comparison below is void.
	_set_target("head")
	_run_head_sensitivity(head)

	if ref != null:
		_set_target("ref")
		_run_control_arm(ref, head)
		_run_feature_suites(ref)
	else:
		print("NOTE res://ref_world_view.gd absent; suite sensitivity is proven separately by mutate.sh")

	if live != null:
		_set_target("live")
		_run_control_arm(live, head)
		_run_feature_suites(live)
	else:
		_set_target("live")
		_ok(false, "res://live_world_view.gd missing (run.sh copies the mod file)")

	var live_fail = int(failures.get("live", 0))
	var ref_fail = int(failures.get("ref", 0))
	var head_fail = int(failures.get("head", 0))
	for t in failures.keys():
		print("SUMMARY %s checks=%d failures=%d" % [t, int(checks.get(t, 0)), int(failures[t])])
	if p2notes.size() > 0:
		print("SUMMARY p2_notes=%d" % p2notes.size())
	if ref != null:
		print("SENSITIVITY harness_ok=" + ("true" if ref_fail == 0 else "false"))
	else:
		print("SENSITIVITY harness_ok=skipped (ref_world_view.gd absent; mutation self-check is the sensitivity gate)")
	var ok = live_fail == 0 and head_fail == 0 and ref_fail == 0
	print("TEST RESULT: " + ("PASS" if ok else "FAIL"))
	return 0 if ok else 1


# =============================================================================
# Harness plumbing
# =============================================================================

func _load_script(path: String):
	if not ResourceLoader.exists(path):
		return null
	var s = load(path)
	if s == null:
		return null
	return s


func _set_target(t: String) -> void:
	target = t
	if not failures.has(t):
		failures[t] = 0
		checks[t] = 0


func _ok(cond: bool, msg: String) -> bool:
	checks[target] = int(checks.get(target, 0)) + 1
	if not cond:
		failures[target] = int(failures.get(target, 0)) + 1
		print("CHECK_FAIL [%s] %s" % [target, msg])
	return cond


func _check_eq(a, b, msg: String) -> bool:
	return _ok(a == b, "%s (got %s, want %s)" % [msg, str(a), str(b)])


func _check_near(a: float, b: float, msg: String, eps: float = EPS) -> bool:
	return _ok(abs(a - b) <= eps, "%s (got %.9f, want %.9f)" % [msg, a, b])


func _p2(msg: String) -> void:
	p2notes.append(msg)
	print("P2_NOTE [%s] %s" % [target, msg])


func _suite(name: String, before_checks: int, before_fails: int) -> void:
	var d_checks = int(checks.get(target, 0)) - before_checks
	var d_fails = int(failures.get(target, 0)) - before_fails
	print("SUITE %s %s checks=%d failures=%d" % [target, name, d_checks, d_fails])


func _deep_diff(a, b, path: String) -> String:
	# Returns "" when a and b are value-identical, else a human-readable reason.
	var ta = typeof(a)
	var tb = typeof(b)
	if ta != tb:
		return "%s type %d vs %d" % [path, ta, tb]
	if ta == TYPE_ARRAY:
		if a.size() != b.size():
			return "%s size %d vs %d" % [path, a.size(), b.size()]
		for i in range(a.size()):
			var d = _deep_diff(a[i], b[i], "%s[%d]" % [path, i])
			if d != "":
				return d
		return ""
	if ta == TYPE_DICTIONARY:
		if a.size() != b.size():
			return "%s dict size %d vs %d" % [path, a.size(), b.size()]
		for k in a.keys():
			if not b.has(k):
				return "%s missing key %s" % [path, str(k)]
			var d2 = _deep_diff(a[k], b[k], "%s[%s]" % [path, str(k)])
			if d2 != "":
				return d2
		return ""
	if ta == TYPE_OBJECT:
		return "" if a == b else "%s object %s vs %s" % [path, str(a), str(b)]
	# int/real/Vector2/Color/String/bool all compare with == in GDScript 3.
	return "" if a == b else "%s %s vs %s" % [path, str(a), str(b)]


func _check_arrays_equal(tag: String, a: Array, b: Array) -> void:
	checks[target] = int(checks.get(target, 0)) + 1
	var d = _deep_diff(a, b, tag)
	if d == "":
		return
	failures[target] = int(failures.get(target, 0)) + 1
	print("CHECK_FAIL [%s] %s differs: %s" % [target, tag, d])
	print("  got  %s" % str(a))
	print("  want %s" % str(b))


# --- fixtures ---------------------------------------------------------------

func _new_stats(hp: float, dmg: float, spd: float = 0.0):
	var s = _stats_script.new()
	s.health = hp
	s.damage = dmg
	s.speed = spd
	return s


func _new_enemy(pos: Vector2, hp: float = 30.0, dmg: float = 8.0, spd: float = 0.0, script = null):
	var e = _enemy_script.new() if script == null else script.new()
	e.position = pos
	e.current_stats = _new_stats(hp, dmg, spd)
	return e


func _new_boss(pos: Vector2, hp: float = 800.0, dmg: float = 15.0):
	var b = _boss_script.new()
	b.position = pos
	b.current_stats = _new_stats(hp, dmg, 0.0)
	return b


func _new_player(pos: Vector2 = Vector2.ZERO, hp: float = 60.0, max_hp: float = 100.0, speed: float = 300.0):
	var p = _player_script.new()
	p.position = pos
	p.setup(hp, max_hp, speed)
	p.make_attract_area(PICKUP_RADIUS)
	return p


func _new_spawner():
	return _spawner_script.new()


func _new_main(spawner):
	var m = _main_script.new()
	m._entity_spawner = spawner
	var container = Node.new()
	container.name = "EnemyProjectiles"
	m.add_child(container)
	m._wave_timer = _timer_script.new()
	return m


func _new_consumable(pos: Vector2, my_id: String = "", healing: bool = false, effects: Array = []):
	var c = _consumable_script.new()
	c.position = pos
	c.healing = healing
	if my_id != "":
		var d = _consumable_data_script.new()
		d.setup(my_id, effects)
		c.consumable_data = d
	return c


func _new_effect(key: String, value: int):
	var e = _effect_script.new()
	e.key = key
	e.value = value
	e.key_hash = Keys.generate_hash(key)
	return e


func _new_gold(pos: Vector2):
	var g = _gold_script.new()
	g.position = pos
	return g


func _gather(W, main, player, overrides: Dictionary):
	if RunData.player_character == null:
		RunData.player_character = _character_script.new()
	var v = W.new()
	if overrides.size() > 0:
		v.apply_overrides(overrides)
	v.gather(main, player)
	return v


func _target_value(view, pos: Vector2) -> float:
	for t in view.targets:
		if t[0] == pos:
			return float(t[1])
	_ok(false, "no target tuple at %s" % str(pos))
	return -9999.0


func _threat_damage(view, pos: Vector2) -> float:
	for th in view.threats:
		if th[0] == pos and th.size() >= 8 and int(th[4]) == KIND_CONTACT:
			return float(th[3])
	_ok(false, "no contact threat tuple at %s" % str(pos))
	return -9999.0


func _reward_at(view, pos: Vector2) -> Array:
	for r in view.rewards:
		if r[0] == pos:
			return r
	return []


func _rim_of(r: Array, pickup_radius: float) -> float:
	# Mirror of arbiter.gd _cost (arbiter.gd:1671-1672).
	if r.size() > 3 and float(r[3]) > 0.0:
		return float(r[3])
	if r.size() < 3 or bool(r[2]):
		return pickup_radius
	return 0.0


func _semantic_rewards(view) -> Array:
	# Score-equivalent projection: zero-value rewards can never change the
	# arbiter's score (gain is multiplied by r[1]), so dropping them lets the
	# control arm compare "what the arbiter sees" rather than dead entries.
	var out = []
	for r in view.rewards:
		var val = float(r[1])
		if val == 0.0:
			continue
		out.append([r[0], val, _rim_of(r, float(view.pickup_radius))])
	return out


# =============================================================================
# HEAD sensitivity: prove the suite would catch a no-op implementation
# =============================================================================

func _run_head_sensitivity(head) -> void:
	var before_c = int(checks.get(target, 0))
	var before_f = int(failures.get(target, 0))
	var w = _build_curse_world()
	var hv = _gather(head, w.main, w.player, {"charprofile": 0})
	_check_near(_target_value(hv, Vector2(-300, 0)), _target_value(hv, Vector2(300, 0)),
			"HEAD: cursed enemy priced like a plain one (no engage multiplier)")
	_check_eq(_threat_damage(hv, Vector2(-300, 0)), 8.0,
			"HEAD: cursed contact damage unchanged")
	_ok(not ("curse_mult" in hv), "HEAD: no curse_mult member (pre-change script)")
	_ok(not ("evo_mult" in hv), "HEAD: no evo_mult member (pre-change script)")

	var ew = _build_evo_world()
	var ev = _gather(head, ew.main, ew.player, {"charprofile": 0})
	var r = _reward_at(ev, Vector2(100, 0))
	_check_eq(r.size(), 2, "HEAD: evolution fruit reward is a plain 2-field food tuple")
	if r.size() == 2:
		_check_near(float(r[1]), 30.0, "HEAD: evolution fruit priced by _food_value (as food)")
	_suite("head_sensitivity", before_c, before_f)


# =============================================================================
# Control arm: with --arb-curse=0 --arb-evolved=0 --arb-evo=0 the new script
# must produce the same threats / targets / rewards as HEAD on the same fake
# non-DLC world (score-equivalent for zero-value reward entries).
# =============================================================================

func _run_control_arm(W, head) -> void:
	var before_c = int(checks.get(target, 0))
	var before_f = int(failures.get(target, 0))

	# --- hurt player: every consumable has a non-zero food value -> the
	# --- control arm must be byte-identical on all three arrays.
	var w = _build_control_world(60.0, 100.0)
	var hv = _gather(head, w.main, w.player, {"charprofile": 0})
	var lv = _gather(W, w.main, w.player,
			{"charprofile": 0, "curse": 0, "evolved": 0, "evo": 0})
	_check_arrays_equal("control_hurt threats", lv.threats, hv.threats)
	_check_arrays_equal("control_hurt targets", lv.targets, hv.targets)
	_check_arrays_equal("control_hurt rewards", lv.rewards, hv.rewards)

	# DLC switches at their defaults must be inert on a world with no DLC
	# entities/consumables (detection false -> multipliers never applied).
	var dv = _gather(W, w.main, w.player, {"charprofile": 0})
	_check_arrays_equal("control_defaults threats", dv.threats, lv.threats)
	_check_arrays_equal("control_defaults targets", dv.targets, lv.targets)
	_check_arrays_equal("control_defaults rewards", dv.rewards, lv.rewards)

	# --- full-HP player: food value is 0.0. HEAD still pushes [pos, 0.0] dead
	# --- entries; the v2.4.0 script skips zero-value consumables (design §3.4
	# --- `if v != 0.0`). Zero-value entries are score-neutral, so the control
	# --- arm is compared on the score-equivalent projection.
	var w2 = _build_control_world(100.0, 100.0)
	var hv2 = _gather(head, w2.main, w2.player, {"charprofile": 0})
	var lv2 = _gather(W, w2.main, w2.player,
			{"charprofile": 0, "curse": 0, "evolved": 0, "evo": 0})
	_check_arrays_equal("control_fullhp threats", lv2.threats, hv2.threats)
	_check_arrays_equal("control_fullhp targets", lv2.targets, hv2.targets)
	_check_arrays_equal("control_fullhp rewards_score_equiv",
			_semantic_rewards(lv2), _semantic_rewards(hv2))
	var dead_entries = 0
	for r in hv2.rewards:
		if float(r[1]) == 0.0:
			dead_entries += 1
	if dead_entries > 0:
		_p2("HEAD pushed %d zero-value food reward(s) at full HP; new code drops them (score-neutral, design §3.4)" % dead_entries)

	# --- DLC world with the pickups switched off: evo=0 must run the old
	# --- food-only line VERBATIM, so a floor full of evolution consumables (and
	# --- of non-healing DLC consumables) must produce exactly HEAD's rewards.
	# --- This is the strongest control-arm check: it covers the new classifier's
	# --- off-switch on the very content class the feature adds.
	var w3 = _build_evo_world()
	var hv3 = _gather(head, w3.main, w3.player, {"charprofile": 0})
	var lv3 = _gather(W, w3.main, w3.player,
			{"charprofile": 0, "curse": 0, "evolved": 0, "evo": 0})
	_check_arrays_equal("control_dlcworld threats", lv3.threats, hv3.threats)
	_check_arrays_equal("control_dlcworld targets", lv3.targets, hv3.targets)
	_check_arrays_equal("control_dlcworld rewards", lv3.rewards, hv3.rewards)
	_suite("control_arm", before_c, before_f)


# =============================================================================
# Control-arm fake world: no DLC entities, no evolution consumables.
# =============================================================================

func _build_control_world(hp: float, max_hp: float):
	var player = _new_player(Vector2.ZERO, hp, max_hp)
	var spawner = _new_spawner()
	var loot = _new_enemy(Vector2(60, 0), 10.0, 5.0)
	loot.is_loot = true
	spawner.enemies = [
		_new_enemy(Vector2(150, 0), 30.0, 8.0, 120.0),
		_new_enemy(Vector2(400, 100), 100.0, 10.0, 150.0),
		_new_enemy(Vector2(2000, 0), 50.0, 10.0, 100.0),   # beyond THREAT_RANGE
		loot,
	]
	spawner.bosses = [_new_boss(Vector2(500, -200))]
	spawner.neutrals = []
	spawner.pets = []
	var main = _new_main(spawner)
	main._consumables = [
		_new_consumable(Vector2(100, 50), "consumable_fruit", true),
		_new_consumable(Vector2(-120, 80), "consumable_item_box", true),
		_new_consumable(Vector2(700, -300), "consumable_legendary_item_box", true),
	]
	main._active_golds = [_new_gold(Vector2(80, -60)), _new_gold(Vector2(300, 300))]
	return {"main": main, "player": player}


# =============================================================================
# Curse / evolved engagement
# =============================================================================

func _build_curse_world():
	var player = _new_player(Vector2.ZERO, 60.0, 100.0)
	var spawner = _new_spawner()
	var plain = _new_enemy(Vector2(300, 0))
	var cursed = _new_enemy(Vector2(-300, 0))
	cursed.add_outline(Utils.CURSE_COLOR)
	var meca = _new_enemy(Vector2(0, 300))
	meca._is_meca = true
	meca.add_outline(Utils.MECA_COLOR)
	var mutant = _new_enemy(Vector2(0, -300))
	mutant._is_mutant = true
	mutant.add_outline(Utils.MUTANT_COLOR)
	var both = _new_enemy(Vector2(0, 550))
	both.add_outline(Utils.CURSE_COLOR)
	both._is_meca = true
	var boss_plain = _new_boss(Vector2(500, 0))
	var boss_cursed = _new_boss(Vector2(-500, 0))
	boss_cursed.add_outline(Utils.CURSE_COLOR)
	spawner.enemies = [plain, cursed, meca, mutant, both]
	spawner.bosses = [boss_plain, boss_cursed]
	spawner.neutrals = []
	spawner.pets = []
	var main = _new_main(spawner)
	main._consumables = []
	main._active_golds = []
	return {"main": main, "player": player}


func _run_curse_suite(W) -> void:
	var before_c = int(checks.get(target, 0))
	var before_f = int(failures.get(target, 0))
	var w = _build_curse_world()
	var P = Vector2(300, 0)       # plain
	var C = Vector2(-300, 0)      # cursed
	var M = Vector2(0, 300)       # meca evolved
	var U = Vector2(0, -300)      # mutant evolved
	var B = Vector2(0, 550)       # cursed + meca
	var BP = Vector2(500, 0)      # boss plain
	var BC = Vector2(-500, 0)     # boss cursed

	# --- D1: new defaults (curse x3, evolved x2.5), no override needed.
	var v = _gather(W, w.main, w.player, {"charprofile": 0})
	var base = _target_value(v, P)
	_check_near(_target_value(v, C), 3.0 * base, "curse=3 engage: cursed target value x3")
	_check_near(_target_value(v, M), 2.5 * base, "evolved default: meca target value x2.5")
	_check_near(_target_value(v, U), 2.5 * base, "evolved default: mutant target value x2.5")
	_check_near(_target_value(v, B), 3.0 * 2.5 * base,
			"curse=3 + evolved=2.5 engage multipliers multiply")
	_check_eq(_threat_damage(v, C), 8.0, "engage does not scale threat damage")
	_check_eq(_threat_damage(v, B), 8.0, "combined engage does not scale threat damage")
	_check_near(_target_value(v, BC), _target_value(v, BP),
			"boss: engage multiplier not applied to target value")
	_check_eq(_threat_damage(v, BC), 15.0, "boss: engage does not scale threat damage")

	# --- D2: exact 2.3.0 numbers with the control arm.
	v = _gather(W, w.main, w.player, {"charprofile": 0, "curse": 0, "evolved": 0, "evo": 0})
	base = _target_value(v, P)
	_check_eq(_target_value(v, C), base, "curse=0: cursed target value equals plain")
	_check_eq(_target_value(v, M), base, "evolved=0: meca target value equals plain")
	_check_eq(_target_value(v, U), base, "evolved=0: mutant target value equals plain")
	_check_eq(_target_value(v, B), base, "curse=0/evolved=0: both-flags target equals plain")
	_check_eq(_threat_damage(v, C), 8.0, "curse=0: threat damage unchanged")
	_check_eq(_threat_damage(v, M), 8.0, "evolved=0: threat damage unchanged")
	_check_eq(_target_value(v, BC), _target_value(v, BP),
			"curse=0: boss target value unchanged")

	# --- D3: avoid curse=-1: target value 0, threat damage x2.
	v = _gather(W, w.main, w.player, {"charprofile": 0, "curse": -1, "evolved": 0, "evo": 0})
	base = _target_value(v, P)
	_check_eq(_target_value(v, C), 0.0, "curse=-1 avoid: cursed target value 0")
	_check_eq(_threat_damage(v, C), 16.0, "curse=-1 avoid: threat damage x2")
	_check_eq(_target_value(v, B), 0.0, "curse=-1 avoid wins over evolved: both-flags value 0")
	_check_eq(_threat_damage(v, B), 16.0, "curse=-1 avoid: both-flags threat damage x2")
	_check_eq(_target_value(v, M), base, "curse=-1 does not touch uncursed evolved target")
	_check_eq(_target_value(v, BC), _target_value(v, BP),
			"curse=-1 avoid: boss target value unchanged (engage/avoid gate)")
	_check_eq(_threat_damage(v, BC), 30.0, "curse=-1 avoid: boss threat damage x2")
	if _target_value(v, BC) == 0.0:
		_p2("boss avoid zeroed the boss target value; design §3.3 gates target modifiers on `not unit is Boss`")

	# --- D4: avoid scaling is (1+|v|): curse=-2 -> threat damage x3.
	v = _gather(W, w.main, w.player, {"charprofile": 0, "curse": -2, "evolved": 0, "evo": 0})
	_check_eq(_target_value(v, C), 0.0, "curse=-2 avoid: cursed target value 0")
	_check_eq(_threat_damage(v, C), 24.0, "curse=-2 avoid: threat damage x3")

	# --- D5: evolved avoid.
	v = _gather(W, w.main, w.player, {"charprofile": 0, "curse": 0, "evolved": -1, "evo": 0})
	base = _target_value(v, P)
	_check_eq(_target_value(v, M), 0.0, "evolved=-1 avoid: meca target value 0")
	_check_eq(_threat_damage(v, M), 16.0, "evolved=-1 avoid: meca threat damage x2")
	_check_eq(_target_value(v, U), 0.0, "evolved=-1 avoid: mutant target value 0")
	_check_eq(_threat_damage(v, U), 16.0, "evolved=-1 avoid: mutant threat damage x2")
	_check_eq(_target_value(v, B), 0.0, "evolved=-1 avoid: both-flags value 0")
	_check_eq(_threat_damage(v, B), 16.0, "evolved=-1 avoid: both-flags threat damage x2")
	_check_eq(_target_value(v, C), base, "evolved=-1 does not touch uncursed plain target")

	# --- D6: combined engage multipliers.
	v = _gather(W, w.main, w.player, {"charprofile": 0, "curse": 2, "evolved": 3, "evo": 0})
	base = _target_value(v, P)
	_check_near(_target_value(v, B), 6.0 * base, "curse=2 x evolved=3: both-flags target value x6")
	_check_near(_target_value(v, C), 2.0 * base, "curse=2: cursed target value x2")

	# --- D7: combined avoid scales multiply: (-1) -> x2, (-2) -> x3.
	v = _gather(W, w.main, w.player, {"charprofile": 0, "curse": -1, "evolved": -2, "evo": 0})
	base = _target_value(v, P)
	_check_eq(_target_value(v, B), 0.0, "combined avoid: both-flags target value 0")
	_check_eq(_threat_damage(v, B), 48.0, "combined avoid: threat damage x2 * x3")
	_check_eq(_target_value(v, M), 0.0, "evolved=-2 avoid: meca target value 0")
	_check_eq(_threat_damage(v, M), 24.0, "evolved=-2 avoid: meca threat damage x3")
	_check_eq(_target_value(v, P), base, "plain enemy unaffected by DLC switches")

	# --- helper shape (soft: design names _avoid_scale but behaviour is what
	# --- matters; flag a name deviation as P2 only).
	var hv = W.new()
	if hv.has_method("_avoid_scale"):
		_check_eq(hv._avoid_scale(0.0), 1.0, "_avoid_scale(0) == 1")
		_check_eq(hv._avoid_scale(0.5), 1.0, "_avoid_scale(positive) == 1")
		_check_eq(hv._avoid_scale(-1.0), 2.0, "_avoid_scale(-1) == 2")
		_check_eq(hv._avoid_scale(-2.0), 3.0, "_avoid_scale(-2) == 3")
	else:
		_p2("_avoid_scale helper missing (design §3.3); behaviour tested via gather()")
	if hv.has_method("_enemy_is_cursed"):
		_ok(_enemy_cursed_probe(hv, w, C), "_enemy_is_cursed true for outline ca61ff")
		_ok(not _enemy_cursed_probe(hv, w, P), "_enemy_is_cursed false without outline")
	else:
		_p2("_enemy_is_cursed helper missing (design §3.2)")
	if hv.has_method("_enemy_is_evolved"):
		_ok(_enemy_evolved_probe(hv, w, M), "_enemy_is_evolved true for _is_meca")
		_ok(_enemy_evolved_probe(hv, w, U), "_enemy_is_evolved true for _is_mutant")
		_ok(not _enemy_evolved_probe(hv, w, P), "_enemy_is_evolved false for plain enemy")
	else:
		_p2("_enemy_is_evolved helper missing (design §3.2)")
	_suite("curse_evolved", before_c, before_f)


func _enemy_cursed_probe(view, world, pos: Vector2) -> bool:
	for e in world.main._entity_spawner.enemies:
		if e.position == pos:
			return bool(view._enemy_is_cursed(e))
	return false


func _enemy_evolved_probe(view, world, pos: Vector2) -> bool:
	for e in world.main._entity_spawner.enemies:
		if e.position == pos:
			return bool(view._enemy_is_evolved(e))
	return false


# =============================================================================
# Evolution consumables: classification, eligibility, camp direction, rim
# =============================================================================

const EVO_POS = {
	"meca_fruit": Vector2(100, 0),
	"mutant_fruit": Vector2(100, 100),
	"mutation_fruit": Vector2(100, 200),
	"meca_parts": Vector2(100, 300),
	"plain_fruit": Vector2(100, 400),
	"item_box": Vector2(100, -300),
	"poisoned_fruit": Vector2(100, -100),
	"mystery": Vector2(100, -200),
}


func _build_evo_world():
	var player = _new_player(Vector2.ZERO, 60.0, 100.0)
	var spawner = _new_spawner()
	spawner.enemies = []
	spawner.bosses = []
	spawner.neutrals = []
	spawner.pets = []
	var main = _new_main(spawner)
	main._consumables = [
		_new_consumable(EVO_POS["meca_fruit"], "meca_consumable_fruit", false),
		_new_consumable(EVO_POS["mutant_fruit"], "mutant_consumable_fruit", false),
		_new_consumable(EVO_POS["mutation_fruit"], "mutation_consumable_fruit", false),
		_new_consumable(EVO_POS["meca_parts"], "meca_parts_consumable", false),
		_new_consumable(EVO_POS["plain_fruit"], "consumable_fruit", true),
		_new_consumable(EVO_POS["item_box"], "consumable_item_box", true),
		_new_consumable(EVO_POS["poisoned_fruit"], "consumable_poisoned_fruit", false),
		_new_consumable(EVO_POS["mystery"], "consumable_mystery_thing", false),
	]
	main._active_golds = []
	return {"main": main, "player": player}


func _set_camp(evolution: float, meca_only: bool, mutant_only: bool, dual: bool) -> void:
	RunData.effects = {}
	RunData.effects[Keys.stat_evolution_hash] = evolution
	RunData.effects[Keys.meca_only_hash] = 1 if meca_only else 0
	RunData.effects[Keys.mutant_only_hash] = 1 if mutant_only else 0
	RunData.effects[Keys.dual_evolution_hash] = 1 if dual else 0


func _check_evo_reward(view, kind: String, want_value: float, ctx: String) -> void:
	var pos = EVO_POS[kind]
	var r = _reward_at(view, pos)
	if want_value < 0.0:
		_check_eq(r.size(), 0, "%s: %s has no reward (value 0)" % [ctx, kind])
		return
	if not _check_eq(r.size(), 4, "%s: %s reward tuple is 4-field held form" % [ctx, kind]):
		return
	_check_near(float(r[1]), want_value, "%s: %s value" % [ctx, kind], 1e-4)
	_ok(not bool(r[2]), "%s: %s third field false" % [ctx, kind])
	_check_near(float(r[3]), EVO_WALK_RIM, "%s: %s held rim == EVO_WALK_RIM" % [ctx, kind])


func _check_food_reward(view, kind: String, want_value: float, ctx: String) -> void:
	var pos = EVO_POS[kind]
	var r = _reward_at(view, pos)
	if not _check_eq(r.size(), 2, "%s: %s reward tuple stays 2-field [pos, value]" % [ctx, kind]):
		return
	_check_near(float(r[1]), want_value, "%s: %s food value" % [ctx, kind], 1e-4)


func _evo_case(W, world, ctx: String, evolution: float, meca_only: bool, mutant_only: bool, dual: bool,
		overrides: Dictionary, expect: Dictionary) -> void:
	_set_camp(evolution, meca_only, mutant_only, dual)
	var v = _gather(W, world.main, world.player, overrides)
	for kind in expect.keys():
		_check_evo_reward(v, kind, float(expect[kind]), ctx)
	# Food path must be identical regardless of the DLC switches (control arm).
	_check_food_reward(v, "plain_fruit", 30.0, ctx)
	_check_food_reward(v, "item_box", 30.0, ctx)
	# Non-healing, non-evolution DLC/unknown consumables are not food.
	_check_eq(_reward_at(v, EVO_POS["poisoned_fruit"]).size(), 0,
			"%s: non-healing poisoned fruit not priced as food" % ctx)
	_check_eq(_reward_at(v, EVO_POS["mystery"]).size(), 0,
			"%s: unknown non-healing consumable not priced as food" % ctx)


func _run_evo_suite(W) -> void:
	var before_c = int(checks.get(target, 0))
	var before_f = int(failures.get(target, 0))
	var world = _build_evo_world()
	var base_overrides = {"charprofile": 0, "curse": 0, "evolved": 0, "evo": 1}

	# --- E1: all four classified, base values. A dual-evolution kit at
	# --- evolution=+1 is the only state where the GAME lets all four be picked
	# --- up (RunData.can_pick_up_consumable gates mutation fruit / meca parts on
	# --- a camp side; dual + evolution != 0 relaxes that).
	_evo_case(W, world, "evo=1 dual", 1.0, false, false, true, base_overrides, {
		"meca_fruit": 6.0, "mutant_fruit": 6.0, "mutation_fruit": 9.0, "meca_parts": 6.0})

	# --- E2: evo multiplier scales every evolution pickup value.
	_evo_case(W, world, "evo=2 dual", 1.0, false, false, true,
			{"charprofile": 0, "curse": 0, "evolved": 0, "evo": 2}, {
		"meca_fruit": 12.0, "mutant_fruit": 12.0,
		"mutation_fruit": 18.0, "meca_parts": 12.0})

	# --- E3: evo=0 is the EXACT v2.3.0 control arm: gather() runs the old
	# --- food-only line verbatim (same 2-field tuple, _food_value for every
	# --- consumable, evolution classifier never consulted). This is stronger
	# --- than the design-doc §3.4 "-> 0" wording and is checked against HEAD
	# --- in the control-arm suite; here we pin the values directly.
	_set_camp(1.0, false, false, true)
	var v0 = _gather(W, world.main, world.player,
			{"charprofile": 0, "curse": 0, "evolved": 0, "evo": 0})
	for kind in EVO_POS.keys():
		var r0 = _reward_at(v0, EVO_POS[kind])
		_check_eq(r0.size(), 2, "evo=0: %s keeps the old 2-field food tuple" % kind)
		if r0.size() == 2:
			_check_near(float(r0[1]), 30.0, "evo=0: %s priced by old _food_value" % kind)

	# --- E4: can_pick_up_consumable false -> value 0.
	RunData.can_pick_override = false
	_set_camp(0.0, false, false, false)
	var v = _gather(W, world.main, world.player, base_overrides)
	for kind in ["meca_fruit", "mutant_fruit", "mutation_fruit", "meca_parts"]:
		_check_eq(_reward_at(v, EVO_POS[kind]).size(), 0,
				"can_pick_up_consumable=false: %s skipped" % kind)
	RunData.can_pick_override = null

	# --- E5: camp-direction matrix (evolution sign / meca_only / mutant_only / dual).
	# evolution > 0 (meca side): meca fruit + parts yes, mutant fruit + mutation no.
	_evo_case(W, world, "evolution=+1", 1.0, false, false, false, base_overrides, {
		"meca_fruit": 6.0, "mutant_fruit": -1.0, "mutation_fruit": -1.0, "meca_parts": 6.0})
	# evolution == 0: both fruits eligible, parts/mutation need a side.
	_evo_case(W, world, "evolution=0", 0.0, false, false, false, base_overrides, {
		"meca_fruit": 6.0, "mutant_fruit": 6.0, "mutation_fruit": -1.0, "meca_parts": -1.0})
	# evolution < 0 (mutant side): mutant fruit + mutation yes, meca fruit + parts no.
	_evo_case(W, world, "evolution=-1", -1.0, false, false, false, base_overrides, {
		"meca_fruit": -1.0, "mutant_fruit": 6.0, "mutation_fruit": 9.0, "meca_parts": -1.0})
	# beyond the camp lock (|evolution| > 2): game gate blocks the far fruit.
	_evo_case(W, world, "evolution=+3", 3.0, false, false, false, base_overrides, {
		"meca_fruit": 6.0, "mutant_fruit": -1.0, "mutation_fruit": -1.0, "meca_parts": 6.0})
	# meca-only kit.
	_evo_case(W, world, "meca_only", 1.0, true, false, false, base_overrides, {
		"meca_fruit": 6.0, "mutant_fruit": -1.0, "mutation_fruit": -1.0, "meca_parts": 6.0})
	# mutant-only kit.
	_evo_case(W, world, "mutant_only", -1.0, false, true, false, base_overrides, {
		"meca_fruit": -1.0, "mutant_fruit": 6.0, "mutation_fruit": 9.0, "meca_parts": -1.0})
	# dual evolution: both camps open.
	_evo_case(W, world, "dual", 1.0, false, false, true, base_overrides, {
		"meca_fruit": 6.0, "mutant_fruit": 6.0, "mutation_fruit": 9.0, "meca_parts": 6.0})
	# dual + evolution == 0: fruits still allowed (game rule), parts/mutation not.
	_evo_case(W, world, "dual_evolution0", 0.0, false, false, true, base_overrides, {
		"meca_fruit": 6.0, "mutant_fruit": 6.0, "mutation_fruit": -1.0, "meca_parts": -1.0})

	# --- E6: fallback classification by effect key when the id hash is unknown
	# --- (design §3.4 step 2: effect.key == "stat_evolution" / "meca_parts").
	var fw = _build_evo_world()
	fw.main._consumables = [
		_new_consumable(Vector2(50, 0), "weird_meca_fruit",
				false, [_new_effect("stat_evolution", 1)]),
		_new_consumable(Vector2(50, 60), "weird_mutant_fruit",
				false, [_new_effect("stat_evolution", -1)]),
		_new_consumable(Vector2(50, 120), "weird_meca_parts",
				false, [_new_effect("meca_parts", 2)]),
	]
	_set_camp(0.0, false, false, false)
	var fv = _gather(W, fw.main, fw.player, base_overrides)
	var fb_meca = _reward_at(fv, Vector2(50, 0))
	_check_eq(fb_meca.size(), 4, "effect-fallback: stat_evolution +1 classified as evolution item")
	if fb_meca.size() == 4:
		_check_near(float(fb_meca[1]), 6.0, "effect-fallback: stat_evolution +1 valued as meca fruit")
	var fb_mut = _reward_at(fv, Vector2(50, 60))
	_check_eq(fb_mut.size(), 4, "effect-fallback: stat_evolution -1 classified as evolution item")
	if fb_mut.size() == 4:
		_check_near(float(fb_mut[1]), 6.0, "effect-fallback: stat_evolution -1 valued as mutant fruit")
	var fb_parts = _reward_at(fv, Vector2(50, 120))
	_check_eq(fb_parts.size(), 4, "effect-fallback: meca_parts effect classified as evolution item")
	if fb_parts.size() == 4:
		_check_near(float(fb_parts[1]), 6.0, "effect-fallback: meca_parts effect valued as parts")

	# --- E7: null consumable_data / missing fields must not crash.
	var nw = _build_evo_world()
	var nullc = _new_consumable(Vector2(30, -30))
	nullc.consumable_data = null
	var emptyc = _new_consumable(Vector2(30, -60), "consumable_mystery_thing", false)
	nw.main._consumables = [nullc, emptyc]
	_set_camp(0.0, false, false, false)
	var nv = _gather(W, nw.main, nw.player, base_overrides)
	_check_eq(nv.rewards.size(), 0, "null/unknown consumable_data -> no rewards, no crash")

	# --- E8: pickup range still gates evolution items.
	var rw = _build_evo_world()
	var far = _new_consumable(Vector2(0, 1000), "meca_consumable_fruit", false)
	rw.main._consumables = [far]
	_set_camp(0.0, false, false, false)
	var rv = _gather(W, rw.main, rw.player, base_overrides)
	_check_eq(rv.rewards.size(), 0, "evolution item outside PICKUP_RANGE ignored")

	# --- E9: helper shape (soft).
	var hv = W.new()
	for meth in ["_consumable_value", "_consumable_is_food", "_evolution_consumable_kind",
			"_evolution_direction_ok", "_evolution_base_value"]:
		if not hv.has_method(meth):
			_p2("helper %s missing (design §3.4 names it)" % meth)
	_suite("evolution_pickups", before_c, before_f)


# =============================================================================
# Robustness: absent/damaged game fields must not crash gather()
# =============================================================================

func _run_robustness_suite(W) -> void:
	var before_c = int(checks.get(target, 0))
	var before_f = int(failures.get(target, 0))
	RunData.can_pick_override = null
	_set_camp(0.0, false, false, false)

	var player = _new_player(Vector2.ZERO, 100.0, 100.0, 1.0)   # min speed / full HP
	var spawner = _new_spawner()
	var bare = _enemy_min_script.new()
	bare.position = Vector2(200, 0)
	# current_stats stays null: default damage/health path.
	var dead_e = _new_enemy(Vector2(250, 0))
	dead_e.dead = true
	var dying_e = _new_enemy(Vector2(-250, 0))
	dying_e._pending_die = true
	var charmed = _charmed_script.new()
	charmed.position = Vector2(0, 250)
	charmed.current_stats = _new_stats(30.0, 8.0)
	spawner.enemies = [bare, dead_e, dying_e, charmed]
	spawner.bosses = []
	spawner.neutrals = []
	spawner.pets = []
	var main = _new_main(spawner)
	var nullc = _new_consumable(Vector2(40, 40))
	nullc.consumable_data = null
	var emptyc = _new_consumable(Vector2(40, 80), "consumable_mystery_thing", false)
	main._consumables = [nullc, emptyc]
	main._active_golds = []

	var v = _gather(W, main, player, {"charprofile": 0, "curse": -1, "evolved": -1, "evo": 1})
	_check_eq(v.targets.size(), 1, "only live non-charmed enemies are targets")
	if v.targets.size() == 1:
		_check_near(float(v.targets[0][1]), 5.0,
				"stats-less enemy: default damage 5, health 20 -> kill value 5")
	_check_eq(v.threats.size(), 1, "only live non-charmed enemies are threats")
	if v.threats.size() == 1:
		# The bare body has neither has_outline() nor _is_meca/_is_mutant, so
		# with avoid switches on it must NOT be scaled: damage stays the 5.0
		# default. (A crash here is the bug this test exists for.)
		_check_eq(float(v.threats[0][3]), 5.0,
				"body without DLC probe surface: no avoid scaling, default damage 5")
	_ok(bool(v.has_method("gather")), "gather() completed on a damaged world")
	for th in v.threats:
		for i in range(th.size()):
			var f = typeof(th[i])
			if f == TYPE_REAL or f == TYPE_INT:
				_ok(not (is_nan(float(th[i])) or is_inf(float(th[i]))),
						"threat field %d finite" % i)

	# Idempotency: the same view instance re-gathered must produce the same arrays.
	var v2 = W.new()
	v2.apply_overrides({"charprofile": 0, "curse": -1, "evolved": -1, "evo": 1})
	v2.gather(main, player)
	var first_threats = v2.threats.duplicate(true)
	var first_targets = v2.targets.duplicate(true)
	v2.gather(main, player)
	_check_arrays_equal("idempotent threats", v2.threats, first_threats)
	_check_arrays_equal("idempotent targets", v2.targets, first_targets)

	# The cached-value guard: zero-valued food at full HP on a HEAD-style script
	# still pushes [pos, 0.0]; the new script must not crash either way.
	var head = _load_script("res://head_world_view.gd")
	if head != null:
		var hv = _gather(head, main, player, {"charprofile": 0})
		_ok(hv != null, "HEAD survives the same damaged world")
	_suite("robustness", before_c, before_f)


# =============================================================================
# Telemetry counters (design §3.5) -- P2 if absent, hard check if present.
# =============================================================================

func _run_telemetry_suite(W) -> void:
	var before_c = int(checks.get(target, 0))
	var before_f = int(failures.get(target, 0))
	var player = _new_player(Vector2.ZERO, 60.0, 100.0)
	var spawner = _new_spawner()
	var c1 = _new_enemy(Vector2(200, 0))
	c1.add_outline(Utils.CURSE_COLOR)
	var c2 = _new_enemy(Vector2(-200, 0))
	c2.add_outline(Utils.CURSE_COLOR)
	var dead_cursed = _new_enemy(Vector2(300, 300))
	dead_cursed.add_outline(Utils.CURSE_COLOR)
	dead_cursed.dead = true
	var evolved = _new_enemy(Vector2(0, 200))
	evolved._is_mutant = true
	spawner.enemies = [c1, c2, dead_cursed, evolved]
	spawner.bosses = []
	spawner.neutrals = []
	spawner.pets = []
	var main = _new_main(spawner)
	main._consumables = [
		_new_consumable(Vector2(80, 0), "meca_consumable_fruit", false),
		_new_consumable(Vector2(80, 80), "meca_parts_consumable", false),
		_new_consumable(Vector2(80, -80), "consumable_fruit", true),
	]
	main._active_golds = []
	_set_camp(0.0, false, false, false)
	var v = _gather(W, main, player, {"charprofile": 0})
	if ("last_cursed_n" in v) and ("last_evolved_n" in v) and ("last_evo_ground_n" in v):
		_check_eq(int(v.last_cursed_n), 2, "telemetry: 2 live cursed enemies counted")
		_check_eq(int(v.last_evolved_n), 1, "telemetry: 1 live evolved enemy counted")
		_check_eq(int(v.last_evo_ground_n), 2, "telemetry: 2 evolution consumables on the ground counted")
	else:
		_p2("telemetry counters last_cursed_n/last_evolved_n/last_evo_ground_n missing (design §3.5)")
	_suite("telemetry", before_c, before_f)


# =============================================================================
# Constants / overrides / defaults
# =============================================================================

func _run_config_suite(W) -> void:
	var before_c = int(checks.get(target, 0))
	var before_f = int(failures.get(target, 0))
	var consts = W.get_script_constant_map() if W.has_method("get_script_constant_map") else {}
	_check_near(float(consts.get("CURSE_TARGET_MULT", -1)), 3.0, "const CURSE_TARGET_MULT == 3.0")
	_check_near(float(consts.get("EVOLVED_TARGET_MULT", -1)), 2.5, "const EVOLVED_TARGET_MULT == 2.5")
	_check_near(float(consts.get("EVO_FRUIT_VALUE", -1)), 6.0, "const EVO_FRUIT_VALUE == 6.0")
	_check_near(float(consts.get("EVO_MUTATION_VALUE", -1)), 9.0, "const EVO_MUTATION_VALUE == 9.0")
	_check_near(float(consts.get("EVO_PARTS_VALUE", -1)), 6.0, "const EVO_PARTS_VALUE == 6.0")
	_check_near(float(consts.get("EVO_WALK_RIM", -1)), 45.0, "const EVO_WALK_RIM == 45.0")

	var v = W.new()
	_check_near(float(v.curse_mult), 3.0, "default curse_mult == 3.0")
	_check_near(float(v.evolved_mult), 2.5, "default evolved_mult == 2.5")
	_check_near(float(v.evo_mult), 1.0, "default evo_mult == 1.0")
	v.apply_overrides({"curse": 0.0})
	_check_eq(float(v.curse_mult), 0.0, "apply_overrides curse -> curse_mult")
	v.apply_overrides({"evolved": -1.0})
	_check_eq(float(v.evolved_mult), -1.0, "apply_overrides evolved -> evolved_mult")
	v.apply_overrides({"evo": 0.0})
	_check_eq(float(v.evo_mult), 0.0, "apply_overrides evo -> evo_mult")
	v.apply_overrides({"nosuchflag": 1})
	_ok(true, "apply_overrides ignores unknown keys without crashing")
	_check_near(float(v.curse_mult), 0.0, "unrelated apply_overrides does not reset curse_mult")
	_suite("config", before_c, before_f)


# =============================================================================
# Feature suites driver
# =============================================================================

func _run_feature_suites(W) -> void:
	_run_config_suite(W)
	_run_curse_suite(W)
	_run_evo_suite(W)
	_run_robustness_suite(W)
	_run_telemetry_suite(W)
