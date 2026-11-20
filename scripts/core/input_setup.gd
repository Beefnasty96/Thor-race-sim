class_name InputSetup
extends RefCounted
## Input bindings, laid out to the XInput (Xbox controller) standard.
##
## Godot's gamepad layer uses the XInput layout and naming on every platform:
## on Windows it talks to XInput directly; on Android/Linux it maps controllers
## through the SDL GameController database onto the same layout. So an Xbox
## pad, the AYN Thor's built-in controls (set to Xbox layout) or any
## XInput-compatible controller all map the same way.
##
##   XInput control     Godot constant              Action
##   ----------------   -------------------------   ---------------------------
##   RT (analog)        JOY_AXIS_TRIGGER_RIGHT      throttle
##   LT (analog)        JOY_AXIS_TRIGGER_LEFT       brake (hold at a stop: reverse)
##   Left stick X       JOY_AXIS_LEFT_X             steer
##   Right stick X      JOY_AXIS_RIGHT_X            look left / right
##   RB / LB            JOY_BUTTON_RIGHT/LEFT_SHOULDER  shift up / down (manual)
##   A                  JOY_BUTTON_A                handbrake · menu select
##   B                  JOY_BUTTON_B                menu back
##   X                  JOY_BUTTON_X                look back
##   Y                  JOY_BUTTON_Y                change camera
##   Back (View)        JOY_BUTTON_BACK             telemetry on/off
##   Start (Menu)       JOY_BUTTON_START            pause
##   D-pad up / down    JOY_BUTTON_DPAD_UP/DOWN     transfer case / auto-manual
##   RS click           JOY_BUTTON_RIGHT_STICK      reset onto road
##   Motors             Input.start_joy_vibration   rumble (see rumble.gd)

const STICK_ACTIONS := ["steer_left", "steer_right", "look_left", "look_right"]
const TRIGGER_ACTIONS := ["throttle", "brake"]

static func register() -> void:
	_axis("throttle", JOY_AXIS_TRIGGER_RIGHT, 1.0, [KEY_W, KEY_UP])
	_axis("brake", JOY_AXIS_TRIGGER_LEFT, 1.0, [KEY_S, KEY_DOWN])
	_axis("steer_left", JOY_AXIS_LEFT_X, -1.0, [KEY_A, KEY_LEFT])
	_axis("steer_right", JOY_AXIS_LEFT_X, 1.0, [KEY_D, KEY_RIGHT])
	_axis("look_left", JOY_AXIS_RIGHT_X, -1.0, [])
	_axis("look_right", JOY_AXIS_RIGHT_X, 1.0, [])
	_button("shift_up", JOY_BUTTON_RIGHT_SHOULDER, [KEY_E])
	_button("shift_down", JOY_BUTTON_LEFT_SHOULDER, [KEY_Q])
	_button("handbrake", JOY_BUTTON_A, [KEY_SPACE])
	_button("camera", JOY_BUTTON_Y, [KEY_C])
	_button("look_back", JOY_BUTTON_X, [KEY_B])
	_button("telemetry", JOY_BUTTON_BACK, [KEY_T])
	_button("pause", JOY_BUTTON_START, [KEY_ESCAPE, KEY_P])
	_button("transfer_case", JOY_BUTTON_DPAD_UP, [KEY_4])
	_button("trans_mode", JOY_BUTTON_DPAD_DOWN, [KEY_M])
	_button("reset_car", JOY_BUTTON_RIGHT_STICK, [KEY_R])
	# menus: A selects, B goes back (XInput convention)
	_button("ui_accept", JOY_BUTTON_A, [])
	_button("ui_cancel", JOY_BUTTON_B, [])

## Apply deadzones from settings. XInput reports sticks as signed 16-bit and
## triggers as 0-255; Microsoft's suggested defaults are ~24% for the left
## stick and ~12% (30/255) for triggers. Hall-effect sticks like the Thor's
## can go much lower. Strength is rescaled past the deadzone, so full travel
## still gives 100%.
static func apply_deadzones(settings: Dictionary) -> void:
	var stick: float = settings.get("stick_deadzone", 0.10)
	var trig: float = settings.get("trigger_deadzone", 0.06)
	for a in STICK_ACTIONS:
		if InputMap.has_action(a):
			InputMap.action_set_deadzone(a, stick)
	for a in TRIGGER_ACTIONS:
		if InputMap.has_action(a):
			InputMap.action_set_deadzone(a, trig)

## Human-readable description of the connected controller(s).
static func controller_info() -> String:
	var pads := Input.get_connected_joypads()
	if pads.is_empty():
		return "No controller detected"
	var parts := []
	for id in pads:
		var known := Input.is_joy_known(id)
		parts.append("%s  (%s)" % [Input.get_joy_name(id), "XInput layout" if known else "unknown layout - using defaults"])
	return "\n".join(parts)

static func _ensure(action: String, deadzone: float = 0.2) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, deadzone)

static func _axis(action: String, axis: JoyAxis, dir: float, keys: Array) -> void:
	_ensure(action, 0.1)
	var e := InputEventJoypadMotion.new()
	e.device = -1                  # any controller
	e.axis = axis
	e.axis_value = dir
	InputMap.action_add_event(action, e)
	for k in keys:
		var ke := InputEventKey.new()
		ke.physical_keycode = k
		InputMap.action_add_event(action, ke)

static func _button(action: String, btn: JoyButton, keys: Array) -> void:
	_ensure(action)
	var e := InputEventJoypadButton.new()
	e.device = -1
	e.button_index = btn
	InputMap.action_add_event(action, e)
	for k in keys:
		var ke := InputEventKey.new()
		ke.physical_keycode = k
		InputMap.action_add_event(action, ke)
