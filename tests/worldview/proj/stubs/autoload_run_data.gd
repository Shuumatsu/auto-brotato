extends Node

# Functional RunData stub for the v2.4.0 world_view self-test.
#
# can_pick_up_consumable() / is_meca_only() / is_mutant_only() /
# is_dual_evolution() are PORTED 1:1 from singletons/run_data.gd:363-406
# (Brotato 1.2.0.1) so the mod's evolution-pickup gating is exercised against
# the real game rules, not against a permissive fake.
#
# Test hooks (set by test.gd):
#   effects             hash -> effect value (stat_evolution, meca_only, ...)
#   player_character    object with .my_id, returned by get_player_character()
#   can_pick_override  null = faithful logic; true/false = force that result

const DUMMY_PLAYER_INDEX = 100

var current_wave = 4
var current_run_accessibility_settings = {"speed": 1.0}
var player_character = null
var effects = {}
var can_pick_override = null


func reset() -> void:
	current_wave = 4
	current_run_accessibility_settings = {"speed": 1.0}
	player_character = null
	effects = {}
	can_pick_override = null


func get_player_character(_player_index: int):
	return player_character


func get_player_effects(_player_index: int) -> Dictionary:
	return effects


func get_player_effect(key: int, _player_index: int):
	return effects.get(key, 0)


func get_player_effect_bool(key: int, player_index: int) -> bool:
	return get_player_effect(key, player_index) > 0


func get_player_weapons(_player_index: int) -> Array:
	return []


func get_player_gold(_player_index: int) -> int:
	return 0


func add_bonus_gold(_player_index: int, _amount) -> void:
	pass


func get_player_count() -> int:
	return 1


func get_armor_coef(armor: int) -> float:
	var percent_dmg_taken = 10.0 / (10.0 + (abs(armor) / 1.5))
	if armor < 0:
		percent_dmg_taken = (1.0 - percent_dmg_taken) + 1.0
	return percent_dmg_taken


# --- ported verbatim from singletons/run_data.gd (1.2.0.1) -------------------

func is_meca_only(player_index: int) -> bool:
	if player_index < 0 or player_index == DUMMY_PLAYER_INDEX:
		return false
	return get_player_effect(Keys.meca_only_hash, player_index) > 0


func is_mutant_only(player_index: int) -> bool:
	if player_index < 0 or player_index == DUMMY_PLAYER_INDEX:
		return false
	return get_player_effect(Keys.mutant_only_hash, player_index) > 0


func is_dual_evolution(player_index: int) -> bool:
	if player_index < 0 or player_index == DUMMY_PLAYER_INDEX:
		return false
	return get_player_effect(Keys.dual_evolution_hash, player_index) > 0


func can_pick_up_consumable(consumable_data, player_index: int) -> bool:
	if can_pick_override != null:
		return bool(can_pick_override)
	if player_index < 0 or player_index == DUMMY_PLAYER_INDEX:
		return true

	var id_hash: int = consumable_data.my_id_hash
	var evolution: float = get_player_effect(Keys.stat_evolution_hash, player_index)

	if id_hash == Keys.consumable_meca_parts_hash or id_hash == Keys.consumable_mutation_fruit_hash:
		if is_dual_evolution(player_index):
			return evolution != 0
		if id_hash == Keys.consumable_meca_parts_hash:
			return is_meca_only(player_index) or (not is_mutant_only(player_index) and evolution > 0)
		return is_mutant_only(player_index) or (not is_meca_only(player_index) and evolution < 0)

	if is_dual_evolution(player_index):
		return true

	if id_hash == Keys.consumable_meca_fruit_hash:
		return not is_mutant_only(player_index) and evolution >= -ItemService.EVOLUTION_CAMP_LOCK_THRESHOLD

	if id_hash == Keys.consumable_mutant_fruit_hash:
		return not is_meca_only(player_index) and evolution <= ItemService.EVOLUTION_CAMP_LOCK_THRESHOLD

	return true
