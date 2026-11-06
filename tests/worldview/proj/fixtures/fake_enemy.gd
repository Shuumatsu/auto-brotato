extends Node2D

# Fake Enemy (a Unit): every field world_view.gd's _add_unit path reads, with
# the real Entity outline API (entities/entity.gd:151-167) and Enemy's exported
# _is_meca / _is_mutant flags (enemies/enemy.gd:39-40).
var dead = false
var _pending_die = false
var is_loot = false

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
