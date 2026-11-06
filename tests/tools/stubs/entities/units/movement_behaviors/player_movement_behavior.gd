extends Node2D

# Minimal base stub for the parse gate: the real game base class lives at this
# res:// path; the mod extension only needs it to resolve for compilation.
func get_movement() -> Vector2:
	return Vector2.ZERO
