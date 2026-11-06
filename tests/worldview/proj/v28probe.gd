extends SceneTree

# Thin entry point: world_view/Utils/Keys autoloads only exist after project
# startup, so the probe body is load()ed at runtime (same pattern as test.gd).
func _init() -> void:
	var impl = load("res://v28probe_impl.gd")
	if impl == null:
		print("TEST RESULT: FAIL infra: v28probe_impl.gd failed to load")
		quit(2)
		return
	quit(impl.new().run())
