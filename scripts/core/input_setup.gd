class_name InputSetup
extends RefCounted
## Registers input actions in code so bindings live in one readable place.
## AYN Thor: its built-in controls report as a standard Android gamepad
## (analog hall-effect L2/R2 triggers, two sticks, shoulders, D-pad).

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
	# menus: make sure the gamepad D-pad/stick and A/B drive the UI
	_button("ui_accept", JOY_BUTTON_A, [])
	_button("ui_cancel", JOY_BUTTON_B, [])

static func _ensure(action: String, deadzone: float = 0.08) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, deadzone)

static func _axis(action: String, axis: JoyAxis, dir: float, keys: Array) -> void:
	_ensure(action, 0.04)
	var e := InputEventJoypadMotion.new()
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
	e.button_index = btn
	InputMap.action_add_event(action, e)
	for k in keys:
		var ke := InputEventKey.new()
		ke.physical_keycode = k
		InputMap.action_add_event(action, ke)
