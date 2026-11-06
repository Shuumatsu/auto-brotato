extends SceneTree

func _init():
	var A = load("res://arbiter.gd")
	if A == null:
		print("LOAD FAIL")
		quit(1)
		return
	var a = A.new()
	var threats = []
	for i in range(40):
		var ang = float(i) * TAU / 40.0
		var pos = Vector2(1000, 700) + Vector2(cos(ang), sin(ang)) * 400.0
		threats.push_back([pos, -Vector2(cos(ang), sin(ang)) * 250.0,
				14.0, 6.0, 1, 0.0, 1.6, 1e9, 0.0])
	var d = a._rollout_escape_dir(Vector2(1000, 700), 320.0,
			Vector2(1800, 1300), threats)
	print("ROLLOUT dir=", d, " rolled_bodies>24 path ok")
	quit(0)
