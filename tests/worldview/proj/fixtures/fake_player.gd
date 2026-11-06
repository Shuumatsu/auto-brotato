extends Node2D

# Fake Player: the fields world_view.gather() reads.
var player_index = 0

var current_stats = null
var max_stats = null
var current_weapons = []

var _hurtbox = null
var _item_attract_area = null
var not_moving_bonuses_applied = false
var _not_moving_timer = null

var move_speed = 300.0


func get_move_speed() -> float:
	return move_speed


func setup(hp: float, max_hp: float, spd: float = 300.0) -> void:
	var stats = load("res://fixtures/fake_stats.gd").new()
	stats.health = hp
	stats.dodge = 0.0
	stats.armor = 0.0
	current_stats = stats
	var mstats = load("res://fixtures/fake_stats.gd").new()
	mstats.health = max_hp
	max_stats = mstats
	move_speed = spd
	return


# Builds the real-player node shape world_view reads the attract rim from:
# Player/ItemAttractArea/CollisionShape2D with a CircleShape2D radius.
func make_attract_area(radius: float = 150.0) -> void:
	var area = Area2D.new()
	area.name = "ItemAttractArea"
	var shape_node = CollisionShape2D.new()
	shape_node.name = "CollisionShape2D"
	var circle = CircleShape2D.new()
	circle.radius = radius
	shape_node.shape = circle
	area.add_child(shape_node)
	add_child(area)
	_item_attract_area = area
	return
