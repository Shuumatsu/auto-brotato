extends Node

# Parse-only stub for Godot-Mod-Loader's `ModLoaderMod` autoload singleton.
# tests/tools/check_gd.sh only compiles scripts (load + can_instance), never
# runs them, so these bodies are never executed; they exist so that
# mod_main.gd's `ModLoaderMod.install_script_extension(...)` calls resolve.

func get_unpacked_dir() -> String:
	return "res://mods-unpacked/"


func install_script_extension(_extension_path: String) -> void:
	pass


func install_script_extension_mod(_extension_path: String) -> void:
	pass
