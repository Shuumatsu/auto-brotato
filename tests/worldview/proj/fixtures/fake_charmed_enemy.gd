extends "res://fixtures/fake_enemy.gd"

# Fake enemy that reports as charmed by player 0 (Enemy.get_charmed_by_player_index
# exists in 1.2.0.1 enemy.gd:466; world_view skips allied bodies).
var charmed_by = 0


func get_charmed_by_player_index() -> int:
	return charmed_by
