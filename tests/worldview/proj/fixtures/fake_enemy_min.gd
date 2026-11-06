extends Node2D

# Minimal enemy-shaped body with NONE of the DLC probe surface: no
# has_outline() method, no _is_meca / _is_mutant fields. Used to prove the
# v2.4.0 detection guards do not crash on a unit built by an older/other mod.
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
