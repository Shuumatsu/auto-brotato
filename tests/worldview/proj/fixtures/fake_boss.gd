extends Boss

# Fake boss: the global Boss class (so `unit is Boss` is true, exactly like the
# real thing) with the same field surface as fake_enemy.gd.
var dead = false
var _pending_die = false
var is_loot = false
var is_elite = false   # v2.8: Boss vs Elite class split

var current_stats = null
var bonus_speed = 0.0
var decaying_bonus_speed = 0.0

var _current_attack_behavior = null
var _current_movement_behavior = null
var _attack_behavior = null
var _hurtbox = null
var _move_locked = false
var _can_move = true
var _animation_player = null

var _is_meca = false
var _is_mutant = false

var _outline_colors = []


func add_outline(color: Color) -> void:
	if not _outline_colors.has(color):
		_outline_colors.append(color)


func remove_outline(color: Color) -> void:
	_outline_colors.erase(color)


func has_outline(color: Color) -> bool:
	for outline in _outline_colors:
		if outline == color:
			return true
	return false


func setup(hp: float, dmg: float, spd: float = 0.0) -> void:
	var stats = load("res://fixtures/fake_stats.gd").new()
	stats.health = hp
	stats.damage = dmg
	stats.speed = spd
	current_stats = stats
	return
