extends Reference

# =============================================================================
# config.gd -- THE single parser for `--arb-*` overrides.
#
# Step-1 structural refactor (task-5). Before this file existed the same key
# space was parsed in FOUR places:
#   * world_view.apply_overrides   (36 keys; "sweep" parsed twice by mistake)
#   * arbiter.apply_overrides      (60 keys)
#   * player_movement_behavior.gd  (overrides.get("every"))
#   * world_view._profile_mode()   (direct Utils.get_startup_arguments() read
#                                   for the STRING key --arb-profile)
# See _research/review-v3/arch/FINDINGS.md F-06 for the audit evidence.
#
# Public entry points:
#   cfg.parse(startup_args, node_overrides)   full parse (defaults first)
#   cfg.override(dict)                        partial apply, keeps earlier state
# Both are used by the modules' compatibility `apply_overrides()` wrappers (the
# offline harnesses call those); the shipped shell calls parse() once and then
# distributes single Config instance via WorldView.apply_config() /
# Arbiter.apply_config().
#
# CONFLICT SPLITS (the only intentional behaviour change of step 1; defaults are
# unchanged so the default build behaves exactly as before):
#   sweep / bladeunion / sweepmat
#       legacy "--arb-sweep=V" used to set BOTH the material quiet-field
#       multiplier (sweep_override) and the blade swept-union switch
#       (sweep_union). The legacy key keeps that exact old behaviour (and warns
#       once); the new granular keys are:
#           --arb-bladeunion=V -> sweep_union only
#           --arb-sweepmat=V   -> sweep_override only
#   orbit / orbitscan / orbitw
#       legacy "--arb-orbit=V" used to set BOTH the boss-attached-projectile
#       scan switch (world_view.orbit_scan) and the perimeter orbit weight
#       (arbiter.orbit_override). The legacy key keeps that exact old behaviour
#       (and warns once); the new granular keys are:
#           --arb-orbitscan=V  -> world_view.orbit_scan only
#           --arb-orbitw=V     -> arbiter.orbit_override only
#
# Unknown numeric keys are still accepted-and-ignored like before, but print one
# warning per key (old code was silent).
# =============================================================================

# Defaults that are also the public documentation of a switch. These two used to
# live as OPP_ENABLE/COV_ENABLE constants duplicated in world_view and arbiter.
const OPP_ENABLE_DEFAULT = 1.0
const COV_ENABLE_DEFAULT = 1.0


# ---- world_view-owned fields (WorldView.apply_config copies these) --------
var persist_max = 4.0
var aoe_clock = 1.0
var aoe_mult = 1.5
var blade_split = 1.0
var sweep_union = 1.0        # --arb-bladeunion (legacy --arb-sweep sets both)
var sine_sample = 1.0
var moving_clock = 1.0
var orbit_scan = 1.0         # --arb-orbitscan (legacy --arb-orbit sets both)
var moving_blade = 1.0
var bonus_speed_scan = 1.0
var dps_ref_scan = 1.0
var char_profile = 1.0
var gold_value_override = null
var gold_pickup_draw = 1.5
var anchor_inner_override = null
var leash_override = 0.0
var engage_hp_override = null
var caution_mult = 1.0
var tree_mult = 1.0
var food_mult = 2.5
var sweep_override = -1.0    # --arb-sweepmat (legacy --arb-sweep sets both)
var dash_fix = 1.0
var revive_mult = 1.0
var center_mode_override = 0.0
var curse_mult = 3.0
var evolved_mult = 2.5
var evo_mult = 1.0
var walk_tag = 1.0
var waveend_mult = 1.0
var bounty_tag = 1.0
var boxes_mult = 1.0
var windup_priced = 1.0
var hitbox_scan = 1.0
var opp_enable = OPP_ENABLE_DEFAULT    # shared with arbiter (one knob, one value)
var opp_agg = 1.0                      # shared with arbiter
var cov_enable = COV_ENABLE_DEFAULT    # shared with arbiter
var tap_cd = 1.0

# ---- v2.9 economy objective layer (world_view + arbiter + economy module) --
# Default ON: the economy layer is additive and every hook is guarded by
# `econ != 0.0`; --arb-econ=0 restores the exact v2.8.0 code path (no extra
# reward tuple fields, no planner). See _research/review-v3/econ/IMPL-SPEC.md.
var econ = 1.0
var econ_hp_floor = 0.2
var econ_risk_base = 0.6
var econ_risk_hp = 2.4
var econ_margin = 0.3
var econ_eta_cost = 0.5
var econ_deadline_margin = 1.5
var econ_deadline_boost = 2.0
var econ_deadline_cap = 3.0
# v2.10.0: 1 = v2.9.1 behaviour (the wave-end deadline factor is applied TWICE,
# once inside economy.gd's price and again in econ_planner.gd -> value up to
# 9x near the horn); 0 = fixed, the planner is the only deadline owner.
var econ_dl = 0.0
var econ_sweep_secs = 6.0
var econ_gather_range = 2000.0
var econ_candidate_cap = 60
var econ_xp = 0.2

# ---- arbiter-owned fields (Arbiter.apply_config copies these) -------------
var w_proj = 1.0
var w_contact = 1.0
var w_dash = 1.4
var w_aoe = 1.2
var w_latent = 0.5
var w_room = 6.0
var w_wall = 16.0
var w_enclose = 5.0
var w_dps = 14.0
var w_pickup = 1.0
var pickup_taken = 1.0
var fire_still_danger = 130.0
var hop_enable = 1.0
var stand_mult = 1.0
var stand_commit = 1.0
var w_hyst = 1.2
var lethality_override = -1.0
var horizon = 0.8
var room_cap = 260.0
var w_room_far = 3.0
var scan_distance = 420.0
var pin_enable = 0.0
var pin_dwell_override = 0
var pin_leak = 0.0
var orbit_override = -1.0    # --arb-orbitw (legacy --arb-orbit sets both)
var orbit_from_override = -1.0
var pin_threat = 0.25
var w_predict = 0.0
var predict_secs = 2.5
var w_tangent = 30.0
var wall_swerve = 1.0
var w_anchor = 12.0
var trade_share = 0.5
var fire_floor = 16.0
var trade_killable_min = 0.15
# v2.10.0: contract-body-aware objective pull guard (see the arbiter's
# PULL_SAFE block). 1 = shipped default; 0 = exact v2.9.1 (objective pulls are
# never damped, so a committed resource behind a monster is walked through).
var pull_safe = 1.0
var engage_mult = 1.0
var aimed_full = 1.0
var never_still_scan = 1.0
var cluster_near = 0.4
var cluster_override = -1
var w_kite = 10.0
var kite_hp_growth = 0.4
var plan_depth = 1
var plan_beam = 4
var plan_gamma = 0.6
var plan_max_threats = 90
var adapt_enable = 1.0
var adapt_gain = 0.25
var adapt_secs = 2.0
var breakout_enable = 1.0
var bounty_enable = 1.0
var room_track = 1.0
var w_space = 2.5
var goal_enable = 1.0
var w_goal = 9.0
var walk_enable = 1.0
var pursuit_enable = 1.0

# ---- shell-owned ----------------------------------------------------------
var every = 1                # --arb-every (was read directly by the shell)

# ---- world_view profile mode (STRING startup arg --arb-profile) -----------
# "" = not given => world_view._profile_mode() falls back to "auto" exactly as
# before (and prints the BOTLOG PROFILE_MODE line at the old point in time).
var profile_mode = ""

# Keys applied so far (used only by the compatibility logging in the modules).
var applied_keys = {}

# Config field names changed by the LAST parse()/override() call. The modules'
# compatibility apply_overrides() wrappers use this to copy ONLY the fields a
# given dict touches (the old per-module parsers accumulated across calls and
# never reset unrelated fields -- the offline harnesses assert that).
var last_fields = {}

var _legacy_warned = {}
var _unknown_warned = {}


func parse(startup_args: Dictionary, node_overrides: Dictionary) -> void:
	reset_defaults()
	if node_overrides != null and node_overrides is Dictionary:
		for k in node_overrides.keys():
			_apply(str(k), node_overrides[k])
	# The one non-numeric channel: `--arb-profile=<auto|table|merge>` is read
	# straight from the startup args (it was never part of the float dict).
	var raw = ""
	if startup_args != null and startup_args is Dictionary:
		raw = startup_args.get("arb-profile", "")
	if raw is String and raw != "":
		var m = raw.to_lower()
		if m == "auto" or m == "table" or m == "merge":
			profile_mode = m


# Partial apply: used by the modules' legacy apply_overrides() wrappers. Keeps
# previously applied values (the offline harnesses call it repeatedly on one
# instance and expect accumulation, like the old per-module parsers did).
func override(d: Dictionary) -> void:
	if d == null:
		return
	last_fields = {}
	for k in d.keys():
		var before = _field_snapshot()
		_apply(str(k), d[k])
		var after = _field_snapshot()
		for f in after.keys():
			if str(before.get(f, "<none>")) != str(after[f]):
				last_fields[f] = true


# Snapshot of every Config field (bookkeeping vars excluded), stringified so the
# comparison is type-insensitive (int 1 == float 1.0) and deterministic.
func _field_snapshot() -> Dictionary:
	var out = {}
	for p in get_property_list():
		if not (int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var n = String(p["name"])
		if n == "applied_keys" or n == "last_fields" or n == "_legacy_warned" or n == "_unknown_warned":
			continue
		out[n] = str(get(n))
	return out


func reset_defaults() -> void:
	persist_max = 4.0
	aoe_clock = 1.0
	aoe_mult = 1.5
	blade_split = 1.0
	sweep_union = 1.0
	sine_sample = 1.0
	moving_clock = 1.0
	orbit_scan = 1.0
	moving_blade = 1.0
	bonus_speed_scan = 1.0
	dps_ref_scan = 1.0
	char_profile = 1.0
	gold_value_override = null
	gold_pickup_draw = 1.5
	anchor_inner_override = null
	leash_override = 0.0
	engage_hp_override = null
	caution_mult = 1.0
	tree_mult = 1.0
	food_mult = 2.5
	sweep_override = -1.0
	dash_fix = 1.0
	revive_mult = 1.0
	center_mode_override = 0.0
	curse_mult = 3.0
	evolved_mult = 2.5
	evo_mult = 1.0
	walk_tag = 1.0
	waveend_mult = 1.0
	bounty_tag = 1.0
	boxes_mult = 1.0
	windup_priced = 1.0
	hitbox_scan = 1.0
	opp_enable = OPP_ENABLE_DEFAULT
	opp_agg = 1.0
	cov_enable = COV_ENABLE_DEFAULT
	tap_cd = 1.0
	w_proj = 1.0
	w_contact = 1.0
	w_dash = 1.4
	w_aoe = 1.2
	w_latent = 0.5
	w_room = 6.0
	w_wall = 16.0
	w_enclose = 5.0
	w_dps = 14.0
	w_pickup = 1.0
	pickup_taken = 1.0
	fire_still_danger = 130.0
	hop_enable = 1.0
	stand_mult = 1.0
	stand_commit = 1.0
	w_hyst = 1.2
	lethality_override = -1.0
	horizon = 0.8
	room_cap = 260.0
	w_room_far = 3.0
	scan_distance = 420.0
	pin_enable = 0.0
	pin_dwell_override = 0
	pin_leak = 0.0
	orbit_override = -1.0
	orbit_from_override = -1.0
	pin_threat = 0.25
	w_predict = 0.0
	predict_secs = 2.5
	w_tangent = 30.0
	wall_swerve = 1.0
	w_anchor = 12.0
	trade_share = 0.5
	fire_floor = 16.0
	trade_killable_min = 0.15
	pull_safe = 1.0
	engage_mult = 1.0
	aimed_full = 1.0
	never_still_scan = 1.0
	cluster_near = 0.4
	cluster_override = -1
	w_kite = 10.0
	kite_hp_growth = 0.4
	plan_depth = 1
	plan_beam = 4
	plan_gamma = 0.6
	plan_max_threats = 90
	adapt_enable = 1.0
	adapt_gain = 0.25
	adapt_secs = 2.0
	breakout_enable = 1.0
	bounty_enable = 1.0
	room_track = 1.0
	w_space = 2.5
	goal_enable = 1.0
	w_goal = 9.0
	walk_enable = 1.0
	pursuit_enable = 1.0
	econ = 1.0
	econ_hp_floor = 0.2
	econ_risk_base = 0.6
	econ_risk_hp = 2.4
	econ_margin = 0.3
	econ_eta_cost = 0.5
	econ_deadline_margin = 1.5
	econ_deadline_boost = 2.0
	econ_deadline_cap = 3.0
	econ_dl = 0.0
	econ_sweep_secs = 6.0
	econ_gather_range = 2000.0
	econ_candidate_cap = 60
	econ_xp = 0.2
	every = 1
	profile_mode = ""
	applied_keys = {}
	last_fields = {}


# Single per-key conversion table. The expressions reproduce the two old
# apply_overrides() bodies exactly (same float()/int()/max/clamp calls), so a key
# value lands on the same field with the same coercion as before.
func _apply(key: String, v) -> void:
	applied_keys[key] = true
	match key:
		# ---- keys owned by world_view ----
		"persist": persist_max = max(float(v), 1.0)
		"aoeclock": aoe_clock = float(v)
		"aoemult": aoe_mult = float(v)
		"blade": blade_split = float(v)
		"bladeunion": sweep_union = float(v)
		"sweepmat": sweep_override = float(v)
		"sweep":
			sweep_union = float(v)
			sweep_override = float(v)
			_warn_legacy("sweep", "sets BOTH --arb-bladeunion and --arb-sweepmat (old semantics kept)")
		"sine": sine_sample = float(v)
		"movingclock": moving_clock = float(v)
		"orbitscan": orbit_scan = float(v)
		"orbitw": orbit_override = float(v)
		"orbit":
			orbit_scan = float(v)
			orbit_override = float(v)
			_warn_legacy("orbit", "sets BOTH --arb-orbitscan and --arb-orbitw (old semantics kept)")
		"mblade": moving_blade = float(v)
		"bonusspeed": bonus_speed_scan = float(v)
		"dpsref": dps_ref_scan = float(v)
		"charprofile": char_profile = float(v)
		"goldval": gold_value_override = float(v)
		"golddraw": gold_pickup_draw = float(v)
		"inner": anchor_inner_override = float(v)
		"leash": leash_override = float(v)
		"engagehp": engage_hp_override = float(v)
		"caution": caution_mult = float(v)
		"tree": tree_mult = float(v)
		"food": food_mult = float(v)
		"dashfix": dash_fix = float(v)
		"revive": revive_mult = float(v)
		"centermode": center_mode_override = float(v)
		"curse": curse_mult = float(v)
		"evolved": evolved_mult = float(v)
		"evo": evo_mult = float(v)
		"walk":
			walk_tag = float(v)
			walk_enable = float(v)
		"waveend": waveend_mult = float(v)
		"bounty":
			bounty_tag = float(v)
			bounty_enable = float(v)
		"boxes": boxes_mult = float(v)
		"windup": windup_priced = float(v)
		"hitbox": hitbox_scan = float(v)
		"opp": opp_enable = float(v)
		"agg": opp_agg = clamp(float(v), 0.0, 2.0)
		"cov": cov_enable = float(v)
		"tapcd": tap_cd = float(v)
		# ---- keys owned by arbiter ----
		"proj": w_proj = float(v)
		"contact": w_contact = float(v)
		"dash": w_dash = float(v)
		"aoe": w_aoe = float(v)
		"latent": w_latent = float(v)
		"room": w_room = float(v)
		"wall": w_wall = float(v)
		"enclose": w_enclose = float(v)
		"dps": w_dps = float(v)
		"pickup": w_pickup = float(v)
		"taken": pickup_taken = float(v)
		"firedanger": fire_still_danger = float(v)
		"hop": hop_enable = float(v)
		"stand": stand_mult = float(v)
		"standcommit": stand_commit = float(v)
		"hyst": w_hyst = float(v)
		"lethality": lethality_override = float(v)
		"horizon": horizon = float(v)
		"roomcap": room_cap = float(v)
		"roomfar": w_room_far = float(v)
		"scandist": scan_distance = max(float(v), 0.0)
		"pin": pin_enable = float(v)
		"pindwell": pin_dwell_override = int(v)
		"pinleak": pin_leak = float(v)
		"orbitfrom": orbit_from_override = float(v)
		"pinthreat": pin_threat = float(v)
		"predict": w_predict = float(v)
		"predsecs": predict_secs = max(float(v), 0.1)
		"tangent": w_tangent = float(v)
		"swerve": wall_swerve = float(v)
		"anchor": w_anchor = float(v)
		"trade": trade_share = float(v)
		"floor": fire_floor = float(v)
		"tradekill": trade_killable_min = float(v)
		"pullsafe": pull_safe = float(v)
		"engage": engage_mult = float(v)
		"aimedfull": aimed_full = float(v)
		"neverstill": never_still_scan = float(v)
		"cnear": cluster_near = float(v)
		"cluster": cluster_override = int(v)
		"kite": w_kite = float(v)
		"kitehp": kite_hp_growth = float(v)
		"plan": plan_depth = int(v)
		"beam": plan_beam = max(int(v), 0)
		"gamma": plan_gamma = float(v)
		"planthreats": plan_max_threats = max(int(v), 0)
		"adapt": adapt_enable = float(v)
		"adaptgain": adapt_gain = float(v)
		"adaptsecs": adapt_secs = max(float(v), 0.0)
		"breakout": breakout_enable = float(v)
		"roomtrack": room_track = float(v)
		"space": w_space = float(v)
		"goal": goal_enable = float(v)
		"goalw": w_goal = float(v)
		"pursuit": pursuit_enable = float(v)
		# ---- v2.9 economy layer (shared by world_view + arbiter + economy) ----
		"econ": econ = float(v)
		"econhpfloor": econ_hp_floor = clamp(float(v), 0.0, 1.0)
		"econrisk": econ_risk_base = max(float(v), 0.0)
		"econriskhp": econ_risk_hp = max(float(v), 0.0)
		"econmarg": econ_margin = float(v)
		"econeta": econ_eta_cost = max(float(v), 0.0)
		"econdeadline": econ_deadline_margin = max(float(v), 0.0)
		"econboost": econ_deadline_boost = max(float(v), 0.0)
		"econcap": econ_deadline_cap = max(float(v), 1.0)
		"econsweep": econ_sweep_secs = max(float(v), 0.0)
		"econrange": econ_gather_range = max(float(v), 900.0)
		"econcands": econ_candidate_cap = max(int(v), 8)
		"econxp": econ_xp = max(float(v), 0.0)
		"econdl": econ_dl = float(v)
		# ---- shell-owned ----
		"every": every = int(v)
		_:
			_warn_unknown(key)


func _warn_legacy(key: String, note: String) -> void:
	if _legacy_warned.has(key):
		return
	_legacy_warned[key] = true
	print("CONFIG WARN: legacy override '--arb-%s' %s; use the split keys" % [key, note])


func _warn_unknown(key: String) -> void:
	if _unknown_warned.has(key):
		return
	_unknown_warned[key] = true
	print("CONFIG WARN: unknown --arb override key '%s' (ignored)" % key)
