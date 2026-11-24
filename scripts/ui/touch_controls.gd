class_name TouchControls
extends Control
## Arcade-style on-screen driving controls for phones and touch screens.
##
## Right side: BRAKE and GAS pedals (hold; they ramp up quickly so a tap
## doesn't spin the tires). Steering: tilt the device like a wheel, or
## ◀ ▶ buttons on the left when there's no tilt sensor (or Steering is set
## to Buttons). Small buttons along the top: pause, camera, reset, and gear
## − / + (manual), plus a handbrake button above the pedals.
##
## Everything feeds the same input actions a controller uses
## (Input.action_press / InputEventAction), so the driving code doesn't know
## the difference. Multitouch: each finger is tracked on its own.
##
## Settings (Game.settings, passed in as `settings`): touch_controls "auto" | "on" | "off" (auto =
## shown on a touch screen with no controller connected), touch_steer
## "tilt" | "buttons", touch_tilt_invert, touch_tilt_range (degrees for full
## lock).

const PEDAL_RAMP := 6.0        # full pedal in ~0.17 s
const BUTTON_STEER_RAMP := 4.0 # ◀ ▶ reach full lock in 0.25 s
const TILT_DEADZONE := 2.0     # degrees

var settings: Dictionary = {}  # the game's settings (shared, so changes apply live)
var tilt_available := false
var neutral_angle := 0.0       # device roll that counts as straight ahead
var _fingers := {}             # touch index -> button name
var _held := {}                # button name -> true
var _gas := 0.0
var _brake := 0.0
var _steer := 0.0
var _buttons := {}             # name -> Rect2 (local)
var _calibrated := false

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	process_mode = Node.PROCESS_MODE_ALWAYS
	resized.connect(_layout)
	get_viewport().size_changed.connect(_fit)
	_fit()

## Cover the whole screen (the parent may not be sized).
func _fit() -> void:
	position = Vector2.ZERO
	size = get_viewport_rect().size
	_layout()

## Whether the overlay should be on right now, from the setting, the
## screen and connected controllers.
static func wanted(settings: Dictionary) -> bool:
	match settings.get("touch_controls", "auto"):
		"on":
			return true
		"off":
			return false
	return DisplayServer.is_touchscreen_available() and Input.get_connected_joypads().is_empty()

func use_tilt() -> bool:
	return tilt_available and settings.get("touch_steer", "tilt") == "tilt"

## Call when a drive starts: reads the tilt sensor and takes the current
## device angle as straight ahead.
func start() -> void:
	var a := Input.get_accelerometer()
	tilt_available = a.length() > 1.0
	_calibrated = false
	recalibrate()
	release_all()
	_layout()

func recalibrate() -> void:
	var a := Input.get_accelerometer()
	if a.length() > 1.0:
		neutral_angle = _roll(a)
		_calibrated = true

## Device roll in degrees: the direction of gravity in the screen's plane.
## Turning the phone like a wheel rotates gravity in this plane whatever way
## the sensor's axes are mapped to the screen.
static func _roll(a: Vector3) -> float:
	return rad_to_deg(atan2(a.x, a.y))

func _layout() -> void:
	var s := size
	if s.x < 10:
		return
	var u := minf(s.x, s.y * 2.0) / 100.0          # ~1% of a wide screen
	var pedal := Vector2(u * 11.0, s.y * 0.42)
	var margin := u * 2.5
	var gas := Rect2(Vector2(s.x - margin - pedal.x, s.y - margin - pedal.y), pedal)
	var brake := Rect2(gas.position - Vector2(pedal.x + margin, -pedal.y * 0.25), Vector2(pedal.x, pedal.y * 0.75))
	_buttons = {"gas": gas, "brake": brake}
	var hb := Vector2(pedal.x * 2.0 + margin, u * 7.0)
	_buttons["handbrake"] = Rect2(Vector2(brake.position.x, gas.position.y - margin - hb.y), hb)
	if not use_tilt():
		var sb := Vector2(u * 12.0, s.y * 0.3)
		_buttons["left"] = Rect2(Vector2(margin, s.y - margin - sb.y), sb)
		_buttons["right"] = Rect2(Vector2(margin * 2.0 + sb.x, s.y - margin - sb.y), sb)
	var small := Vector2(u * 8.0, u * 6.0)
	# top middle (the minimap is top right, test results top left)
	var x := s.x * 0.5 - small.x * 1.5 - margin * 0.6
	for name in ["reset", "camera", "pause"]:
		_buttons[name] = Rect2(Vector2(x, margin * 0.6), small)
		x += small.x + margin * 0.6
	_buttons["gear_up"] = Rect2(Vector2(margin, s.y * 0.36), small)
	_buttons["gear_down"] = Rect2(Vector2(margin, s.y * 0.36 + small.y + margin * 0.6), small)
	if use_tilt():
		_buttons["center"] = Rect2(Vector2(margin + small.x + margin * 0.6, s.y * 0.36), Vector2(small.x * 1.6, small.y))
	queue_redraw()

func _button_at(p: Vector2) -> String:
	for name in _buttons:
		if (_buttons[name] as Rect2).grow(6.0).has_point(p):
			return name
	return ""

func _input(e: InputEvent) -> void:
	if not visible:
		return
	if e is InputEventScreenTouch:
		var p := get_global_transform().affine_inverse() * (e as InputEventScreenTouch).position
		if e.pressed:
			var b := _button_at(p)
			if b == "":
				return
			_fingers[e.index] = b
			_press(b)
			_handled()
		elif _fingers.has(e.index):
			_release(_fingers[e.index])
			_fingers.erase(e.index)
			_handled()
	elif e is InputEventScreenDrag and _fingers.has(e.index):
		# sliding a finger between the pedals / steer buttons moves the press
		var p2 := get_global_transform().affine_inverse() * (e as InputEventScreenDrag).position
		var b2 := _button_at(p2)
		var cur: String = _fingers[e.index]
		if b2 != cur and b2 in ["gas", "brake", "left", "right"] and cur in ["gas", "brake", "left", "right"]:
			_release(cur)
			_fingers[e.index] = b2
			_press(b2)
		_handled()

func _handled() -> void:
	var vp := get_viewport()
	if vp:
		vp.set_input_as_handled()

func _press(b: String) -> void:
	_held[b] = true
	match b:
		"pause":
			_tap_action("pause")
		"camera":
			_tap_action("camera")
		"reset":
			_tap_action("reset_car")
		"gear_up":
			_tap_action("shift_up")
		"gear_down":
			_tap_action("shift_down")
		"center":
			recalibrate()
		"handbrake":
			Input.action_press("handbrake")
	queue_redraw()

func _release(b: String) -> void:
	_held.erase(b)
	if b == "handbrake":
		Input.action_release("handbrake")
	queue_redraw()

func _tap_action(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	Input.parse_input_event(up)

func release_all() -> void:
	for b in _held.keys():
		_release(b)
	_fingers.clear()
	_gas = 0.0
	_brake = 0.0
	_steer = 0.0
	for a in ["throttle", "brake", "steer_left", "steer_right", "handbrake"]:
		Input.action_release(a)

func _process(dt: float) -> void:
	if not visible:
		return
	_gas = move_toward(_gas, 1.0 if _held.has("gas") else 0.0, dt * PEDAL_RAMP * (1.0 if _held.has("gas") else 2.0))
	_brake = move_toward(_brake, 1.0 if _held.has("brake") else 0.0, dt * PEDAL_RAMP * (1.0 if _held.has("brake") else 2.0))
	if use_tilt():
		var a := Input.get_accelerometer()
		if a.length() > 1.0:
			if not _calibrated:
				recalibrate()
			var d := wrapf(_roll(a) - neutral_angle, -180.0, 180.0)
			if settings.get("touch_tilt_invert", false):
				d = -d
			var rng: float = settings.get("touch_tilt_range", 30.0)
			var mag := maxf(absf(d) - TILT_DEADZONE, 0.0) / maxf(rng - TILT_DEADZONE, 1.0)
			_steer = clampf(signf(d) * mag, -1.0, 1.0)
	else:
		var want := (1.0 if _held.has("right") else 0.0) - (1.0 if _held.has("left") else 0.0)
		_steer = move_toward(_steer, want, dt * BUTTON_STEER_RAMP * (1.0 if want != 0.0 else 2.0))
	_set_axis("throttle", _gas)
	_set_axis("brake", _brake)
	_set_axis("steer_right", maxf(_steer, 0.0))
	_set_axis("steer_left", maxf(-_steer, 0.0))
	queue_redraw()

func _set_axis(action: String, v: float) -> void:
	if v > 0.001:
		Input.action_press(action, v)
	else:
		Input.action_release(action)

## Current outputs (for tests and the settings readout).
func outputs() -> Dictionary:
	return {"gas": _gas, "brake": _brake, "steer": _steer}

func _draw() -> void:
	var font := get_theme_default_font()
	for name in _buttons:
		var r: Rect2 = _buttons[name]
		var on := _held.has(name)
		var base := Color(1, 1, 1, 0.10)
		var edge := Color(1, 1, 1, 0.35)
		match name:
			"gas":
				base = Color(0.2, 0.75, 0.3, 0.18 + 0.4 * _gas)
				edge = Color(0.4, 1.0, 0.5, 0.7)
			"brake":
				base = Color(0.85, 0.2, 0.2, 0.18 + 0.4 * _brake)
				edge = Color(1.0, 0.45, 0.45, 0.7)
		if on and not name in ["gas", "brake"]:
			base.a += 0.25
		draw_rect(r, base)
		draw_rect(r, edge, false, 3.0)
		var label: String = {"gas": "GAS", "brake": "BRAKE", "handbrake": "HANDBRAKE", "left": "◀", "right": "▶",
			"pause": "II", "camera": "CAM", "reset": "RESET", "gear_up": "GEAR +", "gear_down": "GEAR −",
			"center": "CENTER"}[name]
		var fs := int(clampf(r.size.y * (0.12 if name in ["gas", "brake"] else 0.36), 14.0, 40.0))
		if name in ["left", "right"]:
			fs = int(clampf(r.size.x * 0.4, 20.0, 64.0))
		var ts := font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
		draw_string(font, r.get_center() + Vector2(-ts.x * 0.5, ts.y * 0.3), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.9))
	if use_tilt():
		# steering indicator: a bar along the bottom middle
		var w := size.x * 0.24
		var c := Vector2(size.x * 0.5, size.y - 410.0)
		draw_line(c - Vector2(w * 0.5, 0), c + Vector2(w * 0.5, 0), Color(1, 1, 1, 0.3), 4.0)
		draw_circle(c + Vector2(_steer * w * 0.5, 0), 9.0, Color(1, 1, 1, 0.85))
