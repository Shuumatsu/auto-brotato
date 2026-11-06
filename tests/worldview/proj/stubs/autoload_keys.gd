extends Node

# Functional Keys stub for the v2.4.0 world_view self-test.
#
# Mirrors the parts of singletons/keys.gd (Brotato 1.2.0.1) that world_view.gd
# touches, with the SAME name -> hash-string mapping as the game, so a fake
# ConsumableData built with my_id = "meca_consumable_fruit" classifies exactly
# like the real resource. Values are computed with String.hash(), which is what
# the game's generate_hash() uses; only equality matters here, not the number.

const empty_hash = 5381

var hash_to_string = {empty_hash: ""}

# Every key world_view.gd references (HEAD) plus the v2.4.0 DLC keys.
var stat_evolution_hash
var consumable_fruit_hash
var consumable_poisoned_fruit_hash
var consumable_meca_fruit_hash
var consumable_mutant_fruit_hash
var consumable_mutation_fruit_hash
var consumable_meca_parts_hash
var consumable_item_box_hash
var consumable_legendary_item_box_hash
var meca_only_hash
var mutant_only_hash
var dual_evolution_hash
var stat_lifesteal_hash
var stat_hp_regeneration_hash
var stat_harvesting_hash
var reload_when_pickup_gold_hash
var one_shot_trees_hash
var no_heal_hash
var living_tree_hash
var gain_pct_gold_start_wave_hash
var explosion_damage_hash
var explode_when_below_hp_hash
var explode_on_hit_hash
var explode_on_consumable_hash
var explode_on_consumable_burning_hash
var percent_materials_hash
var temp_stats_while_not_moving_hash
var temp_stats_while_moving_hash
var temp_consumable_stats_while_max_hash
var effect_stat_while_not_moving_hash
var effect_stat_while_moving_hash
var effect_gold_while_not_moving_hash
var effect_gold_while_moving_hash
var effect_instant_gold_attracting_hash
var effect_gain_stat_for_every_tree_hash
var effect_gain_pct_gold_start_wave_hash
var dmg_when_pickup_gold_hash
var consumable_stats_while_max_hash
var can_attack_while_moving_hash
var tree_turrets_hash
var structure_range_hash

# [member name, exact hash string from singletons/keys.gd]
const _MAP = [
	["stat_evolution", "stat_evolution"],
	["consumable_fruit", "consumable_fruit"],
	["consumable_poisoned_fruit", "consumable_poisoned_fruit"],
	["consumable_meca_fruit", "meca_consumable_fruit"],
	["consumable_mutant_fruit", "mutant_consumable_fruit"],
	["consumable_mutation_fruit", "mutation_consumable_fruit"],
	["consumable_meca_parts", "meca_parts_consumable"],
	["consumable_item_box", "consumable_item_box"],
	["consumable_legendary_item_box", "consumable_legendary_item_box"],
	["meca_only", "meca_only"],
	["mutant_only", "mutant_only"],
	["dual_evolution", "dual_evolution"],
	["stat_lifesteal", "stat_lifesteal"],
	["stat_hp_regeneration", "stat_hp_regeneration"],
	["stat_harvesting", "stat_harvesting"],
	["reload_when_pickup_gold", "reload_when_pickup_gold"],
	["one_shot_trees", "one_shot_trees"],
	["no_heal", "no_heal"],
	["living_tree", "living_tree"],
	["gain_pct_gold_start_wave", "gain_pct_gold_start_wave"],
	["explosion_damage", "explosion_damage"],
	["explode_when_below_hp", "explode_when_below_hp"],
	["explode_on_hit", "explode_on_hit"],
	["explode_on_consumable", "explode_on_consumable"],
	["explode_on_consumable_burning", "explode_on_consumable_burning"],
	["percent_materials", "percent_materials"],
	["temp_stats_while_not_moving", "temp_stats_while_not_moving"],
	["temp_stats_while_moving", "temp_stats_while_moving"],
	["temp_consumable_stats_while_max", "temp_consumable_stats_while_max"],
	["effect_stat_while_not_moving", "effect_stat_while_not_moving"],
	["effect_stat_while_moving", "effect_stat_while_moving"],
	["effect_gold_while_not_moving", "effect_gold_while_not_moving"],
	["effect_gold_while_moving", "effect_gold_while_moving"],
	["effect_instant_gold_attracting", "effect_instant_gold_attracting"],
	["effect_gain_stat_for_every_tree", "effect_gain_stat_for_every_tree"],
	["effect_gain_pct_gold_start_wave", "effect_gain_pct_gold_start_wave"],
	["dmg_when_pickup_gold", "dmg_when_pickup_gold"],
	["consumable_stats_while_max", "consumable_stats_while_max"],
	["can_attack_while_moving", "can_attack_while_moving"],
	["tree_turrets", "tree_turrets"],
	["structure_range", "structure_range"],
]


func _init() -> void:
	for pair in _MAP:
		set(pair[0] + "_hash", generate_hash(pair[1]))


func generate_hash(text: String) -> int:
	if text == "":
		return empty_hash
	var hsh = text.hash()
	if not hash_to_string.has(hsh):
		hash_to_string[hsh] = text
	return hsh
