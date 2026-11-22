class_name TireSpec
extends RefCounted
## Parses tire sizes as printed on the sidewall or door placard:
##   P245/75R16, LT265/75R16, 245/40ZR18 97W, 185/65 R15, 205/55-16,
##   31x10.50R15 (flotation, inches), 7.75-15 / 7.75x15 (old bias-ply).
## Returns {} if the text isn't a tire size.

static func parse(text: String) -> Dictionary:
	var t := text.strip_edges().to_upper().replace(" ", "")
	var re := RegEx.new()
	# metric: [P|LT|T|ST] width / aspect [R|ZR|D|B|-] rim
	re.compile("^(P|LT|ST|T)?(\\d{3})/(\\d{2})(ZR|R|D|B|-)?F?(\\d{2}(?:\\.5)?)")
	var m := re.search(t)
	if m:
		var w := m.get_string(2).to_float()          # mm
		var ar := m.get_string(3).to_float()         # %
		var rim := m.get_string(5).to_float()        # inches
		var cons := "ZR" if m.get_string(4) == "ZR" else "R"
		if w < 100 or w > 400 or ar < 20 or ar > 90 or rim < 10 or rim > 26:
			return {}
		var dia_m := rim * 0.0254 + 2.0 * w * ar / 100000.0
		return _out(m.get_string(1), "%s%d/%d%s%s" % [m.get_string(1), int(w), int(ar), cons, _rim(rim)], dia_m, w / 1000.0, rim)
	# flotation: diameter x width R rim (inches)
	re.compile("^(LT)?(\\d{2}(?:\\.\\d)?)X(\\d{1,2}(?:\\.\\d{1,2})?)(?:R|-)?(\\d{2}(?:\\.5)?)")
	m = re.search(t)
	if m:
		var d := m.get_string(2).to_float()
		var wi := m.get_string(3).to_float()
		var rim2 := m.get_string(4).to_float()
		if d < 20 or d > 44 or wi < 6 or wi > 20 or rim2 < 13 or rim2 > 24 or d <= rim2:
			return {}
		return _out(m.get_string(1), "%sx%sR%s" % [_rim(d), _rim(wi), _rim(rim2)], d * 0.0254, wi * 0.0254, rim2)
	# old bias-ply / numeric: section width (in) - rim (aspect ~82%)
	re.compile("^(\\d{1,2}\\.\\d{2})(?:-|X)(\\d{2})$")
	m = re.search(t)
	if m:
		var sw := m.get_string(1).to_float()
		var rim3 := m.get_string(2).to_float()
		if sw < 4 or sw > 12 or rim3 < 10 or rim3 > 17:
			return {}
		return _out("", "%s-%d" % [m.get_string(1), int(rim3)], (rim3 + 2.0 * sw * 0.82) * 0.0254, sw * 0.0254, rim3)
	return {}

static func _out(prefix: String, label: String, dia_m: float, width_m: float, rim_in: float) -> Dictionary:
	return {"size": label, "radius_m": snappedf(dia_m * 0.5, 0.0001), "width_m": snappedf(width_m, 0.0001),
		"rim_in": rim_in, "diameter_in": snappedf(dia_m / 0.0254, 0.1), "light_truck": prefix == "LT"}

static func _rim(x: float) -> String:
	return str(int(x)) if is_equal_approx(x, roundf(x)) else str(x)

## Find a tire size inside longer text ("P245/75R16 109S all-season on ...").
static func find_in(text: String) -> Dictionary:
	for word in text.split(" ", false):
		var p := parse(word)
		if not p.is_empty():
			return p
	return parse(text)

static func valid_psi(text: String) -> bool:
	var t := text.strip_edges()
	return t.is_valid_float() and t.to_float() >= 10.0 and t.to_float() <= 90.0
