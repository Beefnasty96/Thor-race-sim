class_name UIKit
extends RefCounted
## Shared look: clean, cool-toned panels and crisp white type in the spirit of
## early-2000s console racing menus.

const ACCENT := Color(0.32, 0.62, 1.0)
const PANEL := Color(0.04, 0.07, 0.12, 0.78)
const TEXT := Color(0.94, 0.96, 1.0)
const DIM := Color(0.62, 0.68, 0.78)
const WARN := Color(1.0, 0.72, 0.2)
const BAD := Color(1.0, 0.3, 0.25)
const GOOD := Color(0.4, 0.95, 0.55)

static func theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 26
	var panel := StyleBoxFlat.new()
	panel.bg_color = PANEL
	panel.border_color = Color(1, 1, 1, 0.12)
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(6)
	panel.content_margin_left = 18; panel.content_margin_right = 18
	panel.content_margin_top = 14; panel.content_margin_bottom = 14
	t.set_stylebox("panel", "PanelContainer", panel)
	var btn := StyleBoxFlat.new()
	btn.bg_color = Color(0.1, 0.14, 0.22, 0.85)
	btn.set_corner_radius_all(4)
	btn.content_margin_left = 20; btn.content_margin_right = 20
	btn.content_margin_top = 10; btn.content_margin_bottom = 10
	var focus := btn.duplicate()
	focus.bg_color = Color(0.18, 0.40, 0.78, 0.95)
	focus.border_color = Color(0.75, 0.88, 1.0)
	focus.set_border_width_all(2)
	var hover := btn.duplicate()
	hover.bg_color = Color(0.16, 0.26, 0.44, 0.95)
	t.set_stylebox("normal", "Button", btn)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", focus)
	t.set_stylebox("focus", "Button", focus)
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_focus_color", "Button", Color.WHITE)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_color", "Label", TEXT)
	return t

static func label(text: String, size: int = 26, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

static func temp_color(c: float, cold: float, ideal: float, hot: float) -> Color:
	if c < ideal:
		return Color(0.25, 0.55, 1.0).lerp(Color(0.35, 0.95, 0.45), clampf((c - cold) / (ideal - cold), 0, 1))
	return Color(0.35, 0.95, 0.45).lerp(Color(1.0, 0.25, 0.15), clampf((c - ideal) / (hot - ideal), 0, 1))


## A gamepad-friendly option row: Left/Right (or A) cycles through values.
class OptionRow extends Button:
	signal value_changed(key: String, value)
	var key := ""
	var title := ""
	var values: Array = []
	var labels: Array = []
	var index := 0

	func setup(k: String, t: String, vals: Array, labs: Array, current) -> OptionRow:
		key = k; title = t; values = vals; labels = labs
		index = maxi(0, _find(current))
		alignment = HORIZONTAL_ALIGNMENT_LEFT
		custom_minimum_size = Vector2(760, 52)
		focus_mode = Control.FOCUS_ALL
		_refresh()
		pressed.connect(func(): step(1))
		return self

	func _find(v) -> int:
		for i in values.size():
			if typeof(values[i]) == TYPE_FLOAT or typeof(v) == TYPE_FLOAT:
				if absf(float(values[i]) - float(v)) < 0.0001:
					return i
			elif values[i] == v:
				return i
		return 0

	func step(d: int) -> void:
		index = wrapi(index + d, 0, values.size())
		_refresh()
		value_changed.emit(key, values[index])

	func _refresh() -> void:
		text = "%s    ◀  %s  ▶" % [title.rpad(26), str(labels[index])]

	func _gui_input(e: InputEvent) -> void:
		if e.is_action_pressed("ui_left"):
			step(-1); accept_event()
		elif e.is_action_pressed("ui_right"):
			step(1); accept_event()
