extends "res://entities/units/movement_behaviors/player_movement_behavior.gd"

# The bot is steered by the candidate-action arbiter in steering/ (Arbiter +
# WorldView). get_movement() hands every bot-controlled slot to _arbiter_move();
# human slots fall through to the base movement.
#
# Step-1 structural refactor (task-5): the retired potential-field controller's
# constants/state and the unshipped telemetry plumbing were deleted; the only
# fields still exported are the two the local test harness reads (last_arb_us,
# last_move_dir). The --arb-* overrides are now parsed once by steering/config.gd
# and distributed to Arbiter/WorldView via apply_config().
const Config = preload("res://mods-unpacked/Pasha-AutoBattler/steering/config.gd")
const Arbiter = preload("res://mods-unpacked/Pasha-AutoBattler/steering/arbiter.gd")
const WorldView = preload("res://mods-unpacked/Pasha-AutoBattler/steering/world_view.gd")

# -- Tap-move tuning (fire_still characters; see the interleave in _arbiter_move) --
const TAP_MOVE = 2               # frames of travel per tap cycle
const TAP_STOP = 2               # frames of stand-and-volley per cycle (0 disables)
# v2.8.0: fire_still CD-synced tap (--arb-tapcd). The game fires every weapon
# whose `_current_cooldown <= 0` on the FIRST frame movement input is exactly
# zero, so ONE stop frame per ready volley is enough. world_view publishes
# `fire_wait_frames`; stop when it is this low, otherwise keep moving. The old
# fixed TAP_MOVE/TAP_STOP cycle remains the fallback for hops, unknown loadouts
# and --arb-tapcd=0.
const TAP_CD_LEAD = 1.0          # frames-until-ready that makes a stop worth it
const TAP_SAFE_GAP = 35.0        # only tap while standing scores within this of the
                                 # chosen move; beyond it the move is a dodge.
var _tap_phase = 0

var _arbiter = null
var _world = null
var _config = null

# -- Decision interval --
# Above the frame budget the decision is taken every other physics tick and the
# heading held in between (--arb-every=0 = adaptive, N = fixed interval).
const ARB_BUDGET_US = 5000       # adaptive threshold: skip alternate ticks above this
var arb_every = 1
var _arb_tick = 0
var _arb_decided = false

# Read by _research/harness-mod's telemetry extension (do not rename/remove).
var last_move_dir = Vector2.ZERO
var last_arb_us = 0


func get_movement()->Vector2:
	# SLIM FORK: no co-op / bot-slot logic. Autopilot either steers, or the
	# original player input runs untouched (decisions and manual control are
	# always the player's).
	var options_node = get_node_or_null("/root/AutobattlerOptions")
	if options_node == null or not options_node.enable_autobattler:
		return .get_movement()
	return _arbiter_move(get_parent())


func _arbiter_move(player)->Vector2:
	if _arbiter == null:
		_arbiter = Arbiter.new()
		_world = WorldView.new()
		# ONE parse of the shared --arb-* dictionary (steering/config.gd); each
		# module then copies the fields it owns. The old code parsed the same
		# dict twice and parsed "every" a third time here.
		var overrides = $"/root/AutobattlerOptions".arb_overrides
		_config = Config.new()
		_config.parse(Utils.get_startup_arguments(), overrides)
		_arbiter.apply_config(_config, not overrides.empty())
		_world.apply_config(_config, overrides)
		arb_every = _config.every
	_arb_tick += 1
	var every = arb_every
	if every <= 0:
		every = 2 if last_arb_us > ARB_BUDGET_US else 1
	if not _arb_decided or _arb_tick % every == 0:
		_arbiter.tick_step = every
		var t0 = OS.get_ticks_usec()
		_world.gather($"/root/Main", player)
		last_move_dir = _arbiter.choose(player.position, player.get_move_speed(),
				_world.body_radius, _world.far_corner,
				_world.threats, _world.rewards, _world.targets, _world.chargers,
				_world.weapon_range, _world.prefers_still, _world.current_hp,
				_world.mitigation, _world.profile)
		last_arb_us = OS.get_ticks_usec() - t0
		_arb_decided = true

	# -- Tap-move interleave (fire_still characters) --
	# The game fires every cooldown-ready weapon on the FIRST frame movement
	# input is exactly zero (weapon.gd should_shoot), and the standing stats
	# apply that same frame. Movement is instant-velocity, so stopping costs
	# only the frames spent stopped. Gated on the arbiter's STUTTER gap -- the
	# chosen heading re-scored at the tap cycle's net speed, minus its full-speed
	# score -- so a swarm 300 px out is nearly free to stutter through while a
	# pursuer about to connect prices the slowdown as lethal. Pin escape stays
	# full speed unconditionally. The same duty cycle executes the arbiter's HOP
	# candidates (half-speed steps inside a telegraph ring, see HOP_FRAC).
	if TAP_STOP > 0 and last_move_dir != Vector2.ZERO \
			and not _arbiter.last_escaping \
			and (_arbiter.last_hop \
				or (_world.profile.get("fire_still", false) \
					and _arbiter.last_stutter_gap < TAP_SAFE_GAP)):
		# v2.8.0 CD-synced tap (--arb-tapcd; =0 is the exact v2.7.0 fixed
		# cycle). Stop exactly one frame when world_view reports a weapon ready,
		# then resume moving. Hops keep the fixed duty cycle; unknown loadouts
		# (fire_wait_frames < 0) fall back to it too.
		if not _arbiter.last_hop and _world.tap_cd != 0.0:
			var fw = float(_world.fire_wait_frames)
			if fw < 0.0:
				_tap_phase = (_tap_phase + 1) % (TAP_MOVE + TAP_STOP)
				if _tap_phase < TAP_STOP:
					return Vector2.ZERO
			elif fw <= TAP_CD_LEAD:
				_tap_phase = 0
				return Vector2.ZERO    # a volley is ready: fire this frame
			else:
				_tap_phase = TAP_STOP  # everything cooling: keep moving
		else:
			_tap_phase = (_tap_phase + 1) % (TAP_MOVE + TAP_STOP)
			if _tap_phase < TAP_STOP:
				return Vector2.ZERO    # let the volley off; old fixed cycle
	else:
		_tap_phase = TAP_STOP    # re-enter cycles on the moving side

	return last_move_dir
