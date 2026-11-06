extends Node2D

# Fake Consumable: a Node2D with a ConsumableData and the real healing probe.
# `healing` mirrors what has_healing_effect() would return for the data (i.e.
# whether consumable_data.effects holds a ConsumableHealingEffect).
var consumable_data = null
var healing = false
var already_picked_up = false


func has_healing_effect() -> bool:
	return healing
