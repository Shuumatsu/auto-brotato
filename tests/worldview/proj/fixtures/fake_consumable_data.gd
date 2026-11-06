extends Reference

# Fake ConsumableData: my_id / my_id_hash / effects, as on ItemParentData
# (Brotato 1.2.0.1 items/global/item_parent_data.gd).
var my_id = ""
var my_id_hash = 0
var effects = []


func setup(id: String, has_effects: Array = []) -> void:
	my_id = id
	my_id_hash = Keys.generate_hash(id)
	effects = has_effects
	return
