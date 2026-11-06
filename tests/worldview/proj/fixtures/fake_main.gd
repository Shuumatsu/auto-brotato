extends Node

# Fake Main: gather() reads _entity_spawner / _consumables / _active_golds /
# _wave_timer off it and calls get_node_or_null("EnemyProjectiles") (inherited
# from Node). Everything else it could touch lives behind profile rows that the
# control arm disables.
var _entity_spawner = null
var _consumables = []
var _active_golds = []
var _wave_timer = null
var _births_container = null


func _ready() -> void:
	# world_view walks main.get_node_or_null("EnemyProjectiles").get_children();
	# an empty container is the honest no-projectiles state.
	var container = Node.new()
	container.name = "EnemyProjectiles"
	add_child(container)
	return
