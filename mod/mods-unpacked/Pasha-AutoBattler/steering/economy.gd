extends Reference

const Contract = preload("res://mods-unpacked/Pasha-AutoBattler/steering/contract.gd")

# =============================================================================
# economy.gd -- v2.9 economy objective layer: what a resource is worth as a
# MID-WAVE DETOUR, as a wave-end bank, and how it must be acquired.
#
# Pure data in / pure data out: world_view gathers the game state into a ctx
# Dictionary (hp, wave clock, RunData effect values, build traits) and this
# module prices it. No node access, no RunData/Keys calls, no character-name
# checks: every "full HP payoff" is detected from the effect keys the game
# stores on the player (FA-25), with data-driven magnitudes below.
#
# Unit: the arbiter's HP-equivalent. Anchor: 1 material = MAT_HP (0.8, the old
# GOLD_VALUE) and every material also grants 1 XP (main.gd:1070-1078), hence
# XP_HP. A threat prices at 15-65 units, so ordinary pickups stay small; only
# LOST_AT_HORN / TREE candidates are allowed to approach a threat inside the
# wave-end deadline.
#
# Acquisition classes (bitmask in reward[Contract.R_ECON_FLAGS]):
#   AUTO_AT_HORN   -- horn vacuum pays it anyway; mid-wave value is 0 unless a
#                     pickup-trigger / immediate heal pays NOW.
#   LOST_AT_HORN   -- meca/mutant fruit, Veteran fruit: lost forever if not taken
#                     mid-wave -> full value + deadline scale.
#   MID_WAVE_ONLY  -- temp/decay stats and consume-explosions: NOT triggered by
#                     the horn vacuum -> mid-wave value only.
#   TREE           -- horn destroys an unfelled tree and drops nothing -> EV of
#                     the fell (materials + expected consumable) - hit cost.
#   TRIGGER        -- carries a gold pickup trigger (damage/reload/heal/...).
# =============================================================================

# -- value table (all HP-equivalent units) -----------------------------------
const FRUIT_HEAL = 3.0             # Brotato 1.2.0.1 fruit base heal
const BOX_HEAL = 3.0               # item_box carries a fruit-effect (heal 3)
const LEGENDARY_BOX_HEAL = 100.0   # legendary box heal is effectively full HP

const MAT_HP = 0.8                 # 1 material = GOLD_VALUE arbiter units
const XP_HP = 0.2                  # ... plus 1 XP per material (main.gd:1070-1078)
const HEAL_HP = 1.0                # 1 real HP of healing = 1 unit at full value
const HEAL_LOW_BONUS = 1.0         # urgency multiplier as HP drops (x2 at 0 HP)
const BOX_BANK_HP = 6.0            # one item choice, banked (tree EV only)
const LEG_BANK_HP = 12.0
# LOST_AT_HORN evolution fruit: a permanent camp point that is GONE at the horn.
# Priced near the low end of a real threat (allowed for LOST resources by the
# value-model rule) so the planner can outbid marginal fights; the wave-end
# deadline scale pushes it higher when it is about to be lost.
const EVO_VALUE = 18.0
const TREE_MATERIALS = 3.0         # tree_jungle_stats.tres value = 3
const TREE_BOX_P = 0.2             # 80% fruit / 20% box first consumable
const TREE_HIT_COST = 0.15         # per contact hit (8 hits default -> 1.2 units)
const TREE_FRUIT_BANK = 0.8        # banked value of the fruit drop at the horn
const CRYPTID_TREE_COST = 6.0      # living tree pays 12 materials at the horn
const TREE_BONUS_HP = 0.1          # per point of the "trees" stat (income builds)

const PERM_DISCOUNT = 0.2          # permanent stat floor
const PERM_FARMER_HP = 1.6         # +1 harvesting (data-driven by stat hash)
const PERM_GLUTTON_HP = 1.2        # +1 explosion_damage
const PERM_MAXHP_HP = 1.0          # +1 max HP (Extra Stomach, cap 8/wave)
const PERM_UNKNOWN_HP = 0.5
const DRUID_FRUIT_HP = 0.6         # stats_on_fruit: a small luck roll
const PENGUIN_MID_HP = 2.0         # temp stats while max HP: mid-wave only
const CAULDRON_MID_HP = 1.5        # decaying stats on consumable: mid-wave only
const BOMB_PER_ENEMY = 3.0         # consume-explosion: value in the blast
const BOMB_MAX = 9.0

const TRIGGER_DMG_HP = 1.2         # gold pickup damage, when a target is in range
const TRIGGER_RELOAD_HP = 1.2      # gold pickup resets a cooling weapon
const TRIGGER_MAT_MULT_HP = 0.2    # extra units per +100% material value
const POISON_COST = 2.0            # poisoned fruit: actively harmful

# -- live tuning (mirrors config.gd econ_*; apply_config copies) -------------
var econ = 1.0
var xp_hp = XP_HP
var hp_floor = 0.2
var risk_base = 0.6
var risk_hp = 2.4
var margin = 0.3
var eta_cost = 0.5
var deadline_margin = 1.5
var deadline_boost = 2.0
var deadline_cap = 3.0
var sweep_secs = 6.0
var gather_range = 2000.0
var candidate_cap = 60

# stat hashes used to decode the data-driven permanent-stat effects. Filled by
# world_view (Keys.generate_hash) and passed through ctx["hashes"]; kept here as
# fallbacks so the module is usable standalone in tests.
var h_stat_harvesting = 0
var h_stat_explosion_damage = 0
var h_stat_max_hp = 0


func apply_config(cfg) -> void:
	if cfg == null:
		return
	econ = float(cfg.econ)
	xp_hp = float(cfg.econ_xp)
	hp_floor = float(cfg.econ_hp_floor)
	risk_base = float(cfg.econ_risk_base)
	risk_hp = float(cfg.econ_risk_hp)
	margin = float(cfg.econ_margin)
	eta_cost = float(cfg.econ_eta_cost)
	deadline_margin = float(cfg.econ_deadline_margin)
	deadline_boost = float(cfg.econ_deadline_boost)
	deadline_cap = float(cfg.econ_deadline_cap)
	sweep_secs = float(cfg.econ_sweep_secs)
	gather_range = float(cfg.econ_gather_range)
	candidate_cap = int(cfg.econ_candidate_cap)
	return


func enabled() -> bool:
	return econ != 0.0


# =============================================================================
# Acquisition-path classification
# =============================================================================

# Path class of a ground resource ("gold"/"fruit"/"box"/"legendary"/"meca"/
# "mutant"/"mutation"/"parts"/"poisoned"/"tree"/"loot").
func path_class(kind: String, ctx: Dictionary) -> int:
	match kind:
		"meca", "mutant", "poisoned":
			return Contract.ECON_LOST_AT_HORN
		"tree":
			return Contract.ECON_TREE
		"fruit":
			# Veteran's no_fruit_attracted_end_of_wave: horn skips ordinary fruit
			if bool(ctx.get("veteran_no_fruit", false)):
				return Contract.ECON_LOST_AT_HORN
			return Contract.ECON_AUTO_AT_HORN
		_:
			return Contract.ECON_AUTO_AT_HORN


# Full flags for a ground resource: path class + MID_WAVE_ONLY when the build
# has an effect that the horn vacuum does NOT trigger + TRIGGER for gold.
func flags_for(kind: String, ctx: Dictionary) -> int:
	var f = path_class(kind, ctx)
	if kind == "gold":
		if _gold_trigger_value(ctx) > 0.0:
			f |= Contract.ECON_TRIGGER
		return f
	if kind == "tree":
		return f
	if _has_mid_wave_effect(kind, ctx):
		f |= Contract.ECON_MID_WAVE_ONLY
	if kind == "box" or kind == "legendary":
		if float(_fx(ctx, "item_box_gold", 0.0)) > 0.0:
			f |= Contract.ECON_TRIGGER
	return f


func _has_mid_wave_effect(kind: String, ctx: Dictionary) -> bool:
	# fruit/boxes can carry the horn-suppressed payoffs; meca/mutant never do
	if kind == "meca" or kind == "mutant" or kind == "mutation" or kind == "parts":
		return false
	if _fx(ctx, "explode_consumable", false):
		return true
	if _fx(ctx, "has_temp_stats", false) or _fx(ctx, "has_decay_stats", false):
		return true
	return false


# =============================================================================
# Heal value (the real one, not 2.5*min(12, missing))
# =============================================================================

func heal_amount(ctx: Dictionary) -> float:
	if bool(_fx(ctx, "no_heal", false)):
		return 0.0
	var heal = FRUIT_HEAL + float(_fx(ctx, "consumable_heal", 0.0))
	return max(heal, 0.0)


# Effective heal of a consumable class, including the player's consumable_heal
# modifier (can be negative: Vampire -100 -> 0) and no_heal.
func heal_for(kind: String, ctx: Dictionary) -> float:
	if bool(_fx(ctx, "no_heal", false)):
		return 0.0
	var base = 0.0
	if kind == "fruit":
		base = FRUIT_HEAL
	elif kind == "box":
		base = BOX_HEAL
	elif kind == "legendary":
		base = LEGENDARY_BOX_HEAL
	return max(base + float(_fx(ctx, "consumable_heal", 0.0)), 0.0)


func effective_heal(heal: float, ctx: Dictionary) -> float:
	# The game clamps to missing HP (player.gd:857-875); overflow is wasted.
	return min(heal, max(float(ctx.get("missing_hp", 0.0)), 0.0))


func heal_value(heal: float, ctx: Dictionary) -> float:
	var eff = effective_heal(heal, ctx)
	if eff <= 0.0:
		return 0.0
	var hp_ratio = clamp(float(ctx.get("hp_ratio", 1.0)), 0.0, 1.0)
	return eff * HEAL_HP * (1.0 + HEAL_LOW_BONUS * (1.0 - hp_ratio))


# =============================================================================
# Full-HP / MID_WAVE_ONLY effect payoffs (data-driven from effect values)
# =============================================================================

# Value of the "permanent stat from eating at full HP" family. The horn vacuum
# ALSO triggers these (player.gd:1072-1088 has no cleaning_up guard), so the
# only mid-wave increment is "one wave earlier": a small positive value that
# decays with the remaining number of waves. Never a detour reason on its own.
func permanent_stat_value(ctx: Dictionary) -> float:
	var entries = _fx(ctx, "perm_stats", [])
	if not (entries is Array):
		return 0.0
	var hashes = ctx.get("hashes", {})
	var h_harv = int(hashes.get("stat_harvesting", h_stat_harvesting))
	var h_expl = int(hashes.get("explosion_damage", h_stat_explosion_damage))
	var h_maxhp = int(hashes.get("stat_max_hp", h_stat_max_hp))
	var gained = int(ctx.get("perm_gained_this_wave", 0))
	var discount = _wave_discount(ctx)
	var v = 0.0
	for e in entries:
		if not (e is Array) or e.size() < 2:
			continue
		var stat = int(e[0])
		var cap = int(e[2]) if e.size() >= 3 else 0
		if cap > 0 and gained >= cap:
			continue                       # FA-05: cap reached -> this payoff is 0
		if stat == h_harv:
			v += PERM_DISCOUNT + PERM_FARMER_HP * discount
		elif stat == h_expl:
			v += PERM_DISCOUNT + PERM_GLUTTON_HP * discount
		elif stat == h_maxhp:
			v += PERM_DISCOUNT + PERM_MAXHP_HP * discount
		else:
			v += PERM_DISCOUNT + PERM_UNKNOWN_HP * discount
	return v


func _wave_discount(ctx: Dictionary) -> float:
	# "one wave earlier" is worth more the more waves are still to come
	var wave = max(float(ctx.get("wave", 1.0)), 1.0)
	var total = max(float(ctx.get("waves_total", wave)), wave + 1.0)
	return clamp((total - wave) / max(total - 1.0, 1.0), 0.0, 1.0)


# Value that only exists because the player ate the consumable MID-WAVE: the
# horn vacuum skips temp-stats / decay-stats / consume-explosions.
func mid_wave_only_value(kind: String, ctx: Dictionary, near_enemies: int) -> float:
	if kind == "meca" or kind == "mutant" or kind == "mutation" or kind == "parts":
		return 0.0
	var v = 0.0
	if _fx(ctx, "has_temp_stats", false):
		v += PENGUIN_MID_HP
	if _fx(ctx, "has_decay_stats", false):
		v += CAULDRON_MID_HP
	if _fx(ctx, "explode_consumable", false):
		# Chef/Glutton/Spicy: the fruit is a grenade; empty floor = wasted tag
		v += min(BOMB_MAX, BOMB_PER_ENEMY * float(max(near_enemies, 0)))
	return v


# Fixed "always-on" small payoff for permanent-stat builds at full HP. This is
# the ONLY positive part of a generic build's full-HP fruit; druid's stats_on_
# fruit is a small luck roll that also pays at the horn.
func always_on_value(kind: String, ctx: Dictionary) -> float:
	if kind == "meca" or kind == "mutant" or kind == "mutation" or kind == "parts":
		return 0.0
	var v = permanent_stat_value(ctx)
	if _fx(ctx, "stats_on_fruit", false):
		v += DRUID_FRUIT_HP
	return v


# =============================================================================
# Per-resource pricing
# =============================================================================

# Mid-wave decision value of a ground consumable.
#   kind: "fruit"/"box"/"legendary"/"meca"/"mutant"/"mutation"/"parts"/"poisoned"
#   heal: the consumable's own heal amount (3 / 3 / 100 / 0 / 0 ...)
#   near_enemies: enemies inside the consume-explosion radius at the item
func price_consumable(kind: String, heal: float, ctx: Dictionary,
		near_enemies: int = 0) -> float:
	if kind == "poisoned":
		return -POISON_COST
	if kind == "meca" or kind == "mutant":
		var v = EVO_VALUE
		return v * _deadline_factor(ctx, ctx.get("item_eta", 0.0))
	if kind == "mutation" or kind == "parts":
		return 0.0                         # horn vacuum pays them anyway
	var out = heal_value(heal, ctx) + always_on_value(kind, ctx)
	out += mid_wave_only_value(kind, ctx, near_enemies)
	if kind == "box" or kind == "legendary":
		# the item choice itself is banked at the horn; mid-wave detour value is
		# only the immediate healing (saves this wave's HP) and any triggers
		pass
	return max(out, 0.0)


# Wave-end bank value (used for TREE EV and for classification tests): what the
# horn vacuum actually pays for this consumable.
func horn_value(kind: String, ctx: Dictionary) -> float:
	if kind == "poisoned":
		return 0.0
	if kind == "meca" or kind == "mutant":
		return EVO_VALUE
	if kind == "mutation":
		return 9.0       # banked mutation choice (horn vacuum pays it)
	if kind == "parts":
		return 6.0       # banked meca parts (horn vacuum pays it)
	var hp_value = 0.0
	if kind == "fruit":
		hp_value = heal_value(heal_amount(ctx), ctx) + always_on_value(kind, ctx)
	elif kind == "box":
		hp_value = heal_value(BOX_HEAL, ctx) + float(_fx(ctx, "item_box_gold", 0.0)) * (MAT_HP + xp_hp)
	elif kind == "legendary":
		hp_value = heal_value(LEGENDARY_BOX_HEAL, ctx) + float(_fx(ctx, "item_box_gold", 0.0)) * (MAT_HP + xp_hp)
	return hp_value


# Box "bank" value used by the tree EV and the bag assertion (item choice +
# item_box_gold). Mid-wave detour value stays price_consumable().
func box_bank_value(kind: String, ctx: Dictionary) -> float:
	var bank = BOX_BANK_HP if kind == "box" else LEG_BANK_HP
	return bank + float(_fx(ctx, "item_box_gold", 0.0)) * (MAT_HP + xp_hp)


# Expected value of walking to and felling one living tree, minus the hit cost.
# Cryptid's living trees pay 12 materials per wave at the horn -> felling them
# is a real loss, so the value is negative (planner must not walk there).
func price_tree(ctx: Dictionary) -> float:
	if bool(_fx(ctx, "cryptid", false)):
		return -CRYPTID_TREE_COST
	var gold_drops = float(_fx(ctx, "gold_drops", 0.0))
	var mats = TREE_MATERIALS * (1.0 + gold_drops / 100.0)
	var mat_value = max(mats, 0.0) * (MAT_HP + xp_hp)
	var box_p = clamp(TREE_BOX_P + float(_fx(ctx, "crate_chance", 0.0)) / 100.0, 0.0, 1.0)
	var box_v = box_bank_value("box", ctx)
	var fruit_v = horn_value("fruit", ctx)
	var ev = mat_value + box_p * box_v + (1.0 - box_p) * fruit_v
	# acquisition cost: 1 hit for one_shot_trees builds, 8 contact hits otherwise
	var hits = 1.0 if bool(_fx(ctx, "one_shot_trees", false)) else 8.0
	ev -= hits * TREE_HIT_COST
	# income-build tree bonus (Explorer's "trees" stat / tree turrets)
	var tree_stat = float(_fx(ctx, "trees", 0.0)) + float(_fx(ctx, "tree_turrets", 0.0)) * 3.0
	ev += min(2.0, tree_stat * TREE_BONUS_HP)
	return ev * _deadline_factor(ctx, ctx.get("item_eta", 0.0))


# Mid-wave value of one material/gold drop. The material itself is banked at
# the horn anyway (main.gd:1225-1266), so ordinary gold has NO mid-wave value;
# only pickup-triggered effects pay now.
func price_gold(ctx: Dictionary) -> float:
	return _gold_trigger_value(ctx)


func _gold_trigger_value(ctx: Dictionary) -> float:
	var v = 0.0
	if bool(_fx(ctx, "gold_dmg", false)) and int(ctx.get("targets_near", 0)) > 0:
		v += TRIGGER_DMG_HP
	if bool(_fx(ctx, "gold_reload", false)) and bool(ctx.get("weapon_cooling", false)):
		v += TRIGGER_RELOAD_HP
	var heal_pct = float(_fx(ctx, "gold_heal_pct", 0.0))
	if heal_pct > 0.0:
		v += (heal_pct / 100.0) * heal_value(1.0, ctx)
	var heal_hp = float(_fx(ctx, "gold_heal_hp", 0.0))
	if heal_hp > 0.0:
		v += heal_hp
	var double_pct = float(_fx(ctx, "gold_double_pct", 0.0))
	if double_pct > 0.0:
		v += (double_pct / 100.0) * (MAT_HP + xp_hp)
	var mult_pct = float(_fx(ctx, "gold_mat_mult", 0.0))
	if mult_pct > 0.0:
		v += (mult_pct / 100.0) * (MAT_HP + xp_hp) * TRIGGER_MAT_MULT_HP / max(MAT_HP, 0.01)
	return v


func material_value(materials: float) -> float:
	return max(materials, 0.0) * (MAT_HP + xp_hp)


# =============================================================================
# Deadline (end-of-wave) scaling
# =============================================================================

# LOST_AT_HORN and TREE resources are gone at the horn: as the remaining wave
# time approaches the walk ETA, their value is boosted (EVO_WAVEEND shape,
# generalised). AUTO_AT_HORN resources are never boosted -- the horn pays them.
func _deadline_factor(ctx: Dictionary, eta: float) -> float:
	var flags = int(ctx.get("price_flags", 0))
	var lost = (flags & (Contract.ECON_LOST_AT_HORN | Contract.ECON_TREE)) != 0
	if not lost:
		return 1.0
	var left = float(ctx.get("wave_time_left", 1e9))
	if left >= 1e8:
		return 1.0
	var span = max(eta, 0.0) + deadline_margin
	if left >= span:
		return 1.0
	return clamp(1.0 + deadline_boost * (1.0 - left / span), 1.0, deadline_cap)


# Candidate-level deadline factor for the planner (same shape, explicit flags).
func deadline_factor(flags: int, eta: float, wave_left: float) -> float:
	var lost = (flags & (Contract.ECON_LOST_AT_HORN | Contract.ECON_TREE)) != 0
	if not lost:
		return 1.0
	if wave_left >= 1e8:
		return 1.0
	var span = max(eta, 0.0) + deadline_margin
	if wave_left >= span:
		return 1.0
	return clamp(1.0 + deadline_boost * (1.0 - wave_left / span), 1.0, deadline_cap)


# =============================================================================
# Helpers
# =============================================================================

func _fx(ctx: Dictionary, key: String, fallback):
	var effects = ctx.get("effects", {})
	if effects is Dictionary and effects.has(key):
		return effects[key]
	return fallback


# A stable ("value", "path class", "mid-wave-only", "trigger") summary for
# telemetry / probe assertions.
func describe(kind: String, ctx: Dictionary) -> Dictionary:
	return {
		"kind": kind,
		"flags": flags_for(kind, ctx),
		"price": price_consumable(kind, heal_amount(ctx), ctx),
		"horn": horn_value(kind, ctx),
		"tree": price_tree(ctx) if kind == "tree" else 0.0,
	}
