extends SceneTree

# =============================================================================
# tests/contact/sim.gd -- round-7 "bumps into a monster in a sparse scene"
# closed-loop regression instrument (v2.10.0).
#
# Derived from the v2.5 planning sim / v2.6.1 collision sim. The bot under test
# is the REAL shipped arbiter (copied from mod/ by run.sh into
# res://arbiter.gd), driven through the REAL shipped config path
# (Config.parse({}, {}) + apply_config) -- i.e. the same defaults the game gets.
# The world is a deterministic 60 Hz toy: a walled rectangle, slow pursuers as
# contact bodies, and v2.9-shaped economy reward tuples (8 fields, flags at
# index R_ECON_FLAGS).
#
# Two scenario families target the round-7 regression:
#   econ_*       -- one v2.9 economy resource (LOST_AT_HORN fruit / TREE)
#                   behind a body on the route; the REAL econ_planner decides
#                   the commitment and the commitment is fed as profile["econ"].
#   user_melee_* -- the exact real-game user loadout recovered from the play
#                   session: Survivor (max HP 10), 2x ghost flint (melee
#                   weapon_range 170, kite_frac 0), inferred profile.
#
# Arms (all on the live arbiter, switchable via env -- see run.sh):
#   fixed     : shipped v2.10.0 defaults (objective-pull guard ON, single
#               wave-end deadline scale).
#   v291      : exact v2.9.1 control arm (SIM_OVR="pullsafe=0,econdl=1").
#
# Exit code 0 always; this is an instrument -- assert_contact.py is the gate.
# =============================================================================

const DT = 1.0 / 60.0
const K_CONTACT = 1
const K_PROJ = 0
const INF_TIME = 1e9
# player hurtbox effective radius (player.tscn Hurtbox Collision radius 21, the
# value world_view passes as body_radius). The old sim used 18; live is 21.
const BODY_R = 21.0
# world_view THREAT_RANGE: bodies past this are not in the live threat set.
const THREAT_RANGE = 620.0

var fails = 0
var _last_breakout_s = 0.0
var _last_items = 0
var _last_first_t = -1.0
var _last_edge_min = 0.0
var _last_edge_mean = 0.0
var _last_edge_150 = 0.0
var _last_edge_100 = 0.0
var _last_special_min = 1e9


func _init():
	print("=== planning-v250 closed-loop simulation ===")
	print("policy | scenario | alive | t | hp_min | contact_s | surrounded_s | nearest_end | max_near | breakout_s | items | edge_min | edge_mean | e<150 | e<100 | sp_min | firstC | hits | gap_min | kills")
	var only_scn = OS.get_environment("SIM_ONLY")
	var only_pol = OS.get_environment("SIM_POLICIES")
	var prefix = OS.get_environment("SIM_PREFIX")
	# tests/contact: SIM_SET=a,b,c selects an exact scenario subset (the gate
	# runs only the round-7 fixtures, not the whole research scenario space).
	var sim_set = {}
	var set_env = OS.get_environment("SIM_SET")
	if set_env != "":
		for n in set_env.split(","):
			sim_set[n] = true
	for scn in scenarios():
		if only_scn != "" and scn["name"] != only_scn:
			continue
		if prefix != "" and not scn["name"].begins_with(prefix):
			continue
		if not sim_set.empty() and not sim_set.has(scn["name"]):
			continue
		var pols = scn.get("policies", ["greedy", "control", "v250", "oracle", "proto"])
		if only_pol != "":
			pols = only_pol.split(",")
		for pol in pols:
			var r = run_scenario(scn, pol)
			print("%-14s | %-30s | %-5s | %5.1f | %6.1f | %8.2f | %10.2f | %10.1f | %4d | %5.2f | %d@%.1fs | %6.1f | %6.1f | %5.2f | %5.2f | %6.1f | %6.2f | %3d | %7.2f | %5d" % [
				pol, scn["name"], str(r["alive"]), r["t"],
				r["hp_min"], r["contact_s"], r["surrounded_s"],
				r["nearest_end"], r["max_near"], r["breakout_s"],
				r["items_picked"], r["first_pick_t"],
				r["edge_min"], r["edge_mean"], r["edge_150"], r["edge_100"],
				r["special_min"], r["first_contact"], r["contact_hits"], r["gap_min"],
				r["kills"]])
	print("=== done ===")
	quit(0)


# -- scenarios -------------------------------------------------------------
# Each enemy: pos, speed, radius, dmg. The world is deterministic.
func scenarios():
	# Round-7 mechanism sweep: SIM_SWEEP="k=v,k=v; k=v..." builds one econ
	# scenario per semicolon-separated point (see sweep_scn). Used to map the
	# econ-commitment boundary without editing this file per point.
	var sweepspec = OS.get_environment("SIM_SWEEP")
	if sweepspec != "":
		var swlist = []
		var idx = 0
		for spec in sweepspec.split(";"):
			if spec.strip_edges() == "":
				continue
			swlist.push_back(sweep_scn(spec, idx))
			idx += 1
		return swlist
	var list = []

	list.push_back({
		"name": "ring10_open",
		"far": Vector2(2048, 1536),
		"start": Vector2(1024, 768),
		"player_speed": 320.0,
		"enemies": ring(Vector2(1024, 768), 500.0, 10, 500.0, 200.0, 6.0),
		"spawn": null, "bullets": null, "duration": 30.0,
	})

	list.push_back({
		"name": "ring14_fast",
		"far": Vector2(2048, 1536),
		"start": Vector2(1024, 768),
		"player_speed": 320.0,
		"enemies": ring(Vector2(1024, 768), 420.0, 14, 420.0, 270.0, 6.0),
		"spawn": null, "bullets": null, "duration": 30.0,
	})

	list.push_back({
		"name": "ring16_walls",
		"far": Vector2(1200, 1000),
		"start": Vector2(600, 500),
		"player_speed": 320.0,
		"enemies": ring(Vector2(600, 500), 380.0, 16, 380.0, 240.0, 6.0),
		"spawn": null, "bullets": null, "duration": 30.0,
	})

	list.push_back({
		"name": "pincer_corner",
		"far": Vector2(1600, 1200),
		"start": Vector2(230, 230),
		"player_speed": 320.0,
		"enemies": arc(Vector2(230, 230), 380.0, 45.0, 100.0, 12, 220.0, 6.0),
		"spawn": null, "bullets": null, "duration": 30.0,
	})

	list.push_back({
		"name": "ring30_swarm",
		"far": Vector2(1800, 1300),
		"start": Vector2(900, 650),
		"player_speed": 320.0,
		"enemies": ring(Vector2(900, 650), 500.0, 30, 500.0, 240.0, 6.0),
		"spawn": null, "bullets": null, "duration": 20.0,
	})

	list.push_back({
		"name": "tight_ring8",
		"far": Vector2(1500, 1100),
		"start": Vector2(750, 550),
		"player_speed": 320.0,
		"enemies": ring(Vector2(750, 550), 260.0, 8, 260.0, 190.0, 6.0),
		"spawn": null, "bullets": null, "duration": 30.0,
	})

	list.push_back({
		"name": "swarm_spawn",
		"far": Vector2(2048, 1536),
		"start": Vector2(1024, 768),
		"player_speed": 320.0,
		"enemies": ring(Vector2(1024, 768), 520.0, 6, 520.0, 230.0, 6.0),
		"spawn": {"every": 1.2, "count": 2, "radius": 650.0, "max": 50,
				"speed": 230.0, "dmg": 6.0},
		"bullets": null, "duration": 30.0,
	})

	list.push_back({
		"name": "swarm_bullets",
		"far": Vector2(2048, 1536),
		"start": Vector2(1024, 768),
		"player_speed": 320.0,
		"enemies": ring(Vector2(1024, 768), 520.0, 6, 520.0, 220.0, 6.0),
		"spawn": {"every": 1.5, "count": 2, "radius": 650.0, "max": 45,
				"speed": 220.0, "dmg": 6.0},
		"bullets": {"every": 0.40, "speed": 340.0, "dmg": 5.0, "radius": 4.0,
				"random": 0.25},
		"duration": 30.0,
	})


	list.push_back({
		"name": "ring10_faster",
		"far": Vector2(2048, 1536),
		"start": Vector2(1024, 768),
		"player_speed": 320.0,
		"enemies": ring(Vector2(1024, 768), 460.0, 10, 460.0, 380.0, 6.0),
		"spawn": null, "bullets": null, "duration": 30.0,
	})

	list.push_back({
		"name": "ring20_walls",
		"far": Vector2(1200, 900),
		"start": Vector2(600, 450),
		"player_speed": 320.0,
		"enemies": ring(Vector2(600, 450), 380.0, 20, 380.0, 280.0, 6.0),
		"spawn": null, "bullets": null, "duration": 30.0,
	})

	list.push_back({
		"name": "crossfire",
		"far": Vector2(1500, 1200),
		"start": Vector2(750, 600),
		"player_speed": 320.0,
		"enemies": ring(Vector2(750, 600), 460.0, 10, 460.0, 240.0, 6.0),
		"spawn": null,
		"bullets": {"every": 0.22, "speed": 330.0, "dmg": 5.0, "radius": 4.0,
				"random": 0.15},
		"duration": 30.0,
	})


	list.push_back({
		"name": "ring_shooters",
		"far": Vector2(1600, 1200),
		"start": Vector2(800, 600),
		"player_speed": 320.0,
		"enemies": ring(Vector2(800, 600), 440.0, 9, 440.0, 250.0, 6.0, true),
		"spawn": null, "bullets": null, "duration": 30.0,
	})

	list.push_back({
		"name": "swarm_shooters",
		"far": Vector2(1800, 1300),
		"start": Vector2(900, 650),
		"player_speed": 320.0,
		"enemies": ring(Vector2(900, 650), 460.0, 8, 460.0, 240.0, 6.0, true),
		"spawn": {"every": 1.5, "count": 2, "radius": 650.0, "max": 40,
				"speed": 240.0, "dmg": 6.0},
		"bullets": null, "duration": 30.0,
	})


	list.push_back({
		"name": "bounty_egg",
		"far": Vector2(1600, 1200),
		"start": Vector2(500, 600),
		"player_speed": 320.0,
		"enemies": [],
		"targets_from_enemies": false,
		"target_list": [[Vector2(1100, 600), 60.0, false, 2]],
		"special_watch": Vector2(1100, 600),
		"weapon_range": 260.0,
		"profile": {"kite_frac": 0.75},
		"spawn": null, "bullets": null, "duration": 12.0,
		"policies": ["control", "v25", "v26"],
	})

	list.push_back({
		"name": "bounty_cursed",
		"far": Vector2(1600, 1200),
		"start": Vector2(500, 600),
		"player_speed": 320.0,
		"enemies": [],
		"targets_from_enemies": false,
		"target_list": [[Vector2(1150, 600), 18.0, false, 3]],
		"special_watch": Vector2(1150, 600),
		"weapon_range": 320.0,
		"profile": {"kite_frac": 0.75},
		"spawn": null, "bullets": null, "duration": 12.0,
		"policies": ["control", "v25", "v26"],
	})

	list.push_back({
		"name": "bounty_but_danger",
		"far": Vector2(1600, 1200),
		"start": Vector2(800, 600),
		"player_speed": 320.0,
		"enemies": ring(Vector2(800, 600), 350.0, 8, 350.0, 230.0, 6.0),
		"targets_from_enemies": true,
		"target_list": [[Vector2(1350, 600), 60.0, false, 2]],
		"special_watch": Vector2(1350, 600),
		"weapon_range": 260.0,
		"profile": {"kite_frac": 0.75},
		"spawn": null, "bullets": null, "duration": 12.0,
		"policies": ["control", "v25", "v26"],
	})

	list.push_back({
		"name": "near_wall_ring",
		"far": Vector2(1200, 900),
		"start": Vector2(220, 450),
		"player_speed": 320.0,
		"enemies": ring(Vector2(220, 450), 380.0, 16, 380.0, 255.0, 6.0),
		"targets_from_enemies": true,
		"weapon_range": 300.0,
		"profile": {"kite_frac": 0.75},
		"spawn": null, "bullets": null, "duration": 30.0,
		"policies": ["control", "v250", "pred8", "pred16", "pred24"],
	})

	list.push_back({
		"name": "corner_ring",
		"far": Vector2(1200, 900),
		"start": Vector2(180, 180),
		"player_speed": 320.0,
		"enemies": arc(Vector2(180, 180), 430.0, -20.0, 110.0, 14, 250.0, 6.0),
		"targets_from_enemies": true,
		"weapon_range": 300.0,
		"profile": {"kite_frac": 0.75},
		"spawn": null, "bullets": null, "duration": 30.0,
		"policies": ["control", "v250", "pred8", "pred16", "pred24"],
	})

	list.push_back({
		"name": "soldier_herd",
		"far": Vector2(1200, 900),
		"start": Vector2(600, 450),
		"player_speed": 320.0,
		"enemies": ring(Vector2(600, 450), 420.0, 16, 420.0, 260.0, 6.0),
		"targets_from_enemies": true,
		"weapon_range": 320.0,
		"profile": {"fire_still": true, "still": "prefer", "pin": true,
				"pin_dwell": 40, "kite_frac": 0.0},
		"spawn": null, "bullets": null, "duration": 30.0,
		"policies": ["control", "v250", "pred8", "pred16"],
	})

	list.push_back({
		"name": "melee_herd",
		"far": Vector2(1100, 850),
		"start": Vector2(550, 425),
		"player_speed": 320.0,
		"enemies": ring(Vector2(550, 425), 380.0, 22, 380.0, 275.0, 6.0),
		"targets_from_enemies": true,
		"weapon_range": 120.0,
		"profile": {"kite_frac": 0.0},
		"spawn": null, "bullets": null, "duration": 30.0,
		"policies": ["control", "v250", "pred8", "pred16"],
	})

	list.push_back({
		"name": "slow_player_herd",
		"far": Vector2(1100, 850),
		"start": Vector2(550, 425),
		"player_speed": 240.0,
		"enemies": ring(Vector2(550, 425), 400.0, 16, 400.0, 300.0, 6.0),
		"targets_from_enemies": true,
		"weapon_range": 300.0,
		"profile": {"kite_frac": 0.75},
		"spawn": null, "bullets": null, "duration": 30.0,
		"policies": ["control", "v250", "pred8", "pred16"],
	})

	list.push_back({
		"name": "clump_chase",
		"far": Vector2(1200, 900),
		"start": Vector2(600, 450),
		"player_speed": 320.0,
		"enemies": clump(Vector2(150, 450), 12, 260.0, 6.0),
		"targets_from_enemies": true,
		"weapon_range": 300.0,
		"profile": {"kite_frac": 0.75},
		"spawn": null, "bullets": null, "duration": 30.0,
		"policies": ["control", "v250", "pred8", "pred16"],
	})

	list.push_back({
		"name": "bullet_wall",
		"far": Vector2(1200, 900),
		"start": Vector2(600, 450),
		"player_speed": 320.0,
		"enemies": clump(Vector2(300, 450), 8, 240.0, 6.0),
		"targets_from_enemies": true,
		"weapon_range": 300.0,
		"profile": {"kite_frac": 0.75},
		"spawn": null,
		"bullets": {"every": 0.10, "speed": 340.0, "dmg": 4.0, "radius": 4.0,
				"random": 0.05},
		"duration": 25.0,
		"policies": ["control", "v250", "pred8", "pred16"],
	})

	list.push_back({
		"name": "one_side_spawn",
		"far": Vector2(1100, 850),
		"start": Vector2(550, 425),
		"player_speed": 320.0,
		"enemies": [],
		"targets_from_enemies": true,
		"weapon_range": 300.0,
		"profile": {"kite_frac": 0.75},
		"spawn": {"every": 0.9, "count": 2, "radius": 620.0, "max": 40,
				"speed": 250.0, "dmg": 6.0},
		"bullets": null, "duration": 30.0,
		"policies": ["control", "v250", "pred8", "pred16"],
	})

	list.push_back({
		"name": "item_far_safe",
		"far": Vector2(2048, 1536),
		"start": Vector2(1024, 768),
		"player_speed": 320.0,
		"enemies": [],
		"rewards": [[Vector2(1024 + 650, 768), 9.0, false, 45.0, 1.0]],
		"policies": ["greedy", "control", "v250"],
		"spawn": null, "bullets": null, "duration": 20.0,
	})

	list.push_back({
		"name": "item_far_1slow",
		"far": Vector2(2048, 1536),
		"start": Vector2(1024, 768),
		"player_speed": 320.0,
		"enemies": [{"pos": Vector2(1024 - 320, 768), "speed": 190.0,
				"radius": 14.0, "dmg": 6.0}],
		"rewards": [[Vector2(1024 + 520, 768), 9.0, false, 45.0, 1.0]],
		"policies": ["greedy", "control", "v250"],
		"spawn": null, "bullets": null, "duration": 20.0,
	})

	list.push_back({
		"name": "item_far_ring8",
		"far": Vector2(2048, 1536),
		"start": Vector2(1024, 768),
		"player_speed": 320.0,
		"enemies": ring(Vector2(1024, 768), 500.0, 8, 500.0, 210.0, 6.0),
		"rewards": [[Vector2(1024 + 660, 768), 9.0, false, 45.0, 1.0]],
		"policies": ["greedy", "control", "v250"],
		"spawn": null, "bullets": null, "duration": 25.0,
	})

	list.push_back({
		"name": "item_lull",
		"far": Vector2(2048, 1536),
		"start": Vector2(1024, 768),
		"player_speed": 320.0,
		"enemies": ring(Vector2(1024, 768), 420.0, 8, 420.0, 200.0, 6.0),
		"rewards": [[Vector2(1024 + 620, 768), 9.0, false, 45.0, 1.0]],
		"policies": ["greedy", "control", "v250"],
		"spawn": null, "bullets": null, "duration": 25.0,
	})

	list.append_array(simple_scenarios())
	list.append_array(real_scenarios())
	list.append_array(econ_scenarios())
	list.append_array(user_scenarios())
	return list


# ==========================================================================
# REAL-GEOMETRY 1v1 family (Lead request): the arbiter is fed the enemy
# HURTBOX radius (what world_view does); the world's contact test uses the real
# pair enemy HITBOX radius + player hurtbox 21 (contact_table.json). So the
# scorer's contact radius is LARGER than the real one by 10-38 px, which is
# exactly the over-cautious direction -- if the bot still touches, the cause is
# not "contact underpriced in distance", it is the shape of the cost.
# ==========================================================================
func real_scenarios():
	var list = []
	var C = Vector2(1024, 768)
	var kinds = ["pursuer", "baby_alien", "charger"]
	for kind in kinds:
		for spd in [150.0, 190.0, 250.0]:
			var nm = "real_1v1_%s_%d" % [kind, int(spd)]
			list.push_back(sscn(nm, C, [bdr(kind, C - Vector2(380, 0), spd, 2.0)]))
	# side approach and a start just inside the model radius
	list.push_back(sscn("real_1v1_pursuer190_side", C,
			[bdr("pursuer", C + Vector2(0, -380), 190.0, 2.0)]))
	list.push_back(sscn("real_1v1_pursuer190_near", C,
			[bdr("pursuer", C - Vector2(120, 0), 190.0, 2.0)]))
	# start-distance sweep (body behind the bot's open floor)
	for dist in [180.0, 260.0, 340.0]:
		list.push_back(sscn("real_dist_pursuer190_%d" % int(dist), C,
				[bdr("pursuer", C - Vector2(dist, 0), 190.0, 2.0)]))
	# realistic _kill_value for a DANGEROUS body: value = damage*2*killability.
	# dmg 6 body, kill_ref 60 (60 DPS of sustained fire) -> value ~8-10, i.e. the
	# same DPS pull the flat-8 toy used, without the unrealistic value on a 2-dmg
	# body. Contact price also scales with damage, so this isolates the ratio.
	for kind in ["pursuer", "baby_alien"]:
		for spd in [190.0, 250.0]:
			list.push_back(sscn("real_kill6_%s_%d" % [kind, int(spd)], C,
					[bdr(kind, C - Vector2(380, 0), spd, 6.0, 0.8, 20.0)], 20.0,
					{"kill_ref": 60.0}))
	# the OLD-sim DPS pull (flat target value 8) -- Lead's orbit toy candidate
	for kind in ["pursuer", "baby_alien"]:
		for spd in [150.0, 190.0, 250.0]:
			list.push_back(sscn("real_tv8_%s_%d" % [kind, int(spd)], C,
					[bdr(kind, C - Vector2(300, 0), spd, 2.0)], 20.0,
					{"target_value": 8.0}))
	return list


func clump(center, n, speed, dmg):
	var out = []
	for i in range(n):
		var a = float(i) * TAU / float(n)
		out.push_back({
			"pos": center + Vector2(cos(a), sin(a)) * (20.0 + 8.0 * float(i % 5)),
			"speed": speed, "radius": 14.0, "dmg": dmg,
			"ranged": false,
		})
	return out


func ring(center, r, n, start_r, speed, dmg, ranged = false):
	var out = []
	for i in range(n):
		var a = float(i) * TAU / float(n)
		out.push_back({
			"pos": center + Vector2(cos(a), sin(a)) * start_r,
			"speed": speed, "radius": 14.0, "dmg": dmg,
			"ranged": ranged and (i % 3 == 0),
		})
	return out


# Arc of enemies coming from `from_deg` to `to_deg` around the player (the
# direction the open floor is). The player's back is a wall corner.
func arc(center, r, from_deg, to_deg, n, speed, dmg):
	var out = []
	for i in range(n):
		var t = float(i) / float(max(n - 1, 1))
		var a = deg2rad(lerp(from_deg, to_deg, t))
		out.push_back({
			"pos": center + Vector2(cos(a), sin(a)) * r,
			"speed": speed, "radius": 14.0, "dmg": dmg,
			"ranged": false,
		})
	return out


# ==========================================================================
# SIMPLE / SPARSE family ("sometimes in relatively simple situations the
# character collides with monsters"). Sparse = 1-4 bodies, calm/open wave, all
# bodies SLOWER than the player (150-250 vs 320), so a correct kiting policy
# never has to touch one. Profiles are realistic world_view defaults for a
# normal ranged build: kite_frac 0.75 (KITE_FRAC_RANGED) + weapon_range 260.
# ==========================================================================
func bd(pos, speed, dmg, radius = 14.0, kill = 0.6, hp = 10.0):
	return {"pos": pos, "speed": speed, "radius": radius, "dmg": dmg,
			"kill": kill, "hp": hp, "ranged": false}


# Real in-game contact geometry, straight from
# _research/collision-bug/geom/contact_table.json (geom-auditor):
#   [model_radius_fed_to_arbiter, real_contact_radius_world_test]
# world_view._body_radius() reads the enemy HURTBOX radius and _add_unit adds
# the player hurtbox radius (21) -> that is what the scorer prices. The real
# Area2D overlap is enemy HITBOX radius + player hurtbox 21, so the two differ
# by 10-38 px per kind (pursuer: model 64.38 vs real 26).
const ENEMY_GEOM = {
	"generic": [14.0, 14.0],
	"pursuer": [64.3817, 26.0],
	"baby_alien": [32.0, 16.0312],
	"fin_alien": [32.0, 16.0],
	"helmet_alien": [32.0, 21.0],
	"charger": [48.0104, 25.0],
	"horned_charger": [48.0104, 25.0],
}


# Enemy with BOTH radii: `radius` = hurtbox radius world_view feeds the arbiter,
# `hit_radius` = hitbox radius used by the world's real contact test.
func bdr(kind, pos, speed, dmg, kill = 0.6, hp = 10.0):
	var g = ENEMY_GEOM["generic"]
	if ENEMY_GEOM.has(kind):
		g = ENEMY_GEOM[kind]
	return {"pos": pos, "speed": speed, "radius": float(g[0]),
			"hit_radius": float(g[1]), "dmg": dmg, "kill": kill, "hp": hp,
			"ranged": false}


func sscn(name, start, enemies, duration = 20.0, extra = {}):
	var s = {
		"name": name, "far": Vector2(2048, 1536), "start": start,
		"player_speed": 320.0, "enemies": enemies,
		"targets_from_enemies": true, "weapon_range": 260.0,
		"profile": {"kite_frac": 0.75},
		"spawn": null, "bullets": null, "duration": duration,
		"policies": ["control", "v250", "v26"],
	}
	for k in extra.keys():
		s[k] = extra[k]
	return s


func simple_scenarios():
	var list = []
	var C = Vector2(1024, 768)

	# -- A: one body, open field, no reward. The bot should never touch it --
	list.push_back(sscn("simple_a_behind150", C,
			[bd(C - Vector2(260, 0), 150.0, 2.0)]))
	list.push_back(sscn("simple_a_ahead150", C,
			[bd(C + Vector2(300, 0), 150.0, 2.0)]))
	list.push_back(sscn("simple_a_pursuer250", C,
			[bd(C - Vector2(420, 0), 250.0, 6.0)]))
	list.push_back(sscn("simple_a_side190", C,
			[bd(C + Vector2(0, -380), 190.0, 4.0)]))
	list.push_back(sscn("simple_a_two_slow", C,
			[bd(C - Vector2(250, 0), 150.0, 2.0),
			 bd(C + Vector2(250, 0), 170.0, 2.0)]))
	list.push_back(sscn("simple_a_two_cross", C,
			[bd(C + Vector2(-200, -160), 200.0, 2.0),
			 bd(C + Vector2(220, 180), 250.0, 6.0)]))

	# -- B: committed item goal with a body on the corridor (v2.5 goal) ----
	# start 500, body 860 (360 px away, GOAL_SAFE_R=320 lets acquisition fire),
	# reward 1250 (750 px, inside GOAL_RANGE=1000).
	var B0 = Vector2(500, 768)
	var BREW = [[Vector2(1250, 768), 9.0, false, 45.0, 1.0]]
	list.push_back(sscn("simple_b_goal_thru150", B0,
			[bd(Vector2(860, 768), 150.0, 2.0)], 20.0,
			{"rewards": BREW}))
	list.push_back(sscn("simple_b_goal_thru250d6", B0,
			[bd(Vector2(860, 768), 250.0, 6.0)], 20.0,
			{"rewards": BREW}))
	list.push_back(sscn("simple_b_goal_offset60", B0,
			[bd(Vector2(860, 828), 150.0, 2.0)], 20.0,
			{"rewards": BREW}))
	list.push_back(sscn("simple_b_goal_thru150_cautious", B0,
			[bd(Vector2(860, 768), 150.0, 2.0)], 20.0,
			{"rewards": BREW,
			 "profile": {"kite_frac": 0.75, "caution": 1.6}}))
	list.push_back(sscn("simple_b_goal_behind", Vector2(1100, 768),
			[bd(Vector2(760, 768), 150.0, 2.0)], 20.0,
			{"rewards": [[Vector2(500, 768), 9.0, false, 45.0, 1.0]]}))

	# -- C: item on the floor + a chaser --------------------------------
	list.push_back(sscn("simple_c_item_cross", Vector2(600, 900),
			[bd(Vector2(900, 600), 200.0, 4.0)], 20.0,
			{"rewards": [[Vector2(600, 300), 9.0, false, 45.0, 1.0]]}))
	list.push_back(sscn("simple_c_item_away", Vector2(700, 768),
			[bd(Vector2(1000, 768), 150.0, 2.0)], 20.0,
			{"rewards": [[Vector2(300, 768), 9.0, false, 45.0, 1.0]]}))

	# -- D: two bodies on crossing paths --------------------------------
	list.push_back(sscn("simple_d_cross2", Vector2(800, 768),
			[bd(Vector2(600, 568), 200.0, 2.0),
			 bd(Vector2(1000, 968), 250.0, 6.0)]))
	list.push_back(sscn("simple_d_vshape", Vector2(800, 768),
			[bd(Vector2(450, 618), 190.0, 2.0),
			 bd(Vector2(1150, 618), 190.0, 2.0)]))

	# -- E: near wall / corner, 2-3 bodies (small arena) ------------------
	list.push_back(sscn("simple_e_edge2", Vector2(140, 450),
			[bd(Vector2(500, 450), 220.0, 2.0),
			 bd(Vector2(700, 300), 250.0, 6.0)], 20.0,
			{"far": Vector2(1200, 900)}))
	list.push_back(sscn("simple_e_corner3", Vector2(180, 180),
			[bd(Vector2(520, 120), 190.0, 2.0),
			 bd(Vector2(120, 520), 190.0, 2.0),
			 bd(Vector2(480, 480), 250.0, 6.0)], 20.0,
			{"far": Vector2(1200, 900)}))
	list.push_back(sscn("simple_e_edge_body_between", Vector2(180, 450),
			[bd(Vector2(560, 450), 180.0, 2.0)], 20.0,
			{"far": Vector2(1200, 900)}))

	# -- F: special target (bounty, v2.6) beyond a plain body ------------
	list.push_back(sscn("simple_f_bounty_thru", Vector2(400, 768),
			[bd(Vector2(820, 768), 150.0, 2.0)], 20.0,
			{"special": [Vector2(1250, 768), 30.0, false, 1.0]}))
	list.push_back(sscn("simple_f_bounty_offset", Vector2(400, 768),
			[bd(Vector2(820, 820), 150.0, 2.0)], 20.0,
			{"special": [Vector2(1250, 768), 30.0, false, 1.0]}))
	list.push_back(sscn("simple_f_bounty_fast", Vector2(400, 768),
			[bd(Vector2(780, 768), 250.0, 6.0)], 20.0,
			{"special": [Vector2(1250, 768), 30.0, false, 1.0]}))

	# -- G: stationary dangerous body (egg / spawner / cursed on floor) ---
	list.push_back(sscn("simple_g_egg_ahead", C,
			[bd(C + Vector2(300, 0), 0.0, 2.0, 20.0)]))
	list.push_back(sscn("simple_g_egg_near", Vector2(1300, 900),
			[bd(Vector2(1300, 768), 0.0, 2.0, 20.0)]))

	# -- H: fire_still stand kit + weak body walking in ----------------
	list.push_back(sscn("simple_h_firestill", C,
			[bd(C + Vector2(500, 0), 150.0, 2.0)], 20.0,
			{"profile": {"fire_still": true, "kite_frac": 0.0}}))

	return list


# ==========================================================================
# Parameterised econ sweep point (SIM_SWEEP mode): one chaser + one flagged
# resource on the straight line. Keys / defaults:
#   dmg   body contact damage           6
#   bspd  body speed px/s               100
#   bpos  body distance ahead           240
#   rpos  resource distance ahead       520
#   rval  resource mid-wave value       18   (meca LOST_AT_HORN = EVO_VALUE)
#   rflags acquisition bitmask          2    (ECON_LOST_AT_HORN)
#   tag   reward R_TAG                  3    (OPP_TAG_EVO)
#   wave  wave_time_left s              1e9  (4 = end-of-wave sweep/deadline)
#   maxhp / starthp  build HP           100 / 100
#   wrange weapon_range                 0    (170 = melee user build)
#   prof  caution (profile multiplier)  1.0
# ==========================================================================
func sweep_scn(spec, idx):
	var d = {"dmg": 6.0, "bspd": 100.0, "bpos": 240.0, "rpos": 520.0,
			"rval": 18.0, "rflags": 2.0, "tag": 3.0, "wave": 1e9,
			"maxhp": 100.0, "starthp": 100.0, "wrange": 0.0, "prof": 1.0,
			"boff": 0.0}
	for kv in spec.split(","):
		var p = kv.split("=")
		if p.size() == 2:
			d[p[0]] = float(p[1])
	var maxhp = float(d["maxhp"])
	var starthp = float(d["starthp"])
	if starthp > maxhp:
		starthp = maxhp
	var wrange = float(d["wrange"])
	var C = Vector2(1024, 768)
	var prof = {"kite_frac": 0.0}
	if float(d["prof"]) != 1.0:
		prof["caution"] = float(d["prof"])
		prof["lethality"] = 4.07
	return {
		"name": "sweep_%03d_%s" % [idx, spec.replace(",", "_").replace("=", "")],
		"far": Vector2(2048, 1536), "start": C,
		"player_speed": 320.0,
		"enemies": [bdr("pursuer", C + Vector2(float(d["bpos"]), float(d["boff"])),
				float(d["bspd"]), float(d["dmg"]))],
		"weapon_range": wrange, "targets_from_enemies": wrange > 0.0,
		"kill_ref": 20.0, "max_hp": maxhp, "start_hp": starthp,
		"profile": prof,
		"rewards_econ": [[C + Vector2(float(d["rpos"]), 0), float(d["rval"]),
				float(d["rflags"]), float(d["tag"])]],
		"wave_left": float(d["wave"]),
		"spawn": null, "bullets": null, "duration": 20.0,
		"policies": ["v26"],
	}


# ==========================================================================
# v2.9 ECONOMY-LAYER family (round 7, top suspect).
#
# The only reward is a flagged resource -- the world_view econ=1 tuple shape
# (8th field = acquisition-path bitmask, contract.gd R_ECON_FLAGS) -- and a
# slow body sits on the straight route. The planner is the REAL
# econ_planner.gd, instantiated here and fed exactly the ctx world_view hands
# it; its commitment dict is passed as profile["econ"], exactly as
# world_view.gather() does. So this exercises the real v2.9 decision chain:
#   resource -> economy flags -> EconPlanner -> profile["econ"]
#            -> arbiter _goal_on pull (+ close-in candidate).
# The v2.8 control arm sees the SAME rewards; econ=0 in the arbiter means the
# 8th field is ignored and the legacy _update_opportunity gate prices the raw
# value (v2.8.0 path). econ=1 means the planner's continuous-risk budget
# decides, with NO proximity/abort gate on an existing commitment.
# ==========================================================================
func econ_scenarios():
	var list = []
	var C = Vector2(1024, 768)
	# meca/mutant fruit: ECON_LOST_AT_HORN, economy price EVO_VALUE = 18.
	# Tuple as world_view builds it: [pos, 18*deadline, false(walk-on),
	# EVO_WALK_RIM=45, EVO_WALK_TAG=1, 0, tag=OPP_TAG_EVO(3), flags=2].
	for spd in [60.0, 100.0, 150.0]:
		list.push_back(escn("econ_meca_body_between_%d" % int(spd), C,
				[bdr("pursuer", C + Vector2(240, 0), spd, 6.0)],
				[[C + Vector2(520, 0), 18.0, 2.0, 3]]))
	# body 60 px off the straight line (grazing lane, not a head-on block)
	list.push_back(escn("econ_meca_body_offset60", C,
			[bdr("pursuer", C + Vector2(240, 60), 100.0, 6.0)],
			[[C + Vector2(520, 0), 18.0, 2.0, 3]]))
	# no body at all: the bot should just collect it (planner sanity)
	list.push_back(escn("econ_meca_alone", C, [],
			[[C + Vector2(520, 0), 18.0, 2.0, 3]]))
	# a weak body (dmg 2): both arms may commit; checks the econ pull strength
	list.push_back(escn("econ_meca_body_between_d2", C,
			[bdr("pursuer", C + Vector2(240, 0), 100.0, 2.0)],
			[[C + Vector2(520, 0), 18.0, 2.0, 3]]))
	# living tree: ECON_TREE(8), realistic full-HP EV ~3.0 (and a strong 6.0)
	for v in [3, 6]:
		list.push_back(escn("econ_tree_body_between_v%d" % v, C,
				[bdr("pursuer", C + Vector2(240, 0), 100.0, 4.0)],
				[[C + Vector2(520, 0), float(v), 8.0, 5]]))
	# stationary body dead on the route (simplest sparse geometry: one body,
	# one resource). Body speed 0 = a non-pursuing monster type.
	for d in [240, 150]:
		list.push_back(escn("econ_meca_stillbody_%d" % d, C,
				[bdr("pursuer", C + Vector2(d, 0), 0.0, 6.0)],
				[[C + Vector2(520, 0), 18.0, 2.0, 3]]))
	# closer resource / closer body geometry sweep
	list.push_back(escn("econ_meca_closer_180_340", C,
			[bdr("pursuer", C + Vector2(180, 0), 100.0, 6.0)],
			[[C + Vector2(340, 0), 18.0, 2.0, 3]]))
	list.push_back(escn("econ_meca_body_between_120", C,
			[bdr("pursuer", C + Vector2(120, 0), 100.0, 6.0)],
			[[C + Vector2(520, 0), 18.0, 2.0, 3]]))
	# end-of-wave sweep: wave_left inside econ_sweep_secs(6 s) -> only LOST
	# resources pay, and the deadline factor boosts value up to x3.
	list.push_back(escn("econ_meca_waveend4s", C,
			[bdr("pursuer", C + Vector2(240, 0), 100.0, 6.0)],
			[[C + Vector2(900, 0), 18.0, 2.0, 3]], 4.0))
	list.push_back(escn("econ_meca_waveend4s_far", C,
			[bdr("pursuer", C + Vector2(240, 0), 100.0, 6.0)],
			[[C + Vector2(900, 0), 18.0, 2.0, 3]], 4.0))
	return list


# econ scenario: far/start/speed fixed (open field), rewards_econ entries are
# [pos, value, flags, tag] and are converted to the real 8-field world_view
# tuple by run_scenario.
func escn(name, start, enemies, econ_rewards, wave_left = 1e9):
	return {
		"name": name, "far": Vector2(2048, 1536), "start": start,
		"player_speed": 320.0, "enemies": enemies,
		"rewards_econ": econ_rewards, "wave_left": wave_left,
		"spawn": null, "bullets": null, "duration": 20.0,
		"policies": ["v26"],
	}


# ==========================================================================
# USER-BUILD family (round-7 real run data, Lead's reconstruction):
#   character_survivor, Danger 5, 2x weapon_ghost_flint (MELEE: max_range 170,
#   cooldown 40f, damage 6), waves 1-2 cleared, lost on wave 3.
#   inferred profile {caution~1.38, food:bank, gold:0.8, lethality~4.07,
#   tree_value:3}; Survivor max HP ~10.
# The profiles below feed the arbiter's real keys (kite_frac/lethality/caution);
# food/gold/tree_value are world_view pricing keys and are inert here, kept for
# provenance. Bodies are the sparse wave-1/2 chasers; no weapon kills are
# modelled (SIM_DPS=0), so contact survival is the discriminator.
# ==========================================================================
func user_scenarios():
	var list = []
	var C = Vector2(1024, 768)
	var prof = {"kite_frac": 0.0, "food": "bank", "gold": 0.8,
			"lethality": 4.07, "tree_value": 3.0, "caution": 1.377}
	# A1: ONE slow chaser ahead: the melee bot must close to 170 px to shoot.
	for spd in [120.0, 150.0, 190.0]:
		list.push_back(uscn("user_melee_pursuer_%d" % int(spd), C,
				[bdr("pursuer", C + Vector2(250, 0), spd, 2.0)], prof))
	# A2: dangerous body: 2.5 contact hits kill a 10 HP build.
	for spd in [150.0, 190.0]:
		list.push_back(uscn("user_melee_pursuer_%d_d4" % int(spd), C,
				[bdr("pursuer", C + Vector2(250, 0), spd, 4.0)], prof))
	# A3: start-distance sweep (200 / 300 px).
	for d in [200, 300]:
		list.push_back(uscn("user_melee_pursuer_150_at%d" % d, C,
				[bdr("pursuer", C + Vector2(d, 0), 150.0, 2.0)], prof))
	# A4: TWO pursuers from different sides (sparse, but not 1v1).
	list.push_back(uscn("user_melee_two_pursuers", C,
			[bdr("pursuer", C + Vector2(250, 0), 150.0, 2.0),
			bdr("pursuer", C - Vector2(0, 250), 150.0, 2.0)], prof))
	# A5: tree behind a body: ECON_TREE(8) value 3 (price_tree EV ~3).
	list.push_back(uscn("user_melee_tree_behind", C,
			[bdr("pursuer", C + Vector2(250, 0), 150.0, 2.0)], prof,
			[[C + Vector2(520, 0), 3.0, 8.0, 5]]))
	# A6: injured-fruit payoff behind a body: MID_WAVE_ONLY(4), value 6.
	list.push_back(uscn("user_melee_fruit_behind", C,
			[bdr("pursuer", C + Vector2(250, 0), 150.0, 2.0)], prof,
			[[C + Vector2(520, 0), 6.0, 4.0, 0]]))
	# A7: same, but the meca-fruit detour (LOST_AT_HORN) one body away: the
	# exact pattern the econ planner is designed to chase.
	list.push_back(uscn("user_melee_meca_behind", C,
			[bdr("pursuer", C + Vector2(250, 0), 150.0, 2.0)], prof,
			[[C + Vector2(520, 0), 18.0, 2.0, 3]]))
	return list


func uscn(name, start, enemies, profile, econ_rewards = []):
	return {
		"name": name, "far": Vector2(2048, 1536), "start": start,
		"player_speed": 320.0, "enemies": enemies,
		"weapon_range": 170.0, "targets_from_enemies": true, "kill_ref": 20.0,
		"max_hp": 10.0, "start_hp": 10.0,
		"profile": profile.duplicate(), "rewards_econ": econ_rewards,
		"spawn": null, "bullets": null, "duration": 20.0,
		"policies": ["v26"],
	}


# -- one scenario x one policy --------------------------------------------
func run_scenario(scn, policy):
	var arb = null
	var oracle_last = Vector2.ZERO
	var oracle_hold = 0
	if policy == "greedy":
		arb = new_arbiter()
		arb.apply_overrides({"plan": 0, "adapt": 0, "kite": 0})
	elif policy == "control":
		arb = new_arbiter()
		arb.apply_overrides({"breakout": 0, "goal": 0, "pursuit": 0, "walk": 0,
				"bounty": 0, "space": 0, "roomtrack": 0})
	elif policy == "v25":
		# v2.5.0 feature set: v2.6 bounty/box layer off.
		arb = new_arbiter()
		arb.apply_overrides({"bounty": 0})
	elif policy == "v26" or policy == "v250" or policy == "proto" or policy == "goal":
		arb = new_arbiter()
	elif policy.begins_with("pred"):
		arb = new_arbiter()
		arb.apply_overrides({"predict": float(policy.substr(4))})
	elif policy.begins_with("psec"):
		arb = new_arbiter()
		arb.apply_overrides({"predict": float(policy.substr(4)), "predsecs": 3.0})
	elif policy.begins_with("wpred"):
		# wpred<N> = wall weight scale: same 0.8s wall term but softer
		arb = new_arbiter()
		arb.apply_overrides({"wall": float(policy.substr(5))})
	elif policy.begins_with("brk"):
		arb = new_arbiter()
		arb.apply_overrides({"breakout": float(policy.substr(3))})
	elif policy.begins_with("ax_"):
		# A/B ablation arm on top of shipped v2.6 defaults: ax_<switch>...
		# e.g. ax_nobounty, ax_nogoal, ax_nobrk, ax_noplan, ax_nopursuit,
		# ax_nohyst, ax_nospace, ax_nokite, ax_nodps, ax_nocontact.
		arb = new_arbiter()
		var ov = {}
		for part in policy.substr(3).split("_"):
			if part == "nobounty":
				ov["bounty"] = 0
			elif part == "nogoal":
				ov["goal"] = 0
			elif part == "nobrk":
				ov["breakout"] = 0
			elif part == "noplan":
				ov["plan"] = 0
			elif part == "nopursuit":
				ov["pursuit"] = 0
			elif part == "nowalk":
				ov["walk"] = 0
			elif part == "nohyst":
				ov["hyst"] = 0
			elif part == "nospace":
				ov["space"] = 0
			elif part == "noroom":
				ov["room"] = 0
			elif part == "noroomfar":
				ov["roomfar"] = 0
			elif part == "nokite":
				ov["kite"] = 0
			elif part == "nodps":
				ov["dps"] = 0
			elif part == "noadapt":
				ov["adapt"] = 0
			elif part == "nocontact":
				ov["contact"] = 0.01
			elif part == "contact3":
				ov["contact"] = 3.0
			else:
				print("UNKNOWN AX PART ", part)
		arb.apply_overrides(ov)
	else:
		pass

	if arb != null and OS.get_environment("SIM_OVR") != "":
		var ov = {}
		for kv in OS.get_environment("SIM_OVR").split(","):
			var kvp = kv.split("=")
			if kvp.size() == 2:
				ov[kvp[0]] = float(kvp[1])
		arb.apply_overrides(ov)

	var far = scn["far"]
	var p = scn["start"]
	var speed = scn["player_speed"]
	# round 7: low-HP user build support (Survivor, inferred max HP ~10).
	# start_hp/max_hp default to the old 100/100 toy.
	var max_hp = float(scn.get("max_hp", 100.0))
	var hp = float(scn.get("start_hp", max_hp))
	var hp_min = hp
	var enemies = []
	for e in scn["enemies"]:
		enemies.push_back({
			"pos": e["pos"], "speed": e["speed"], "radius": e["radius"],
			"hit_radius": float(e.get("hit_radius", e["radius"])),
			"dmg": e["dmg"], "cd": 0.0,
			"kill": float(e.get("kill", 0.6)),
			"hp": float(e.get("hp", 10.0)),
			"ranged": bool(e.get("ranged", false)),
			"shot_cd": 0.7,
		})
	var bullets = []
	var t = 0.0
	var contact_s = 0.0
	var surrounded_s = 0.0
	var max_near = 0
	var nearest_end = 0.0
	var edge_min = 1e9
	var edge_sum = 0.0
	var edge_n = 0
	var edge_under_150 = 0.0
	var edge_under_100 = 0.0
	var special_min = 1e9
	var rng = RandomNumberGenerator.new()
	rng.seed = 12345
	var next_spawn = INF
	if scn["spawn"] != null:
		next_spawn = float(scn["spawn"]["every"])
	var next_bullet = INF
	var breakout_s = 0.0
	var items_start = 0
	var items_picked = 0
	var first_pick_t = -1.0
	var proto_state = {"active": 0, "dir": Vector2.ZERO, "cooldown": 0}
	var trace = OS.get_environment("SIM_TRACE") != ""
	if scn["bullets"] != null:
		next_bullet = 0.5
	var duration = float(scn["duration"])
	# player weapon model: DPS applied to the nearest body inside weapon range
	# (the sim otherwise has no weapons, so bodies never die -- the closed loop
	# then over-weights long orbits). SIM_DPS overrides; 0 = old no-kill sim.
	var dps = float(scn.get("dps", 0.0))
	if OS.get_environment("SIM_DPS") != "":
		dps = float(OS.get_environment("SIM_DPS"))
	var kills = 0
	var kill_ref = float(scn.get("kill_ref", clamp(dps, 20.0, 600.0)))
	# flat target value override: reproduces the OLD planning-v250 sim that fed
	# every target value 8 (not world_view's damage x killability) -- the
	# stronger DPS pull a toy orbit repro may rely on.
	var flat_tv = float(scn.get("target_value", 0.0))
	var rewards = []
	var econ_rewards = scn.get("rewards_econ", [])
	if not econ_rewards.empty():
		# world_view econ=1 tuple (see _econ_reward_tag in world_view.gd):
		# [pos, value, attracted/walk-on, rim, walk-on, vel, tag, flags]
		# The sim appends its own "taken" marker at index 8; it is stripped
		# from replay_rewards before the arbiter sees the tuple.
		for rw in econ_rewards:
			rewards.push_back([rw[0], float(rw[1]), false, 45.0, 1.0, 0.0,
					float(rw[3]), float(rw[2]), 0])
	else:
		for rw in scn.get("rewards", []):
			var r2 = []
			for x in rw:
				r2.push_back(x)
			r2.push_back(0)     # marker is ALWAYS the last element
			rewards.push_back(r2)
	var replay_rewards = []
	for rw in rewards:
		var rr = []
		for x in rw:
			rr.push_back(x)
		rr.remove(rr.size() - 1)
		replay_rewards.push_back(rr)
	var replay_targets = scn.get("targets", [])
	var replay_wrange = float(scn.get("weapon_range", 0.0))
	# -- v2.9 economy planner (the REAL econ_planner.gd; see econ_scenarios) --
	var econ_planner = null
	var wave_left = float(scn.get("wave_left", 1e9))
	if not econ_rewards.empty():
		var Cfg = load("res://mods-unpacked/Pasha-AutoBattler/steering/config.gd")
		var Epl = load("res://mods-unpacked/Pasha-AutoBattler/steering/econ_planner.gd")
		if Cfg != null and Epl != null:
			econ_planner = Epl.new()
			econ_planner.apply_config(Cfg.new())
		else:
			print("ECON: arm predates v2.9 (no config/econ_planner); planner skipped")
	_last_breakout_s = 0.0

	# -- contact instrumentation (see _print_pre/_print_hit) ------------------
	var prev_dir = Vector2.ZERO
	var first_contact_t = -1.0
	var contact_frames = 0
	var contact_hits = 0
	var gap_min = 1e9           # min modelled clearance to any body over the run
	var pre = []                # ring buffer of decision snapshots before contact
	var CONTACT_MAX = 60

	var steps = int(round(duration / DT))
	for step in range(steps):
		# -- build threat set --
		var threats = []
		var mind = 1e9
		var near_120 = 0
		var sectors = []
		for k in range(8):
			sectors.push_back(false)
		for e in enemies:
			var epos = e["pos"]
			var dist = p.distance_to(epos)
			# live world_view culls bodies past THREAT_RANGE (=620) entirely
			if dist > THREAT_RANGE:
				continue
			var vel = Vector2.ZERO
			if dist > 0.001:
				vel = (p - epos) / dist * float(e["speed"])
			# live CONTACT_RATE / (1 - ve/vp) persistence price (world_view
			# _contact_ticks; flat 1.6 is the pre-v2.2.2 control and under-prices
			# every body the player cannot outrun by 2-4x -- do NOT use it here)
			var ticks = 1.6 / max(1.0 - float(e["speed"]) / speed, 0.25)
			threats.push_back([epos, vel, float(e["radius"]), float(e["dmg"]),
					K_CONTACT, 0.0, ticks, INF_TIME, float(e["kill"])])
			mind = min(mind, dist)
			if dist < 120.0:
				near_120 += 1
			if dist < 260.0:
				var ang = (epos - p).angle()
				var sec = int(round((ang + PI) / TAU * 8.0)) % 8
				sectors[sec] = true
		for b in bullets:
			threats.push_back([b["pos"], b["vel"], float(b["radius"]), float(b["dmg"]),
					K_PROJ, 0.0, 1.0, 3.0])
		var occ = 0
		for s in sectors:
			if s:
				occ += 1
		if occ >= 6:
			surrounded_s += DT
		max_near = max(max_near, near_120)

		# -- per-frame targets (optional: ranged-kite scenarios) --
		var targets_now = replay_targets
		var wrange_now = replay_wrange
		if bool(scn.get("targets_from_enemies", false)):
			# live world_view _kill_value: damage * EXPECTED_EXCHANGES *
			# killability, killability = kill_ref/(kill_ref+health). Refreshed
			# from DPS: KILL_HP_REF=20 default, KILL_TIME=1.0s of sustained fire.
			targets_now = []
			for e in enemies:
				if p.distance_to(e["pos"]) < 800.0:
					var kv = float(e["dmg"]) * 2.0 \
							* (kill_ref / (kill_ref + float(e["hp"])))
					if flat_tv > 0.0:
						kv = flat_tv
					targets_now.push_back([e["pos"], kv, false])
			wrange_now = float(scn.get("weapon_range", 0.0))
		if scn.has("target_list"):
			targets_now = []
			for tl in scn["target_list"]:
				targets_now.push_back(tl)
		if scn.has("special"):
			targets_now = targets_now.duplicate()
			targets_now.push_back(scn["special"])
		var prof = scn.get("profile", {})
		prof["hp_ratio"] = hp / max(max_hp, 1.0)
		if econ_planner != null:
			prof["wave_left"] = wave_left
			var econ_cands = []
			for rw in rewards:
				if rw.size() > 7 and int(rw[7]) != 0:
					econ_cands.push_back({"pos": rw[0], "value": float(rw[1]),
							"flags": int(rw[7]), "tag": int(rw[6])})
			var estate = econ_planner.update({"pos": p, "speed": speed,
					"hp_ratio": hp / max(max_hp, 1.0), "wave_time_left": wave_left,
					"threats": threats, "candidates": econ_cands,
					"mitigation": 1.0, "body_radius": BODY_R})
			prof["econ"] = estate
			if (step % 30 == 0) and not estate.empty():
				var gflag = arb.get("last_goal")
				var gdist = arb.get("last_goal_dist")
				var gfrac = arb.get("_goal_frac")
				print("    ECON step=%d t=%.2f kind=%s pos=(%.0f,%.0f) value=%.2f score=%.2f risk=%.2f flags=%d | arb_goal=%s gd=%.0f gfrac=%.2f" % [
						step, t, str(estate.get("kind", "")), float(estate["pos"].x),
						float(estate["pos"].y), float(estate.get("value", 0.0)),
						float(estate.get("score", 0.0)), float(estate.get("risk", 0.0)),
						int(estate.get("flags", 0)), str(gflag), float(gdist if gdist != null else -1.0),
						float(gfrac if gfrac != null else 0.0)])
		if scn.has("special_watch"):
			special_min = min(special_min, p.distance_to(scn["special_watch"]))

		# -- choose movement --
		var dir = Vector2.ZERO
		if policy == "proto":
			var pb = proto_choose(p, enemies, bullets, far, speed, proto_state)
			if pb != null:
				dir = pb
			else:
				dir = arb.choose(p, speed, BODY_R, far, threats, replay_rewards,
						targets_now, [], wrange_now, false, hp, 1.0, prof)
			if int(proto_state["active"]) > 0:
				breakout_s += DT
		elif policy == "goal":
			var g = goal_choose(p, enemies, rewards, far, speed, proto_state)
			if g != null:
				dir = g
			else:
				dir = arb.choose(p, speed, BODY_R, far, threats, replay_rewards,
						targets_now, [], wrange_now, false, hp, 1.0, prof)
		elif policy == "oracle":
			oracle_hold -= 1
			if oracle_hold <= 0:
				oracle_last = oracle_choose(p, enemies, far, speed)
				oracle_hold = 12
			dir = oracle_last
		else:
			dir = arb.choose(p, speed, BODY_R, far, threats, replay_rewards,
					targets_now, [], wrange_now, false, hp, 1.0, prof)
			if arb.last_breakout:
				breakout_s += DT
		# -- instrumentation: snapshot the DECISION state of this frame --
		var snap = _snapshot(arb, p, dir, prev_dir, enemies, speed, far, t, targets_now, wrange_now)
		gap_min = min(gap_min, float(snap[6]))
		pre.push_back(snap)
		if pre.size() > CONTACT_MAX:
			pre.pop_front()
		if OS.get_environment("SIM_ALL") != "":
			_print_pre([snap], [int(snap[5])], enemies, BODY_R)
		# -- ONSET: what the first frames look like out of standstill ----------
		if arb != null and (step == 1 or step == 10 or step == 30 or step == 60 \
				or step == 120 or step == 180 or step == 240 or step == 300) \
				and not enemies.empty():
			var e0 = enemies[0]
			var e0d = p.distance_to(e0["pos"])
			print("    ONSET step=%d t=%.2f bodydist=%.1f model_rad=%.1f real_rad=%.1f stand_T=%.2f chosen=(%+.2f,%+.2f) T=%.2f kill_rew=%.2f | %s" % [
					step, t, e0d, float(e0["radius"]), float(e0["hit_radius"]),
					snap[10], dir.x, dir.y, snap[9], float(snap[21]), snap[12]])
		# -- cost decomposition on the approach frames (the fatal decision) --
		if first_contact_t < 0.0 and float(snap[24]) < 70.0 and step % 10 == 0 and arb != null:
			_prime_probe(arb, p, speed, far, replay_rewards, targets_now,
					wrange_now, hp, prev_dir, dir, snap, t, threats)
		prev_dir = dir
		p += dir * speed * DT
		p.x = clamp(p.x, BODY_R, far.x - BODY_R)
		p.y = clamp(p.y, BODY_R, far.y - BODY_R)

		# -- enemy pursuit + contact hits --
		var touching = false
		var touchers = []
		for ei in range(enemies.size()):
			var e = enemies[ei]
			var stop = float(e["hit_radius"]) + BODY_R
			var to = p - e["pos"]
			var d = to.length()
			if d > stop:
				e["pos"] += to / d * float(e["speed"]) * DT
			if d <= stop + 2.0:
				touching = true
				touchers.push_back(ei)
				e["cd"] = float(e["cd"]) - DT
				if float(e["cd"]) <= 0.0:
					hp -= float(e["dmg"])
					e["cd"] = 0.7
					contact_hits += 1
					_print_hit(t, ei, e, p, hp, dir, contact_hits, pre)
			if bool(e.get("ranged", false)) and d < 480.0:
				e["shot_cd"] = float(e["shot_cd"]) - DT
				if float(e["shot_cd"]) <= 0.0:
					e["shot_cd"] = 1.6
					var bv2 = (p - e["pos"]).normalized() * 300.0
					bullets.push_back({"pos": e["pos"], "vel": bv2,
							"dmg": 4.0, "radius": 4.0})
		# -- player weapons: nearest body in weapon range takes DPS ----------
		if dps > 0.0 and wrange_now > 0.0 and not enemies.empty():
			var wbest = -1
			var wbd = 1e18
			for wi in range(enemies.size()):
				var wd = p.distance_to(enemies[wi]["pos"])
				if wd <= wrange_now and wd < wbd:
					wbd = wd
					wbest = wi
			if wbest >= 0:
				enemies[wbest]["hp"] = float(enemies[wbest]["hp"]) - dps * DT
				if float(enemies[wbest]["hp"]) <= 0.0:
					if trace:
						print("    KILL t=%.2f body_hp<=0 dmg=%.0f p=(%.0f,%.0f)" % [
								t, float(enemies[wbest]["dmg"]), p.x, p.y])
					enemies.remove(wbest)
					kills += 1
		if touching:
			contact_s += DT
			contact_frames += 1
			if first_contact_t < 0.0:
				first_contact_t = t
				print("=== FIRST CONTACT t=%.2f p=(%.1f,%.1f) policy=%s scn=%s hp=%.0f ===" % [
						t, p.x, p.y, policy, scn["name"], hp])
				_print_pre(pre, touchers, enemies, BODY_R)
			elif contact_frames <= 12 or contact_frames % 10 == 0:
				print("    CONTACT t=%.2f bodies=%s p=(%.1f,%.1f) hp=%.0f" % [
						t, str(touchers), p.x, p.y, hp])
		hp_min = min(hp_min, hp)
		if trace and hp <= 0.0:
			print("    DEAD t=%.1f p=(%.0f,%.0f) near=%.1f enemies=%d" % [t, p.x, p.y, mind, enemies.size()])
		if hp <= 0.0:
			_last_breakout_s = breakout_s
			_last_items = items_picked
			_last_first_t = first_pick_t
			_store_edge(edge_min, edge_sum, edge_n, edge_under_150, edge_under_100)
			_last_special_min = special_min
			return result(false, t, hp_min, contact_s, surrounded_s, mind, max_near,
					first_contact_t, contact_hits, gap_min, kills)

		# -- bullets --
		var keep = []
		for b in bullets:
			b["pos"] += b["vel"] * DT
			var bp = b["pos"]
			if p.distance_to(bp) < float(b["radius"]) + 20.0:
				hp -= float(b["dmg"])
				continue
			if bp.x < -100.0 or bp.x > far.x + 100.0 or bp.y < -100.0 or bp.y > far.y + 100.0:
				continue
			keep.push_back(b)
		bullets = keep

		# -- spawns --
		t += DT
		if scn["spawn"] != null and t >= next_spawn and enemies.size() < int(scn["spawn"]["max"]):
			next_spawn += float(scn["spawn"]["every"])
			for _i in range(int(scn["spawn"]["count"])):
				var a = rng.randf() * TAU
				enemies.push_back({
					"pos": p + Vector2(cos(a), sin(a)) * float(scn["spawn"]["radius"]),
					"speed": float(scn["spawn"]["speed"]), "radius": 14.0,
					"hit_radius": 14.0,
					"dmg": float(scn["spawn"]["dmg"]), "cd": 0.0,
					"ranged": false, "shot_cd": rng.randf_range(0.4, 1.6),
				})
		if scn["bullets"] != null and t >= next_bullet:
			next_bullet += float(scn["bullets"]["every"])
			var edge = rng.randi() % 4
			var bp2 = Vector2.ZERO
			if edge == 0:
				bp2 = Vector2(rng.randf() * far.x, -40.0)
			elif edge == 1:
				bp2 = Vector2(far.x + 40.0, rng.randf() * far.y)
			elif edge == 2:
				bp2 = Vector2(rng.randf() * far.x, far.y + 40.0)
			else:
				bp2 = Vector2(-40.0, rng.randf() * far.y)
			var aim = p + Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)) \
					* 260.0 * float(scn["bullets"]["random"])
			var bv = (aim - bp2).normalized() * float(scn["bullets"]["speed"])
			bullets.push_back({"pos": bp2, "vel": bv,
					"dmg": scn["bullets"]["dmg"], "radius": scn["bullets"]["radius"]})
		var kept = []
		for rw in rewards:
			var mi = rw.size() - 1
			var reach = 30.0
			if rw.size() > 4 and float(rw[3]) > 0.0:
				reach = min(40.0, float(rw[3]))
			if int(rw[mi]) == 0 and p.distance_to(rw[0]) < reach:
				rw[mi] = 1
				items_picked += 1
				if first_pick_t < 0.0:
					first_pick_t = t
				continue
			kept.push_back(rw)
		rewards = kept
		replay_rewards = []
		for rw in rewards:
			var rr = []
			for x in rw:
				rr.push_back(x)
			rr.remove(rr.size() - 1)
			replay_rewards.push_back(rr)
		nearest_end = mind
		var edge_now = min(min(p.x - BODY_R, far.x - BODY_R - p.x),
				min(p.y - BODY_R, far.y - BODY_R - p.y))
		edge_min = min(edge_min, edge_now)
		edge_sum += edge_now
		edge_n += 1
		if edge_now < 150.0:
			edge_under_150 += DT
		if edge_now < 100.0:
			edge_under_100 += DT
		var trace_now = trace and step > 0 and ((step % 60 == 0) or (arb != null and arb.last_breakout and step % 10 == 0))
		if trace_now:
			var extra = ""
			if arb != null:
				extra = " breakout=%s free=(%.2f,%.2f) bdir=(%.2f,%.2f) dir=(%.2f,%.2f) goal=%s" % [
						str(arb.last_breakout), arb.last_breakout_free_now,
						arb.last_breakout_free_fut, arb._breakout_dir.x,
						arb._breakout_dir.y, dir.x, dir.y, str(arb.last_goal)]
			print("    t=%.1f p=(%.0f,%.0f) near=%.1f near120=%d enemies=%d%s" % [
					t, p.x, p.y, mind, near_120, enemies.size(), extra])

	_last_breakout_s = breakout_s
	_last_items = items_picked
	_last_first_t = first_pick_t
	_store_edge(edge_min, edge_sum, edge_n, edge_under_150, edge_under_100)
	_last_special_min = special_min
	return result(true, t, hp_min, contact_s, surrounded_s, nearest_end, max_near,
			first_contact_t, contact_hits, gap_min, kills)


func _store_edge(edge_min, edge_sum, edge_n, e150, e100):
	_last_edge_min = edge_min
	_last_edge_mean = edge_sum / max(float(edge_n), 1.0)
	_last_edge_150 = e150
	_last_edge_100 = e100


func result(alive, t, hp_min, contact_s, surrounded_s, nearest_end, max_near,
		first_contact_t = -1.0, contact_hits = 0, gap_min = 1e9, kills = 0):
	return {"alive": alive, "t": t, "hp_min": max(hp_min, 0.0),
			"contact_s": contact_s, "surrounded_s": surrounded_s,
			"nearest_end": nearest_end, "max_near": max_near, "breakout_s": _last_breakout_s,
			"items_picked": _last_items, "first_pick_t": _last_first_t,
			"edge_min": _last_edge_min, "edge_mean": _last_edge_mean,
			"edge_150": _last_edge_150, "edge_100": _last_edge_100,
			"special_min": _last_special_min,
			"first_contact": first_contact_t, "contact_hits": contact_hits,
			"gap_min": gap_min, "kills": kills}


# -- reference policy: 2 s pursuit rollout over 24 headings -----------------
# Not shippable (it is a full forward model), but it is what a human eye does:
# "which line keeps the most clearance from every pursuer, walls included".
func oracle_choose(p, enemies, far, speed):
	var best_score = -1e18
	var best_dir = Vector2.ZERO
	for k in range(24):
		var a = float(k) * TAU / 24.0
		var d = Vector2(cos(a), sin(a))
		var p2 = p
		var pos2 = []
		for e in enemies:
			pos2.push_back(e["pos"])
		var worst = 1e9
		for step in range(60):    # 2.0 s at 30 Hz
			p2 += d * speed * (1.0 / 30.0)
			p2.x = clamp(p2.x, BODY_R, far.x - BODY_R)
			p2.y = clamp(p2.y, BODY_R, far.y - BODY_R)
			var wall = min(min(p2.x - BODY_R, far.x - BODY_R - p2.x),
					min(p2.y - BODY_R, far.y - BODY_R - p2.y))
			worst = min(worst, wall)
			for i in range(enemies.size()):
				var e = enemies[i]
				var to = p2 - pos2[i]
				var dist = to.length()
				if dist > float(e["radius"]) + 20.0:
					pos2[i] += to / dist * float(e["speed"]) * (1.0 / 30.0)
				worst = min(worst, p2.distance_to(pos2[i]) - float(e["radius"]) - 20.0)
		var final_clear = 1e9
		for i in range(enemies.size()):
			final_clear = min(final_clear,
					p2.distance_to(pos2[i]) - float(enemies[i]["radius"]) - 20.0)
		var score = worst + 0.5 * final_clear
		if score > best_score:
			best_score = score
			best_dir = d
	return best_dir



# -- prototype policy: predictive breakout ---------------------------------
# Stands in for the planned v2.5 arbiter mode, implemented here first so the
# CONCEPT can be validated before it is wired into the real cost function.
# Trigger: the ring the bot is inside will be closed soon, while a passable
# gap exists NOW. Then commit to the rollout heading that keeps the most
# clearance over 1.6 s, re-checked every 6 frames.
func enclosure_forecast(p, enemies, T):
	# Project pursuers at T toward the CURRENT position (they cannot know our
	# future heading); bin them into 16 sectors around us at ring distance.
	var bins = []
	for k in range(16):
		bins.push_back(false)
	for e in enemies:
		var to = p - e["pos"]
		var d = to.length()
		if d > 700.0:
			continue
		var proj = e["pos"]
		if d > 1.0:
			proj = e["pos"] + to / d * min(float(e["speed"]) * T, d)
		if p.distance_to(proj) > 320.0:
			continue
		var a = (proj - p).angle()
		var sec = int(round((a + PI) / TAU * 16.0)) % 16
		bins[sec] = true
	var occ = 0
	for b in bins:
		if b:
			occ += 1
	return 1.0 - float(occ) / 16.0


func rollout_best_heading(p, enemies, far, speed, T):
	var best = -1e18
	var best_dir = Vector2.ZERO
	for k in range(16):
		var a = float(k) * TAU / 16.0
		var d = Vector2(cos(a), sin(a))
		var p2 = p
		var pos2 = []
		for e in enemies:
			pos2.push_back(e["pos"])
		var worst = 1e9
		var steps = int(T * 30.0)
		for step in range(steps):
			p2 += d * speed * (1.0 / 30.0)
			p2.x = clamp(p2.x, BODY_R, far.x - BODY_R)
			p2.y = clamp(p2.y, BODY_R, far.y - BODY_R)
			worst = min(worst, min(min(p2.x - BODY_R, far.x - BODY_R - p2.x),
					min(p2.y - BODY_R, far.y - BODY_R - p2.y)))
			for i in range(enemies.size()):
				var e = enemies[i]
				var to = p2 - pos2[i]
				var dist = to.length()
				if dist > float(e["radius"]) + 20.0:
					pos2[i] += to / dist * float(e["speed"]) * (1.0 / 30.0)
				worst = min(worst, p2.distance_to(pos2[i]) - float(e["radius"]) - 20.0)
		var score = worst
		if score > best:
			best = score
			best_dir = d
	if best < -6.0:
		return null
	return best_dir


func proto_choose(p, enemies, bullets, far, speed, st):
	# active breakout: keep the committed heading, exit early if clear.
	if int(st["active"]) > 0:
		st["active"] = int(st["active"]) - 1
		if int(st["active"]) <= 0:
			st["cooldown"] = 20
		return st["dir"]
	if int(st["cooldown"]) > 0:
		st["cooldown"] = int(st["cooldown"]) - 1
	var f_now = enclosure_forecast(p, enemies, 0.0)
	var f_fut = enclosure_forecast(p, enemies, 1.8)
	if f_fut >= 0.70 and f_now >= 0.45 and enemies.size() >= 6:
		var d = rollout_best_heading(p, enemies, far, speed, 1.6)
		if d != null:
			st["active"] = 24
			st["dir"] = d
			return d
	return null



# -- prototype policy: committed item goal ---------------------------------
# Crude stand-in for the planned macro planner: pick the best uncollected
# reward, and while the neighbourhood is calm (no chaser within 300 px) walk
# straight at it; hand control back to the arbiter when anything closes in.
func goal_choose(p, enemies, rewards, far, speed, st):
	var best_i = -1
	var best_u = -1.0
	for i in range(rewards.size()):
		var rw = rewards[i]
		if int(rw[rw.size() - 1]) == 1:
			continue
		var d = p.distance_to(rw[0])
		var u = float(rw[1]) / (1.0 + d / 320.0)
		if u > best_u:
			best_u = u
			best_i = i
	if best_i < 0:
		return null
	var goal_pos = rewards[best_i][0]
	var nearest = 1e9
	for e in enemies:
		nearest = min(nearest, p.distance_to(e["pos"]))
	if nearest < 300.0:
		return null
	var to = goal_pos - p
	if to.length() < 8.0:
		return null
	return to.normalized()


# -- contact instrumentation helpers ---------------------------------------
# One compact decision snapshot per frame, kept in a rolling buffer so the
# frames BEFORE a contact event can be printed (the fatal decision is not the
# contact frame, it is the approach).
# Layout: 0 t, 1 px, 2 py, 3 dir.x, 4 dir.y, 5 nearest-body index,
# 6 nearest-body modelled clearance (current, px), 7 chosen-dir predicted
# clearance to that body over the arbiter horizon (px), 8 t of that closest
# approach, 9 chosen cost, 10 stand cost, 11 cost of the candidate aimed
# straight at the body, 12 mode flags string, 13 full scores, 14 full dirs,
# 15 chosen candidate index, 16 into-body candidate index.
func _snapshot(arb, p, dir, prev_dir, enemies, speed, far, t, targets, wrange):
	var nb = -1
	var nb_gap = 1e9
	for i in range(enemies.size()):
		var g = p.distance_to(enemies[i]["pos"]) - (float(enemies[i]["radius"]) + BODY_R)
		if g < nb_gap:
			nb_gap = g
			nb = i
	var nb_real = 1e9
	for i in range(enemies.size()):
		var gr = p.distance_to(enemies[i]["pos"]) \
				- (float(enemies[i]["hit_radius"]) + BODY_R)
		nb_real = min(nb_real, gr)
	var pred = [1e9, 0.0]
	if dir != Vector2.ZERO and nb >= 0:
		pred = _pred_clear_one(p, dir, speed, far, enemies[nb])
	var scores = []
	var dirs = []
	var best_i = -1
	var best_cost = 1e9
	var stand_cost = 1e9
	var into_i = -1
	var into_cost = 1e9
	var flags = "arb=none"
	if arb != null:
		scores = arb.last_scores.duplicate()
		dirs = arb.last_dirs.duplicate()
		best_i = int(arb.last_best_index)
		if best_i >= 0 and best_i < scores.size():
			best_cost = float(scores[best_i])
		for k in range(dirs.size()):
			if dirs[k] == Vector2.ZERO:
				stand_cost = float(scores[k])
				break
		if nb >= 0:
			var bearing = enemies[nb]["pos"] - p
			if bearing.length() > 0.001:
				bearing = bearing.normalized()
				var bestdot = -2.0
				for k in range(dirs.size()):
					var dd = dirs[k]
					if dd == Vector2.ZERO:
						continue
					var dot = dd.dot(bearing)
					if dot > bestdot:
						bestdot = dot
						into_i = k
				if into_i >= 0:
					into_cost = float(scores[into_i])
		flags = "brk=%d/%s freeN=%.2f freeF=%.2f goal=%d gd=%.0f gfrac=%.2f bounty=%d bd=%.0f esc=%d hop=%d standok=%d plan=%d adapt=%d stillgap=%.2f" % [
				1 if arb.last_breakout else 0, arb.last_breakout_reason,
				arb.last_breakout_free_now, arb.last_breakout_free_fut,
				1 if arb.last_goal else 0, arb.last_goal_dist, arb._goal_frac,
				1 if arb.last_bounty else 0, arb.last_bounty_dist,
				1 if arb.last_escaping else 0, 1 if arb.last_hop else 0,
				1 if arb.last_stand_ok else 0, 1 if arb.last_plan_used else 0,
				1 if arb.last_adapt else 0, arb.last_still_gap]
	# --- arbiter's OWN first-ply model: constant threat velocity (see _cost) ---
	# This is the number the shipped scorer actually prices contact with; the
	# pursuit-integrated prediction above is what the body really does.
	var chosen_cv = 1e9
	var chosen_cv_t = 0.0
	var away_cost = 1e9
	var safe_min = 1e9
	var away_i = -1
	if arb != null and nb >= 0:
		var radii = float(enemies[nb]["radius"]) + BODY_R
		var tpos = enemies[nb]["pos"]
		var tvel = Vector2.ZERO
		var td = p.distance_to(tpos)
		if td > 0.001:
			tvel = (p - tpos) / td * float(enemies[nb]["speed"])
		var bearing = tpos - p
		if bearing.length() > 0.001:
			bearing = bearing.normalized()
		var awaydot = -2.0
		for k in range(dirs.size()):
			var cd = dirs[k]
			if cd == Vector2.ZERO:
				continue
			var pe = p + cd * speed * 0.8
			pe.x = clamp(pe.x, BODY_R, far.x - BODY_R)
			pe.y = clamp(pe.y, BODY_R, far.y - BODY_R)
			var veff = (pe - p) / 0.8
			var w = tpos - p
			var rel = tvel - veff
			var tt = 0.0
			var den = rel.length_squared()
			if den > 0.000001:
				tt = clamp(-w.dot(rel) / den, 0.0, 0.8)
			var miss = w + rel * tt
			var cv = miss.length() - radii
			if k == best_i:
				chosen_cv = cv
				chosen_cv_t = tt
			if cv > 100.0 and float(scores[k]) < safe_min:
				safe_min = float(scores[k])
			var ad = cd.dot(-bearing)
			if ad > awaydot:
				awaydot = ad
				away_i = k
		if away_i >= 0:
			away_cost = float(scores[away_i])
	# --- reward accounting for the chosen and the pure-away candidate ---
	var kill_chosen = _kill_reward(p + dir * speed * 0.8, targets, wrange)
	var kill_away = 1e9
	if away_i >= 0:
		kill_away = _kill_reward(p + dirs[away_i] * speed * 0.8, targets, wrange)
	var hyst_chosen = 0.0
	if arb != null and prev_dir != Vector2.ZERO and dir != Vector2.ZERO:
		hyst_chosen = 1.2 * dir.dot(prev_dir)
	return [t, p.x, p.y, dir.x, dir.y, nb, nb_gap, pred[0], pred[1],
			best_cost, stand_cost, into_cost, flags, scores, dirs, best_i, into_i,
			chosen_cv, chosen_cv_t, away_cost, safe_min, kill_chosen, kill_away,
			hyst_chosen, nb_real]


# Chosen candidate's predicted closest clearance to ONE body, integrated at the
# sim's own 60 Hz with the body pursuing our projected path (the arbiter's own
# model, reproduced so the numbers in the log are comparable to its horizon).
func _pred_clear_one(p, d, speed, far, enemy):
	var p2 = p
	var epos = enemy["pos"]
	var stop = float(enemy["radius"]) + BODY_R
	var best = 1e9
	var best_t = 0.0
	var steps = int(round(0.8 / DT))
	for step in range(steps):
		p2 += d * speed * DT
		p2.x = clamp(p2.x, BODY_R, far.x - BODY_R)
		p2.y = clamp(p2.y, BODY_R, far.y - BODY_R)
		var to = p2 - epos
		var dist = to.length()
		if dist > stop:
			epos += to / dist * float(enemy["speed"]) * DT
		var cl = p2.distance_to(epos) - stop
		if cl < best:
			best = cl
			best_t = float(step + 1) * DT
	return [best, best_t]


func _print_pre(pre, touchers, enemies, body_r):
	var n = pre.size()
	var first = max(0, n - 40)
	for k in range(first, n):
		var sn = pre[k]
		var nb = int(sn[5])
		var nbdmg = 0.0
		if nb >= 0 and nb < enemies.size():
			nbdmg = float(enemies[nb]["dmg"])
		print("    PRE t=%.2f p=(%.1f,%.1f) nb=%d dmg=%.0f mgap=%6.2f rgap=%6.2f pred=%6.2f@%.2f cv=%6.2f@%.2f dir=(%+.2f,%+.2f) best=%.2f stand=%.2f into=%.2f safe=%.2f away=%.2f kill=%.2f/%.2f hyst=%.2f ci=%d ii=%d | %s" % [
				sn[0], sn[1], sn[2], nb, nbdmg, sn[6], sn[24], sn[7], sn[8],
				sn[17], sn[18], sn[3], sn[4], sn[9], sn[10], sn[11],
				sn[20], sn[19], sn[21], sn[22], sn[23],
				int(sn[15]), int(sn[16]), sn[12]])


func _print_hit(t, ei, e, p, hp, dir, n, pre):
	var gap = p.distance_to(e["pos"]) - (float(e["radius"]) + BODY_R)
	var last = ""
	if pre.size() > 0:
		var sn = pre[pre.size() - 1]
		last = "prev: dir=(%+.2f,%+.2f) best=%.2f stand=%.2f into=%.2f nb_gap=%.2f pred=%6.2f@%.2f | %s" % [
				sn[3], sn[4], sn[9], sn[10], sn[11], sn[6], sn[7], sn[8], sn[12]]
	print("    CONTACT-HIT #%d t=%.2f body=%d dmg=%.1f gap=%.2f dir=(%+.2f,%+.2f) hp=%.0f %s" % [
			n, t, ei, float(e["dmg"]), gap, dir.x, dir.y, hp, last])


# Reproduce the arbiter's kill/DPS reward for one end position (KILL_SOFT /
# ACQUIRE_BAND constants, w_dps default 14). Used only for the log's cost
# breakdown, never fed back into the sim.
func _kill_reward(p_end, targets, wrange):
	if targets.empty() or wrange <= 0.0:
		return 0.0
	var kill_gain = 0.0
	for t in targets:
		var dist = p_end.distance_to(t[0])
		if dist > wrange + 220.0:
			continue
		var reach = 1.0
		if dist > wrange:
			reach = 1.0 - (dist - wrange) / 220.0
		kill_gain += float(t[1]) * reach
	if kill_gain <= 0.0:
		return 0.0
	return 14.0 * (1.0 - exp(-kill_gain / 40.0))


# -- cost decomposition at the fatal decision -------------------------------
# Calls the REAL arbiter _cost() with each weight zeroed in turn, so the term
# breakdown is exact (each term is additive in its weight) rather than a
# re-derivation. Also re-scans the SAME candidate set with w_dps=0: that is
# what the same frame would have chosen without the kill reward.
func _sort_pair(a, b):
	return a[0] < b[0]


func _prime_probe(arb, p, speed, far, rewards, targets, wrange, hp, prev_dir,
		dir, snap, t, threats):
	# Full per-term decomposition for the chosen direction and 5 alternatives.
	# contact/proj/dash are BAKED into _p_coef by _prepare(), so every weight
	# probe needs a fresh _prepare(); _cost is additive in each weight.
	var saved_last_dir = arb.last_dir
	arb.last_dir = prev_dir
	var alts = []
	alts.push_back(["chosen", dir])
	if int(snap[5]) >= 0 and int(snap[5]) < threats.size():
		var bv = threats[int(snap[5])][0] - p
		var bl = bv.length()
		if bl > 0.001:
			var bu = bv / bl
			var pu = Vector2(-bu.y, bu.x)
			var mu = Vector2(bu.y, -bu.x)
			var dirs = arb.last_dirs
			var best_away = Vector2.ZERO
			var best_into = Vector2.ZERO
			var best_p = Vector2.ZERO
			var best_m = Vector2.ZERO
			var da = -2.0
			var di = -2.0
			var dp = -2.0
			var dm = -2.0
			for k in range(dirs.size()):
				var cd = dirs[k]
				if cd == Vector2.ZERO:
					continue
				if -cd.dot(bu) > da:
					da = -cd.dot(bu)
					best_away = cd
				if cd.dot(bu) > di:
					di = cd.dot(bu)
					best_into = cd
				if cd.dot(pu) > dp:
					dp = cd.dot(pu)
					best_p = cd
				if cd.dot(mu) > dm:
					dm = cd.dot(mu)
					best_m = cd
			alts.push_back(["away", best_away])
			alts.push_back(["into", best_into])
			alts.push_back(["tang+", best_p])
			alts.push_back(["tang-", best_m])
	alts.push_back(["stand", Vector2.ZERO])
	# normal totals
	arb._prepare(p, speed, BODY_R, threats, hp, 1.0)
	var totals = []
	for a in alts:
		totals.push_back(arb._cost(a[1], p, speed, BODY_R, far, rewards, targets,
				[], wrange, false, hp))
	var pairs = [["contact", "w_contact"], ["room", "w_room"],
			["roomfar", "w_room_far"], ["wall", "w_wall"], ["space", "w_space"],
			["enclose", "w_enclose"], ["dps", "w_dps"], ["pickup", "w_pickup"],
			["hyst", "w_hyst"], ["kite", "w_kite"], ["goal", "w_goal"]]
	var term_vals = {}
	for pr in pairs:
		var saved = arb.get(pr[1])
		arb.set(pr[1], 0.0)
		arb._prepare(p, speed, BODY_R, threats, hp, 1.0)
		var vals = []
		for a in alts:
			vals.push_back(totals[alts.find(a)] - arb._cost(a[1], p, speed,
					BODY_R, far, rewards, targets, [], wrange, false, hp))
		arb.set(pr[1], saved)
		term_vals[pr[0]] = vals
	arb._prepare(p, speed, BODY_R, threats, hp, 1.0)
	arb.last_dir = saved_last_dir
	var bdist = -1.0
	var bdirs = "?"
	if int(snap[5]) >= 0 and int(snap[5]) < threats.size():
		var bb = threats[int(snap[5])][0] - p
		bdist = bb.length()
		if bdist > 0.001:
			bdirs = "(%+.2f,%+.2f)" % [bb.x / bdist, bb.y / bdist]
	print("    DECOMP t=%.2f rgap=%6.2f mgap=%6.2f bdist=%6.1f bodydir=%s prev=(%+.2f,%+.2f) | terms: contact room roomfar wall space enclose kite dps hyst goal pickup" % [
			t, float(snap[24]), float(snap[6]), bdist, bdirs, prev_dir.x, prev_dir.y])
	for i in range(alts.size()):
		var a = alts[i]
		print("      ALT %-7s d=(%+.2f,%+.2f) T=%7.2f | %6.2f %5.2f %6.2f %5.2f %5.2f %6.2f %5.2f %6.2f %5.2f %5.2f %6.2f" % [
				a[0], a[1].x, a[1].y, totals[i],
				term_vals["contact"][i], term_vals["room"][i],
				term_vals["roomfar"][i], term_vals["wall"][i],
				term_vals["space"][i], term_vals["enclose"][i],
				term_vals["kite"][i], term_vals["dps"][i],
				term_vals["hyst"][i], term_vals["goal"][i],
				term_vals["pickup"][i]])




func new_arbiter():
	# Round-7: the arm under test is selectable (HEAD = res://arbiter.gd, frozen
	# releases = res://arms/arb_v*.gd); the config path is selectable too:
	#   SIM_CFG=bare    (default) bare Arbiter.new() -- legacy econ=0 path
	#   SIM_CFG=shipped Arbiter.new() + Config.parse({}, {}) + apply_config(cfg)
	#                   = the shipped default (econ=1), i.e. the REAL GAME path
	var path = OS.get_environment("SIM_SCRIPT")
	if path == "":
		path = "res://arbiter.gd"
	var A = load(path)
	if A == null:
		print("LOAD_FAIL ", path)
		return null
	var arb = A.new()
	if OS.get_environment("SIM_CFG") == "shipped":
		var C = load("res://mods-unpacked/Pasha-AutoBattler/steering/config.gd")
		if C == null:
			print("LOAD_FAIL config.gd (arm has no Config; ignoring SIM_CFG=shipped)")
		else:
			var cfg = C.new()
			cfg.parse({}, {})
			if arb.has_method("apply_config"):
				arb.apply_config(cfg)
			else:
				print("ARM has no apply_config; ignoring SIM_CFG=shipped")
	return arb
