extends SceneTree

func _init():
	var A = load("res://arbiter.gd")
	if A == null:
		print("LOAD FAIL")
		quit(1)
		return
	var p = Vector2(500, 600)
	var far = Vector2(1600, 1200)
	var targets = [[Vector2(1300, 950), 60.0, false, 2]]
	var prof = {"kite_frac": 0.75}
	var a = A.new()
	var d1 = a.choose(p, 320.0, 18.0, far, [], [], targets, [], 260.0,
			false, 100.0, 1.0, prof)
	print("BOUNTY default dir=", d1, " bounty=", a.last_bounty,
			" dist=", a.last_bounty_dist)
	var b = A.new()
	b.apply_overrides({"bounty": 0})
	var d2 = b.choose(p, 320.0, 18.0, far, [], [], targets, [], 260.0,
			false, 100.0, 1.0, prof)
	print("BOUNTY off    dir=", d2, " bounty=", b.last_bounty)
	# safety: a body within 300 must veto acquisition
	var threats = [[Vector2(620, 600), Vector2(0, 0), 14.0, 6.0, 1, 0.0, 1.6, 1e9, 0.0]]
	var c = A.new()
	var d3 = c.choose(p, 320.0, 18.0, far, threats, [], targets, [], 260.0,
			false, 100.0, 1.0, prof)
	print("BOUNTY danger dir=", d3, " bounty=", c.last_bounty)
	quit(0)
