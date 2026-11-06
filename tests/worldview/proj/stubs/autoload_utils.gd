extends Node

# Functional Utils stub for the v2.4.0 world_view self-test.
# Only the members world_view.gd touches are provided. Colours are the real
# 1.2.0.1 values from singletons/utils.gd:4-6 so curse/evolution detection is
# exercised with the exact same Color objects the game uses.

const CURSE_COLOR = Color("ca61ff")
const MUTANT_COLOR = Color("6abe30")
const MECA_COLOR = Color("5b6ee1")

# Test-settable flat stats, keyed by hash. 0 is what a naked build has.
var stats = {}

var startup_arguments = {}


func get_stat(stat_hsh: int, _player_index: int = 0) -> float:
	return float(stats.get(stat_hsh, 0))


func get_capped_stat(stat_hsh: int, player_index: int = 0) -> float:
	return get_stat(stat_hsh, player_index)


func get_startup_arguments() -> Dictionary:
	return startup_arguments
