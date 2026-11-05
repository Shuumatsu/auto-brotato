extends Node

# AutoBattler options singleton (slim fork of BOTato).
#
# - Shift+Space toggles the autopilot at any time (state persisted).
# - A tiny HUD label shows the current state while a run is on screen.
# - Advanced tuning: `--arb-<name>=<value>` startup args are forwarded to
#   steering/arbiter.gd + steering/world_view.gd apply_overrides(), exactly
#   like upstream BOTato (see those files for the available knob names).
#
# Nothing here decides anything in the game: it only flips whether the
# arbiter is allowed to steer the player during a wave.

const CONFIG_FILENAME := "user://auto-battler-fork.cfg"
const OVERRIDES_FILENAME := "user://auto-battler-overrides.json"
const CONFIG_SECTION := "options"
const MOD_NAME := "Pasha-AutoBattler"

const DEFAULT_ENABLE := true

var enable_autobattler := DEFAULT_ENABLE
var arb_overrides := {}

var _last_toggle_ms := 0
var _hud: CanvasLayer = null
var _hud_label: Label = null


func _ready():
	# Keep the hotkey/HUD alive even while the game is paused (pause menu).
	pause_mode = Node.PAUSE_MODE_PROCESS
	load_mod_options()
	_read_startup_args()
	_build_indicator()
	_refresh_indicator()
	print("[AutoBattler] options ready, autopilot=", enable_autobattler)


func _process(_delta):
	# The indicator only matters while a wave/shop is on screen.
	if _hud != null:
		var scene = get_tree().current_scene
		_hud.visible = scene != null and scene.name == "Main"


func _input(event):
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.shift and event.scancode == KEY_SPACE:
		var now = OS.get_ticks_msec()
		if now - _last_toggle_ms < 350:
			return
		_last_toggle_ms = now
		enable_autobattler = not enable_autobattler
		save_configs()
		_refresh_indicator()
		get_tree().set_input_as_handled()
		print("[AutoBattler] autopilot ", "ON" if enable_autobattler else "OFF")


func _build_indicator():
	_hud = CanvasLayer.new()
	_hud.layer = 100
	_hud.name = "AutoBattlerHUD"
	add_child(_hud)

	_hud_label = Label.new()
	_hud_label.name = "AutopilotLabel"
	_hud_label.rect_position = Vector2(18, 14)
	_hud_label.add_color_override("font_color", Color(1.0, 1.0, 1.0, 0.85))
	_hud_label.add_color_override("font_color_shadow", Color(0.0, 0.0, 0.0, 0.8))
	_hud_label.add_constant_override("shadow_offset_x", 2)
	_hud_label.add_constant_override("shadow_offset_y", 2)
	_hud.add_child(_hud_label)


func _refresh_indicator():
	if _hud_label == null:
		return
	var on_text := "AUTOPILOT: ON   [Shift+Space]"
	_hud_label.text = on_text if enable_autobattler else "AUTOPILOT: OFF  [Shift+Space]"


func _read_startup_args():
	# Same knob as upstream BOTato: --arb-<name>=<value>.
	var args = Utils.get_startup_arguments()
	for key in args.keys():
		if key is String and key.begins_with("arb-"):
			var raw = args[key]
			if str(raw).is_valid_float():
				arb_overrides[key.substr(4)] = float(raw)
	# Local tuning hook: user://auto-battler-overrides.json, e.g.
	# {"proj": 1.1, "contact": 0.8, "room": 7.0}. Used by the benchmark driver
	# and useful for hand tuning without Steam launch options.
	var f = File.new()
	if f.file_exists(OVERRIDES_FILENAME):
		if f.open(OVERRIDES_FILENAME, File.READ) == OK:
			var parsed = JSON.parse(f.get_as_text())
			f.close()
			if parsed.error == OK and parsed.result is Dictionary:
				for k in parsed.result.keys():
					var v = parsed.result[k]
					if typeof(v) == TYPE_INT or typeof(v) == TYPE_REAL:
						arb_overrides[str(k)] = float(v)


func load_mod_options():
	var config = ConfigFile.new()
	if config.load(CONFIG_FILENAME) != OK:
		return
	enable_autobattler = bool(config.get_value(
			CONFIG_SECTION, "ENABLE_AUTOBATTLER", DEFAULT_ENABLE))


func save_configs():
	var config = ConfigFile.new()
	config.set_value(CONFIG_SECTION, "ENABLE_AUTOBATTLER", enable_autobattler)
	config.save(CONFIG_FILENAME)
