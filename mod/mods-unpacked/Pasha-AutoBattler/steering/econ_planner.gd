extends Reference

# =============================================================================
# econ_planner.gd -- v2.9 economy objective planner.
#
# Pure array/math input (no game API, no node access): world_view hands it the
# per-decision ctx (position, speed, HP, wave clock, threats, economically
# classified candidates) and it returns the ONE candidate worth committing to
# this decision. The arbiter consumes the commitment through its existing
# goal/bounty pull channels.
#
# What changed vs the v2.8 opportunity layer:
#   * continuous risk budget instead of a binary "is a body near" gate:
#       score = value*deadline - risk_weight(hp_ratio)*route_risk - ETA_COST*eta
#     with risk_weight rising as HP drops; only a hard HP floor remains.
#   * AUTO_AT_HORN resources are not detour targets (only their mid-wave
#     trigger value, if any, can pay the trip).
#   * LOST_AT_HORN / TREE candidates get a wave-end deadline scale (the horn
#     vacuum loses them), and in sweep mode they are the only candidates.
#   * special targets are left to the legacy bounty path in arbiter.gd
#     (value table unchanged), so this planner never reprices them.
# =============================================================================

const Contract = preload("res://mods-unpacked/Pasha-AutoBattler/steering/contract.gd")

const OPP_RISK_TAPER = 60.0
const OPP_RISK_CAP = 200.0
const OPP_TICKS = 100
const OPP_COOLDOWN = 15
const OPP_HOLD = 90.0

var enabled = 1.0
var hp_floor = 0.2
var risk_base = 0.6
var risk_hp = 2.4
var margin = 0.3
var eta_cost = 0.5
var deadline_margin = 1.5
var deadline_boost = 2.0
var deadline_cap = 3.0
var sweep_secs = 6.0

var _ticks = 0
var _cooldown = 0
var _commit = {}
var last_debug = {}


func apply_config(cfg) -> void:
	if cfg == null:
		return
	enabled = float(cfg.econ)
	hp_floor = float(cfg.econ_hp_floor)
	risk_base = float(cfg.econ_risk_base)
	risk_hp = float(cfg.econ_risk_hp)
	margin = float(cfg.econ_margin)
	eta_cost = float(cfg.econ_eta_cost)
	deadline_margin = float(cfg.econ_deadline_margin)
	deadline_boost = float(cfg.econ_deadline_boost)
	deadline_cap = float(cfg.econ_deadline_cap)
	sweep_secs = float(cfg.econ_sweep_secs)
	return


func reset() -> void:
	_ticks = 0
	_cooldown = 0
	_commit = {}
	last_debug = {}


func is_committed() -> bool:
	return not _commit.empty()


# ctx keys:
#   pos:Vector2, speed:float, hp_ratio:float, wave_time_left:float,
#   threats:Array (arbiter threat tuples), candidates:Array,
#   mitigation:float, body_radius:float
# candidate keys: {pos:Vector2, value:float, flags:int, tag:int}
# Returns {} (no commitment) or
#   {on:true, kind:String, pos:Vector2, value:float, score:float,
#    risk:float, eta:float, flags:int, deadline:float}
func update(ctx: Dictionary) -> Dictionary:
	last_debug = {}
	if enabled == 0.0:
		return {}
	var pos = ctx.get("pos", Vector2.ZERO)
	var speed = max(float(ctx.get("speed", 300.0)), 1.0)
	var hp_ratio = clamp(float(ctx.get("hp_ratio", 1.0)), 0.0, 1.0)
	var wave_left = float(ctx.get("wave_time_left", 1e9))
	var threats = ctx.get("threats", [])
	var candidates = ctx.get("candidates", [])
	var mitigation = float(ctx.get("mitigation", 1.0))
	var body_radius = float(ctx.get("body_radius", 20.0))
	# HP floor: below it the bot only survives (existing threat terms decide).
	if hp_ratio < hp_floor:
		return _release()
	if _cooldown > 0:
		_cooldown -= 1
	var sweep = wave_left <= sweep_secs and wave_left < 1e8
	var best = _best(candidates, pos, speed, threats, hp_ratio, wave_left,
			mitigation, body_radius, sweep)
	# -- keep an existing commitment unless something clearly better appears --
	# Hysteresis is deliberately strong: v2.8's opportunity layer held a
	# commitment for ~100 frames, and without that a planner re-picking the
	# "best" candidate every 33 ms oscillates between two similar targets and
	# never finishes one (measured: trees stopped being felled in the sim).
	if _ticks > 0 and not _commit.empty():
		_ticks -= 1
		if not sweep:
			var cur = _find_near(candidates, _commit["pos"], max(OPP_HOLD, speed * 0.15))
			if not cur.empty():
				var keep = true
				var dcur = cur["pos"].distance_to(pos)
				if dcur >= 180.0 and not best.empty() \
						and float(best["score"]) > float(_commit["score"]) * 1.35 + margin:
					keep = false
				if keep:
					_commit["pos"] = cur["pos"]
					_commit["value"] = float(cur["value"])
					return _commit.duplicate()
	if best.empty():
		return _release()
	_ticks = OPP_TICKS
	_commit = best
	return _commit.duplicate()


func _release() -> Dictionary:
	_ticks = 0
	_cooldown = OPP_COOLDOWN
	_commit = {}
	return {}


func _find_near(candidates: Array, at: Vector2, tolerance: float) -> Dictionary:
	var best = {}
	var best_d = tolerance
	for c in candidates:
		if not (c is Dictionary) or not c.has("pos"):
			continue
		var d = c["pos"].distance_to(at)
		if d < best_d:
			best_d = d
			best = c
	return best


func _best(candidates: Array, pos: Vector2, speed: float, threats: Array,
		hp_ratio: float, wave_left: float, mitigation: float,
		body_radius: float, sweep: bool) -> Dictionary:
	var best = {}
	var best_score = margin
	var risk_weight = risk_base + risk_hp * (1.0 - hp_ratio)
	for c in candidates:
		if not (c is Dictionary) or not c.has("pos"):
			continue
		var flags = int(c.get("flags", 0))
		if (flags & Contract.ECON_SPECIAL) != 0:
			continue   # special targets stay on the legacy bounty path
		var v = float(c.get("value", 0.0))
		if v <= 0.0:
			continue   # AUTO bank value is 0; Cryptid trees are negative
		var is_lost = (flags & (Contract.ECON_LOST_AT_HORN | Contract.ECON_TREE)) != 0
		var is_trigger = (flags & (Contract.ECON_TRIGGER | Contract.ECON_MID_WAVE_ONLY)) != 0
		if not is_lost and not is_trigger:
			continue   # pure AUTO_AT_HORN: the horn vacuum pays it anyway
		if sweep and not is_lost:
			continue   # horn sweep: only the resources that would be lost
		var dest = c["pos"]
		var eta = dest.distance_to(pos) / speed
		var deadline = _deadline(flags, eta, wave_left)
		var value = v * deadline
		var risk = route_risk(pos, dest, threats, speed, body_radius, mitigation)
		var score = value - risk_weight * risk - eta_cost * eta
		if score <= best_score:
			continue
		best_score = score
		best = {
			"on": true,
			"kind": _kind(flags),
			"pos": dest,
			"value": value,
			"score": score,
			"risk": risk,
			"eta": eta,
			"flags": flags,
			"deadline": deadline,
		}
	return best


func _kind(flags: int) -> String:
	if (flags & Contract.ECON_TREE) != 0:
		return "tree"
	if (flags & Contract.ECON_LOST_AT_HORN) != 0:
		return "lost"
	if (flags & Contract.ECON_MID_WAVE_ONLY) != 0:
		return "mid_wave"
	if (flags & Contract.ECON_TRIGGER) != 0:
		return "trigger"
	return "auto"


# Same wave-end urgency shape as the legacy evo waveend rule, generalised to
# every resource the horn would take away (LOST_AT_HORN / TREE).
func _deadline(flags: int, eta: float, wave_left: float) -> float:
	if (flags & (Contract.ECON_LOST_AT_HORN | Contract.ECON_TREE)) == 0:
		return 1.0
	if wave_left >= 1e8:
		return 1.0
	var span = max(eta, 0.0) + deadline_margin
	if wave_left >= span:
		return 1.0
	return clamp(1.0 + deadline_boost * (1.0 - wave_left / span), 1.0, deadline_cap)


# Estimated HP cost of walking the straight route pos -> dest through the
# CURRENT threat set. Same one-closest-approach-per-threat math as the legacy
# opportunity layer (a crude but honest risk estimate; the per-frame threat
# terms still dodge whatever this misses).
func route_risk(pos: Vector2, dest: Vector2, threats: Array, speed: float,
		body_radius: float, mitigation: float) -> float:
	var to = dest - pos
	var dist = to.length()
	if dist < 1.0:
		return 0.0
	var own_v = to / dist * max(speed, 1.0)
	var eta = dist / max(speed, 1.0)
	var risk = 0.0
	for t in threats:
		if not (t is Array) or t.size() < 8:
			continue
		var start = float(t[5])
		var end = min(float(t[7]), eta)
		if end <= start:
			continue
		var w = t[0] - pos
		var rel = t[1] - own_v
		var tt = start
		var denom = rel.length_squared()
		if denom > 0.000001:
			tt = clamp(-w.dot(rel) / denom, start, end)
		var miss = (w + rel * tt).length()
		var hit_r = float(t[2]) + body_radius
		if miss >= hit_r + OPP_RISK_TAPER:
			continue
		var frac = clamp(1.0 - max(miss - hit_r, 0.0) / OPP_RISK_TAPER, 0.0, 1.0)
		risk += float(t[3]) * float(t[6]) * mitigation * frac
		if risk >= OPP_RISK_CAP:
			return OPP_RISK_CAP
	return risk


func debug_state() -> Dictionary:
	return _commit.duplicate()
