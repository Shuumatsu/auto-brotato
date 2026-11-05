extends Node

# AutoBattler (slim fork of BOTato) - movement-only autopilot.
#
# Only two script extensions are installed:
#   1. player_movement_behavior.gd -> feeds the arbiter's steering into the
#      player's get_movement() while the autopilot is enabled.
#   2. main_menu.gd -> creates the /root/AutobattlerOptions singleton (config
#      + hotkey) the first time the title screen loads.
#
# Everything from upstream that could touch decisions (auto-shop, auto level-up
# picks, co-op bot slots) is intentionally NOT installed. The game's shop,
# level-up, crate and "next wave" screens therefore run 100% vanilla.

const MOD_DIR := "Pasha-AutoBattler/"


func _init():
	var dir = ModLoaderMod.get_unpacked_dir() + MOD_DIR
	ModLoaderMod.install_script_extension(dir + "extensions/ui/menus/pages/main_menu.gd")
	ModLoaderMod.install_script_extension(
		dir + "extensions/entities/units/movement_behaviors/player_movement_behavior.gd"
	)
