class_name TireForm
extends VBoxContainer
## Tire size + cold pressure entry (front and rear). Shows what each size
## works out to as you type. Empty rear fields mean "same as front".

signal changed

var front_size: LineEdit
var rear_size: LineEdit
var front_psi: LineEdit
var rear_psi: LineEdit
var feedback: Label

func _init() -> void:
	# built here (not in _ready) so set_values works before it's on screen
	add_theme_constant_override("separation", 8)
	add_child(UIKit.label("TIRES (from the door sticker or sidewall)", 22, UIKit.ACCENT))
	var g := GridContainer.new()
	g.columns = 3
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 8)
	add_child(g)
	g.add_child(UIKit.label("", 20))
	g.add_child(UIKit.label("Size", 20, UIKit.DIM))
	g.add_child(UIKit.label("PSI (cold)", 20, UIKit.DIM))
	g.add_child(UIKit.label("Front", 24))
	front_size = _edit("e.g. P245/75R16", 250, false)
	g.add_child(front_size)
	front_psi = _edit("e.g. 35", 120, true)
	g.add_child(front_psi)
	g.add_child(UIKit.label("Rear", 24))
	rear_size = _edit("same as front", 250, false)
	g.add_child(rear_size)
	rear_psi = _edit("same", 120, true)
	g.add_child(rear_psi)
	feedback = UIKit.label("", 20, UIKit.DIM)
	feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(feedback)
	_update()

func _edit(hint: String, w: float, numeric: bool) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = hint
	e.custom_minimum_size = Vector2(w, 64)
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if numeric:
		e.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER_DECIMAL
	e.text_changed.connect(func(_t): _update())
	return e

func set_values(t: Dictionary) -> void:
	front_size.text = t.get("front", "")
	var rear: String = t.get("rear", "")
	rear_size.text = "" if rear == t.get("front", "") else rear
	var fp: float = t.get("front_psi", 0.0)
	var rp: float = t.get("rear_psi", 0.0)
	front_psi.text = ("%d" % fp) if fp > 0 else ""
	rear_psi.text = ("%d" % rp) if (rp > 0 and rp != fp) else ""
	_update()

## [front size, rear size, front psi, rear psi] with blanks filled from the front.
func values() -> Array:
	var f := front_size.text.strip_edges()
	var r := rear_size.text.strip_edges()
	var fp := front_psi.text.strip_edges()
	var rp := rear_psi.text.strip_edges()
	return [f, r if r != "" else f, fp.to_float(), (rp if rp != "" else fp).to_float()]

func is_valid() -> bool:
	var v := values()
	return not TireSpec.parse(v[0]).is_empty() and not TireSpec.parse(v[1]).is_empty() \
		and TireSpec.valid_psi(str(v[2])) and TireSpec.valid_psi(str(v[3]))

func _describe(label: String, s: String) -> String:
	if s.strip_edges() == "":
		return ""
	var p := TireSpec.parse(s)
	if p.is_empty():
		return "%s: “%s” isn't a size I recognize (try P245/75R16, 245/40ZR18 or 31x10.50R15)." % [label, s]
	return "%s: %s = %.1f in tall, %.1f in wide, %s in wheel" % [label, p["size"], p["diameter_in"], p["width_m"] / 0.0254, TireSpec._rim(p["rim_in"])]

func _update() -> void:
	if feedback == null:
		return
	var v := values()
	var lines := []
	var fd := _describe("Front", front_size.text)
	if fd != "":
		lines.append(fd)
	if rear_size.text.strip_edges() != "":
		lines.append(_describe("Rear", rear_size.text))
	for pair in [["Front", front_psi.text], ["Rear", rear_psi.text]]:
		var t: String = pair[1].strip_edges()
		if t != "" and not TireSpec.valid_psi(t):
			lines.append("%s pressure should be 10 to 90 PSI." % pair[0])
	if front_psi.text.strip_edges() == "" and front_size.text.strip_edges() != "":
		lines.append("Enter the front tire pressure.")
	feedback.text = "\n".join(lines)
	feedback.add_theme_color_override("font_color", UIKit.GOOD if is_valid() else UIKit.DIM)
	changed.emit()
