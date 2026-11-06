extends Node2D

# Fake material drop: world_view.gather() walks main._active_golds and skips
# drops already flying to a player (attracted_by != null).
var attracted_by = null
