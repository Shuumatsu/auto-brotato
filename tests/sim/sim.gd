extends SceneTree

# Closed-loop synthetic simulation for the v2.5 "planning" investigation.
#
# Purpose: reproduce, OUTSIDE the game, the two player reports --
#   (a) the bot is visibly about to be SURROUNDED and does not plan around it;
#   (b) it does not plan detours to high-value items.
# The bot under test is the REAL `arbiter.gd` (copied from the live mod by
# run.sh). The world is a deterministic toy: pursuing contact enemies (and,
# in some scenarios, straight bullets) on a walled rectangle, fixed 60 Hz.
#
# Policies:
#   greedy  = --arb-plan=0 --arb-adapt=0 (pre-v2.3.0 behaviour)
#   v240    = current live defaults (2-ply planner + adapt on)
#   oracle  = a 2 s pursuit-rollout over 24 headings, i.e. "what a human eye
#             does": pick the line that keeps the most future clearance from
#             every chaser, walls included. Upper bound, not a shippable policy.
#
# Exit code 0 always; this is a research instrument, not a gate.

const DT = 1.0 / 60.0
const K_CONTACT = 1
const K_PROJ = 0
const INF_TIME = 1e9
const BODY_R = 18.0

var fails = 0
var _last_breakout_s = 0.0
var _last_items = 0
var _last_first_t = -1.0
var _last_edge_min = 0.0
var _last_edge_mean = 0.0
var _last_edge_150 = 0.0
var _last_edge_100 = 0.0
var _last_special_min = 1e9
var _last_sp_reach = -1.0        # t at first d(special) <= desired+40, -1 = never
var _last_lock_s = 0.0           # seconds with a committed opp/bounty/goal active


func _init():
	print("=== planning-v250 closed-loop simulation ===")
	print("policy | scenario | alive | t | hp_min | contact_s | surrounded_s | nearest_end | max_near | breakout_s | items | edge_min | edge_mean | e<150 | e<100 | sp_min | sp_reach | lock_s")
	var only_scn = OS.get_environment("SIM_ONLY")
	var only_pol = OS.get_environment("SIM_POLICIES")
	for scn in scenarios():
		if only_scn != "" and scn["name"] != only_scn:
			continue
		var pols = scn.get("policies", ["greedy", "control", "v250", "oracle", "proto"])
		if only_pol != "":
			pols = only_pol.split(",")
		for pol in pols:
			var r = run_scenario(scn, pol)
			print("%-7s | %-22s | %-5s | %5.1f | %6.1f | %8.2f | %10.2f | %10.1f | %4d | %5.2f | %d@%.1fs | %6.1f | %6.1f | %5.2f | %5.2f | %6.1f | %8.2f | %6.2f" % [
				pol, scn["name"], str(r["alive"]), r["t"],
				r["hp_min"], r["contact_s"], r["surrounded_s"],
				r["nearest_end"], r["max_near"], r["breakout_s"],
				r["items_picked"], r["first_pick_t"],
				r["edge_min"], r["edge_mean"], r["edge_150"], r["edge_100"],
				r["special_min"], r["sp_reach"], r["lock_s"]])
	print("=== done ===")
	quit(0)


# -- scenarios -------------------------------------------------------------
# Each enemy: pos, speed, radius, dmg. The world is deterministic.
func scenarios():
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

	# -- v2.7 opportunity-layer measurements (design §4.4 / F1-F3) -------------
	# S1: special (value 30 = class 1 boss) 800 px east, ONE static body 250 px
	#     east (directly on the straight route). v2.6.1's bounty gate needs the
	#     nearest body >= BOUNTY_BODY_SAFE (300 px), so this body vetoes the
	#     approach entirely; v2.7 replaces the binary gate with a route-risk
	#     score. agg=1 default is the interesting arm, agg=0/2 the sweep.
	# S2: a class-2 special (value 40) 800 px east behind TWO static blockers at
	#     250 and 500 px on the route (3 dmg each: route risk 9.6, inside the
	#     agg=1 allowance 14 but outside agg=0's 4). The blockers are STATIC on
	#     purpose: a moving body (tested at 10/20/60 px/s) trips the v2.6.1
	#     tangent/orbit term and the legacy arm wanders east into the special
	#     by accident (measured sp_min ~40 px in ~2.5 s), which would contaminate
	#     the A/B; static blockers leave the legacy arm parked (sp_min 800).
	# S3: F3 -- high-value (8) loot alien 600 px east that flees straight away
	#     from the player at 120 px/s, capped by the arena walls. v2.6.1 has no
	#     velocity input for rewards; v2.7 gets the r[5] velocity and (design)
	#     intercepts. Metric: items@t = first catch time.
	list.push_back({
		"name": "opp_s1_blocker1",
		"far": Vector2(1600, 1200),
		"start": Vector2(600, 600),
		"player_speed": 320.0,
		"enemies": [{"pos": Vector2(850, 600), "speed": 0.0,
				"radius": 14.0, "dmg": 6.0}],
		"targets_from_enemies": false,
		"target_list": [[Vector2(1400, 600), 30.0, false, 1]],
		"special_watch": Vector2(1400, 600),
		"weapon_range": 260.0,
		"profile": {"kite_frac": 0.75},
		"spawn": null, "bullets": null, "duration": 20.0,
		"policies": ["v26", "v27", "v27a0", "v27a2"],
	})

	list.push_back({
		"name": "opp_s2_blockers2",
		"far": Vector2(1800, 1200),
		"start": Vector2(500, 600),
		"player_speed": 320.0,
		"enemies": [
			{"pos": Vector2(750, 600), "speed": 0.0,
					"radius": 14.0, "dmg": 3.0},
			{"pos": Vector2(1000, 600), "speed": 0.0,
					"radius": 14.0, "dmg": 3.0},
		],
		"targets_from_enemies": false,
		"target_list": [[Vector2(1300, 600), 40.0, false, 2]],
		"special_watch": Vector2(1300, 600),
		"weapon_range": 260.0,
		"profile": {"kite_frac": 0.75},
		"spawn": null, "bullets": null, "duration": 20.0,
		"policies": ["v26", "v27"],
	})

	list.push_back({
		"name": "opp_s3_lootalien",
		"far": Vector2(2400, 1800),
		"start": Vector2(500, 900),
		"player_speed": 320.0,
		"enemies": [],
		"targets_from_enemies": false,
		# tag 4 = loot alien (world_view v2.8 packs the category at index 6 and
		# prices it 12 under cov=1; the v2.7 arms ignore index 6 and use 8).
		"flee_rewards": [{"pos": Vector2(1100, 900), "value": 8.0,
				"speed": 120.0, "tag": 4.0}],
		"profile": {"kite_frac": 0.0},
		"spawn": null, "bullets": null, "duration": 20.0,
		"policies": ["v26", "v27"],
	})

	# -- v2.8 coverage-layer informational probes (clearly NOT in-game values) --
	# opp_v34_plain: a raw 34-value walk-on reward 800 px east behind one static
	#     dmg-6 body 250 px on the route. This is the task-7 "value-34 generic
	#     reward" upper-bound probe: BOTH arms see 34 (no tag), so v27 and v28
	#     both clear the body risk (allowed 12.2 > 9.6) and pick it up. It says
	#     nothing about the v2.8 tag path by itself.
	# opp_v34_tagged: the same geometry, but with the reward tuple world_view
	#     v2.8 emits: [pos, raw 10 = LEGENDARY_BOX_VALUE, true, 0, 0, 0, tag 2].
	#     v27 (opp=1,cov=0) ignores index 6 and sees raw 10 -> allowed risk 5.0
	#     < 9.6 -> refuses the route; v28 (cov=1) prices tag 2 at 34 -> allowed
	#     12.2 > 9.6 -> commits and picks it up. This is a SYNTHETIC injection of
	#     the tuple world_view would produce (the sim bypasses world_view's tag
	#     packaging; no real crate/tag detection is simulated).
	list.push_back({
		"name": "opp_v34_plain",
		"far": Vector2(1600, 1200),
		"start": Vector2(600, 600),
		"player_speed": 320.0,
		"enemies": [{"pos": Vector2(850, 600), "speed": 0.0,
				"radius": 14.0, "dmg": 6.0}],
		"rewards": [[Vector2(1400, 600), 34.0, false, 45.0, 1.0]],
		"spawn": null, "bullets": null, "duration": 12.0,
		"policies": ["v27", "v28"],
	})

	list.push_back({
		"name": "opp_v34_tagged",
		"far": Vector2(1600, 1200),
		"start": Vector2(600, 600),
		"player_speed": 320.0,
		"enemies": [{"pos": Vector2(850, 600), "speed": 0.0,
				"radius": 14.0, "dmg": 6.0}],
		"rewards": [[Vector2(1400, 600), 10.0, true, 0.0, 0.0, 0.0, 2.0]],
		"spawn": null, "bullets": null, "duration": 12.0,
		"policies": ["v27", "v28"],
	})

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
	elif policy == "v26":
		# v2.6.1 behaviour: opportunity layer explicitly OFF. On code that
		# predates v2.7 there is no opp switch, so this is the default script.
		arb = new_arbiter()
		_set_switch(arb, "opp_enable", 0.0)
	elif policy == "v27" or policy == "v27a0" or policy == "v27a2":
		# EXACT v2.7.0: opp=1 + cov=0 + tapcd=0 (the v2.8 coverage layer and
		# the tap-CD sync both off). agg stays 1 (a<N> variants sweep agg 0/2).
		# tap_cd lives in world_view/movement and is not simulated here, but it
		# is set when present so the arm is contract-complete. Switches are
		# assigned directly: --arb-cov is not exposed via apply_overrides in the
		# frozen v2.7 reference, and this keeps the matrix output readable.
		arb = new_arbiter()
		var agg = 1.0
		if policy == "v27a0":
			agg = 0.0
		elif policy == "v27a2":
			agg = 2.0
		_set_switch(arb, "opp_enable", 1.0)
		_set_switch(arb, "opp_agg", agg)
		_set_switch(arb, "cov_enable", 0.0)
		_set_switch(arb, "tap_cd", 0.0)
	elif policy == "v28":
		# shipped v2.8.0 defaults: opp=1, agg=1, cov=1, tapcd=1. On the frozen
		# v2.7.0 reference the extra switches do not exist, so this is the v2.7
		# default script (used for the pinned-baseline run).
		arb = new_arbiter()
	elif policy == "v250" or policy == "proto" or policy == "goal":
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
	else:
		pass

	var far = scn["far"]
	var p = scn["start"]
	var speed = scn["player_speed"]
	var hp = 100.0
	var hp_min = 100.0
	var max_hp = 100.0
	var enemies = []
	for e in scn["enemies"]:
		enemies.push_back({
			"pos": e["pos"], "speed": e["speed"], "radius": e["radius"],
			"dmg": e["dmg"], "cd": 0.0,
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
	var rewards = []
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
	# v2.7 measurement scaffolding: reach threshold for a watched special (the
	# design's "desired + 40" firing-range edge), flee-reward bodies and the
	# commitment / first-reach metrics. Inactive (empty / -1) for legacy scenarios.
	var reach_desired = float(scn.get("reach_desired",
			max(replay_wrange * 0.9, 70.0)))
	var flee = []
	for fr in scn.get("flee_rewards", []):
		flee.push_back({"pos": fr["pos"], "value": float(fr.get("value", 8.0)),
				"speed": float(fr.get("speed", 120.0)), "vel": Vector2.ZERO,
				"tag": float(fr.get("tag", 0.0))})
	var sp_reach_t = -1.0
	var lock_s = 0.0
	_last_breakout_s = 0.0

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
			if dist > 900.0:
				continue
			var vel = Vector2.ZERO
			if dist > 0.001:
				vel = (p - epos) / dist * float(e["speed"])
			threats.push_back([epos, vel, float(e["radius"]), float(e["dmg"]),
					K_CONTACT, 0.0, 1.6, INF_TIME, 0.0])
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
			targets_now = []
			for e in enemies:
				if p.distance_to(e["pos"]) < 800.0:
					targets_now.push_back([e["pos"], 8.0, false])
			wrange_now = float(scn.get("weapon_range", 0.0))
		if scn.has("target_list"):
			targets_now = []
			for tl in scn["target_list"]:
				targets_now.push_back(tl)
		var prof = scn.get("profile", {})
		prof["hp_ratio"] = hp / 100.0
		if scn.has("special_watch"):
			special_min = min(special_min, p.distance_to(scn["special_watch"]))
			if sp_reach_t < 0.0 \
					and p.distance_to(scn["special_watch"]) <= reach_desired + 40.0:
				sp_reach_t = t
		# Static rewards plus any fleeing loot aliens. A fleeing reward is fed
		# with the v2.7 six-tuple (r[5] = velocity); v2.6.1 ignores the extras,
		# so one scenario definition is a fair A/B for both arms.
		var rewards_now = replay_rewards.duplicate()
		for fr in flee:
			var ft = [fr["pos"], fr["value"], true, 0.0, 0.0, fr["vel"]]
			if float(fr["tag"]) > 0.0:
				ft.push_back(float(fr["tag"]))    # v2.8 reward tag at index 6
			rewards_now.push_back(ft)

		# -- choose movement --
		var dir = Vector2.ZERO
		if policy == "proto":
			var pb = proto_choose(p, enemies, bullets, far, speed, proto_state)
			if pb != null:
				dir = pb
			else:
				dir = arb.choose(p, speed, BODY_R, far, threats, rewards_now,
						targets_now, [], wrange_now, false, hp, 1.0, prof)
			if int(proto_state["active"]) > 0:
				breakout_s += DT
		elif policy == "goal":
			var g = goal_choose(p, enemies, rewards, far, speed, proto_state)
			if g != null:
				dir = g
			else:
				dir = arb.choose(p, speed, BODY_R, far, threats, rewards_now,
						targets_now, [], wrange_now, false, hp, 1.0, prof)
		elif policy == "oracle":
			oracle_hold -= 1
			if oracle_hold <= 0:
				oracle_last = oracle_choose(p, enemies, far, speed)
				oracle_hold = 12
			dir = oracle_last
		else:
			dir = arb.choose(p, speed, BODY_R, far, threats, rewards_now,
					targets_now, [], wrange_now, false, hp, 1.0, prof)
			if arb.last_breakout:
				breakout_s += DT
		if arb != null:
			# Commitment telemetry: v2.7 opp layer (last_opp) or the legacy
			# v2.6 bounty/goal commitments. One "locked" definition for both arms.
			var locked = arb.last_bounty or arb.last_goal
			if "last_opp" in arb and arb.last_opp:
				locked = true
			if locked:
				lock_s += DT
		p += dir * speed * DT
		p.x = clamp(p.x, BODY_R, far.x - BODY_R)
		p.y = clamp(p.y, BODY_R, far.y - BODY_R)

		# -- enemy pursuit + contact hits --
		var touching = false
		for e in enemies:
			var stop = float(e["radius"]) + 20.0
			var to = p - e["pos"]
			var d = to.length()
			if d > stop:
				e["pos"] += to / d * float(e["speed"]) * DT
			if d <= stop + 2.0:
				touching = true
				e["cd"] = float(e["cd"]) - DT
				if float(e["cd"]) <= 0.0:
					hp -= float(e["dmg"])
					e["cd"] = 0.7
			if bool(e.get("ranged", false)) and d < 480.0:
				e["shot_cd"] = float(e["shot_cd"]) - DT
				if float(e["shot_cd"]) <= 0.0:
					e["shot_cd"] = 1.6
					var bv2 = (p - e["pos"]).normalized() * 300.0
					bullets.push_back({"pos": e["pos"], "vel": bv2,
							"dmg": 4.0, "radius": 4.0})
		if touching:
			contact_s += DT
		hp_min = min(hp_min, hp)
		if trace and hp <= 0.0:
			print("    DEAD t=%.1f p=(%.0f,%.0f) near=%.1f enemies=%d" % [t, p.x, p.y, mind, enemies.size()])
		if hp <= 0.0:
			_last_breakout_s = breakout_s
			_last_items = items_picked
			_last_first_t = first_pick_t
			_store_edge(edge_min, edge_sum, edge_n, edge_under_150, edge_under_100)
			_last_special_min = special_min
			_last_sp_reach = sp_reach_t
			_last_lock_s = lock_s
			return result(false, t, hp_min, contact_s, surrounded_s, mind, max_near)

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
		# -- fleeing loot aliens (F3) ------------------------------------------
		# Flee straight away from the player at `speed`, hard-capped by the
		# arena walls (the sim's stand-in for the real flee behaviour + walls).
		# Caught when the player's body gets within 30 px; r[5] reports the
		# ACTUAL post-cap velocity, matching what world_view v2.7 will push.
		var flee_kept = []
		for fr in flee:
			var fpos = fr["pos"]
			var fd = p.distance_to(fpos)
			var fvel = Vector2.ZERO
			if fd > 0.001:
				fvel = (fpos - p) / fd * float(fr["speed"])
			var npos = fpos + fvel * DT
			npos.x = clamp(npos.x, 14.0, far.x - 14.0)
			npos.y = clamp(npos.y, 14.0, far.y - 14.0)
			fr["vel"] = (npos - fpos) / DT
			fr["pos"] = npos
			if p.distance_to(npos) < 30.0:
				items_picked += 1
				if first_pick_t < 0.0:
					first_pick_t = t
				continue
			flee_kept.push_back(fr)
		flee = flee_kept
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
	_last_sp_reach = sp_reach_t
	_last_lock_s = lock_s
	return result(true, t, hp_min, contact_s, surrounded_s, nearest_end, max_near)


func _store_edge(edge_min, edge_sum, edge_n, e150, e100):
	_last_edge_min = edge_min
	_last_edge_mean = edge_sum / max(float(edge_n), 1.0)
	_last_edge_150 = e150
	_last_edge_100 = e100


func result(alive, t, hp_min, contact_s, surrounded_s, nearest_end, max_near):
	return {"alive": alive, "t": t, "hp_min": max(hp_min, 0.0),
			"contact_s": contact_s, "surrounded_s": surrounded_s,
			"nearest_end": nearest_end, "max_near": max_near, "breakout_s": _last_breakout_s,
			"items_picked": _last_items, "first_pick_t": _last_first_t,
			"edge_min": _last_edge_min, "edge_mean": _last_edge_mean,
			"edge_150": _last_edge_150, "edge_100": _last_edge_100,
			"special_min": _last_special_min,
			"sp_reach": _last_sp_reach, "lock_s": _last_lock_s}


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


func new_arbiter():
	var A = load("res://arbiter.gd")
	if A == null:
		print("LOAD_FAIL arbiter.gd")
		return null
	return A.new()


# Set a script switch by name when the loaded arbiter actually carries it.
# Keeps one sim.gd working against v2.6.1/v2.7.0/v2.8.0 references (older code
# simply has no such property) without going through apply_overrides, which
# prints the full weight set and would bury the result matrix.
func _set_switch(arb, prop, value):
	if prop in arb:
		arb.set(prop, value)
