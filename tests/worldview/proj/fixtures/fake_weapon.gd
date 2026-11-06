extends Node2D

# Fake Weapon for the v2.8 world_view probe: the fields world_view reads for
# fire_wait_frames (live `_current_cooldown`) and _refresh_kill_ref
# (`stats` legacy base vs `current_stats` live computed).
var stats = null
var current_stats = null
var _current_cooldown = 0.0
