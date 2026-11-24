extends SceneTree
## Checks the on-screen touch driving controls: pedals feed throttle / brake,
## ◀ ▶ buttons and tilt feed steering, one-shot buttons send their actions,
## multitouch, sliding between pedals, and letting go of everything.
##   godot --headless -s res://scripts/tests/touch_test.gd

var fails := 0
var tc: TouchControls
var seen := []

func _check(cond: bool, what: String) -> void:
	print(("  ok    " if cond else "  FAIL  ") + what)
	if not cond:
		fails += 1

func _touch(i: int, p: Vector2, down: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = i
	e.position = p
	e.pressed = down
	tc._input(e)

func _drag(i: int, p: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = i
	e.position = p
	tc._input(e)

func _run(secs: float) -> void:
	var t := 0.0
	while t < secs:
		tc._process(1.0 / 60.0)
		t += 1.0 / 60.0

func _initialize() -> void:
	InputSetup.register()
	var root_ctl := Control.new()
	root_ctl.size = Vector2(1920, 1080)
	root.add_child(root_ctl)
	tc = TouchControls.new()
	root_ctl.add_child(tc)
	tc.size = Vector2(1920, 1080)
	tc.visible = true
	tc.settings["touch_steer"] = "buttons"
	tc.start()

	# setting logic
	_check(TouchControls.wanted({"touch_controls": "on"}) and not TouchControls.wanted({"touch_controls": "off"}), "On / Off settings force the overlay")
	_check(not tc.use_tilt(), "no tilt sensor here: ◀ ▶ buttons are used")
	var b: Dictionary = tc._buttons
	for k in ["gas", "brake", "handbrake", "left", "right", "pause", "camera", "reset", "gear_up", "gear_down"]:
		_check(b.has(k), "%s button laid out" % k)
	var screen := Rect2(Vector2.ZERO, tc.size)
	var inside := true
	for k in b:
		if not screen.encloses(b[k]):
			inside = false
	_check(inside, "every button is on screen")
	_check((b["gas"] as Rect2).position.x > 1920 * 0.75 and (b["left"] as Rect2).end.x < 1920 * 0.3, "pedals on the right, steering on the left")
	var overlap := false
	var keys := b.keys()
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			if (b[keys[i]] as Rect2).intersects(b[keys[j]]):
				overlap = true
	_check(not overlap, "no buttons overlap")

	# gas: ramps up, not instant
	_touch(0, (b["gas"] as Rect2).get_center(), true)
	_run(1.0 / 60.0)
	var first := Input.get_action_strength("throttle")
	_run(0.3)
	_check(first > 0.0 and first < 0.3, "gas ramps in (%.2f after one frame)" % first)
	_check(Input.get_action_strength("throttle") > 0.99, "holding gas gives full throttle")
	# second finger on the left button while gas is held
	_touch(1, (b["left"] as Rect2).get_center(), true)
	_run(0.4)
	_check(Input.get_action_strength("steer_left") > 0.99 and Input.get_action_strength("throttle") > 0.99, "multitouch: steer left while on the gas")
	_touch(1, (b["left"] as Rect2).get_center(), false)
	_run(0.3)
	_check(Input.get_action_strength("steer_left") < 0.01, "steering returns to center when let go")
	# slide gas finger onto the brake
	_drag(0, (b["brake"] as Rect2).get_center())
	_run(0.4)
	_check(Input.get_action_strength("brake") > 0.99 and Input.get_action_strength("throttle") < 0.01, "sliding from gas to brake swaps pedals")
	_touch(0, (b["brake"] as Rect2).get_center(), false)
	_run(0.3)
	_check(Input.get_action_strength("brake") < 0.01, "brake released")

	# one-shot buttons send action events
	for k in ["pause", "camera", "reset", "gear_up", "gear_down"]:
		_touch(2, (b[k] as Rect2).get_center(), true)
		_check(tc._fingers.get(2, "") == k, "%s button takes the touch" % k)
		_touch(2, (b[k] as Rect2).get_center(), false)
	# handbrake is held, not tapped
	_touch(3, (b["handbrake"] as Rect2).get_center(), true)
	_check(Input.is_action_pressed("handbrake"), "handbrake held while touched")
	_touch(3, (b["handbrake"] as Rect2).get_center(), false)
	_check(not Input.is_action_pressed("handbrake"), "handbrake let go")

	# touches outside buttons are left alone
	_touch(4, Vector2(960, 300), true)
	_check(not tc._fingers.has(4), "a touch on empty screen isn't taken")

	# tilt maths
	_check(absf(TouchControls._roll(Vector3(0, 9.8, 0))) < 0.01, "device upright = 0° roll")
	_check(absf(TouchControls._roll(Vector3(9.8 * sin(deg_to_rad(20)), 9.8 * cos(deg_to_rad(20)), 0)) - 20.0) < 0.1, "20° turn reads as 20°")
	tc.tilt_available = true
	tc.settings["touch_steer"] = "tilt"
	tc._layout()
	_check(not tc._buttons.has("left") and tc._buttons.has("center"), "tilt mode: no ◀ ▶, a CENTER button instead")

	# release everything
	_touch(5, (tc._buttons["gas"] as Rect2).get_center(), true)
	_run(0.3)
	tc.release_all()
	_check(Input.get_action_strength("throttle") == 0.0 and tc._fingers.is_empty(), "release_all lets go of every pedal")
	print("ALL PASSED (0 failed)" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails > 0 else 0)
