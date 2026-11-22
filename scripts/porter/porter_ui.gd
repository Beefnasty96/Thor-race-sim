class_name PorterUI
extends RefCounted
## Small helpers for Car Porter's touch UI (phone-sized hit targets).

const BTN_H := 72.0

static func button(text: String, cb: Callable, min_w: float = 0.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, BTN_H)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b

static func toggle(text: String, on: bool, cb: Callable) -> Button:
	var b := button(text, func(): pass)
	b.toggle_mode = true
	b.button_pressed = on
	b.toggled.connect(cb)
	return b

static func fmt_len(m: float, units: String) -> String:
	if units == "metric":
		return "%d mm" % roundi(m * 1000.0)
	return "%.1f in" % (m / 0.0254)

## Parse a length typed by the user in the current units ("188.0", "188 in", "4775mm").
static func parse_len(text: String, units: String) -> float:
	var t := text.strip_edges().to_lower()
	var mult := 0.001 if units == "metric" else 0.0254
	if t.ends_with("mm"):
		mult = 0.001; t = t.trim_suffix("mm")
	elif t.ends_with("cm"):
		mult = 0.01; t = t.trim_suffix("cm")
	elif t.ends_with("in") or t.ends_with("\""):
		mult = 0.0254; t = t.trim_suffix("in").trim_suffix("\"")
	elif t.ends_with("m"):
		mult = 1.0; t = t.trim_suffix("m")
	t = t.strip_edges()
	if not t.is_valid_float():
		return -1.0
	return t.to_float() * mult

static func value_in_units(m: float, units: String) -> String:
	if units == "metric":
		return "%d" % roundi(m * 1000.0)
	return "%.1f" % (m / 0.0254)

static func unit_suffix(units: String) -> String:
	return "mm" if units == "metric" else "in"
