class_name DashPhotoView
extends Control
## The dash photo (taken from the driver's seat) with the dash outline drawn
## over it. Drag to slide the outline over the photo, pinch / mouse wheel to
## size it, so the photo lands on the dash. In gauge mode a tap places the
## chosen gauge (or picks an existing one); gauges show as circles.

signal fit_changed(final: bool)
signal gauge_tapped(frame_pt: Vector2, index: int)   # index = existing gauge hit, or -1

var project: PorterProject
var dash: HalfMesh
var texture: Texture2D
var img_size := Vector2.ONE
var placing := false                 # taps place / pick gauges instead of dragging
var selected := -1
var _touches := {}
var _start := {}
var _moved := false

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	custom_minimum_size = Vector2(0, 360)

func setup(p: PorterProject, d: HalfMesh) -> void:
	project = p
	dash = d
	var img := project.load_photo("dash")
	texture = ImageTexture.create_from_image(img) if img else null
	if img:
		img_size = Vector2(img.get_width(), img.get_height())
	queue_redraw()

## Fit the photo so its width spans the dash and it sits on the dash face.
static func fit_to_dash(p: PorterProject, d: HalfMesh, img_w: float) -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for e in InteriorBuilder.dash_outline(d):
		for q in e:
			lo = lo.min(q)
			hi = hi.max(q)
	var v: Dictionary = p.views["dash"]
	v["flip"] = false
	v["rot"] = 0.0
	if lo.x == INF:
		return
	v["mpp"] = (hi.x - lo.x) / maxf(img_w, 1.0)
	v["cx"] = (lo.x + hi.x) * 0.5
	v["cy"] = (lo.y + hi.y) * 0.5

# photo pixels <-> control pixels: the photo is fitted inside the control
func _k() -> float:
	return minf(size.x / img_size.x, size.y / img_size.y)

func _ofs() -> Vector2:
	return (size - img_size * _k()) * 0.5

func _px_to_screen(px: Vector2) -> Vector2:
	return _ofs() + px * _k()

func _screen_to_px(s: Vector2) -> Vector2:
	return (s - _ofs()) / _k()

func _frame_to_screen(f: Vector2) -> Vector2:
	return _px_to_screen(project.frame_to_image("dash", f, img_size))

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.05, 0.09))
	var font := get_theme_default_font()
	if texture == null:
		draw_string(font, Vector2(20, size.y * 0.5), "Load a dash photo (taken from the driver's seat).", HORIZONTAL_ALIGNMENT_LEFT, -1, 24, UIKit.WARN)
		return
	draw_texture_rect(texture, Rect2(_ofs(), img_size * _k()), false)
	for e in InteriorBuilder.dash_outline(dash):
		draw_line(_frame_to_screen(e[0]), _frame_to_screen(e[1]), Color(0.35, 0.78, 1.0, 0.9), 2.0, true)
	var gs: Array = project.interior.get("gauges", [])
	for i in gs.size():
		var g: Dictionary = gs[i]
		var c := _frame_to_screen(Vector2(g["x"], g["y"]))
		var r := (_frame_to_screen(Vector2(float(g["x"]) + float(g["r"]), g["y"])) - c).length()
		var col := Color(1.0, 0.65, 0.15) if i == selected else Color(1, 1, 1, 0.9)
		draw_arc(c, r, 0, TAU, 32, col, 3.0, true)
		draw_string(font, c + Vector2(-r, -r - 6), InteriorBuilder.GAUGE_TYPES[g["type"]]["label"], HORIZONTAL_ALIGNMENT_LEFT, -1, 18, col)
		if not g.get("on_dash", true):
			draw_string(font, c + Vector2(-r, r + 18), "off the dash", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, UIKit.WARN)
	var tip := "Tap where the gauge goes (or tap a gauge to pick it)" if placing else "Drag / pinch the photo so the blue dash outline sits on the dash"
	draw_string(font, Vector2(14, 28), tip, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(1, 1, 1, 0.85))

func _gauge_at(s: Vector2) -> int:
	var gs: Array = project.interior.get("gauges", [])
	for i in range(gs.size() - 1, -1, -1):
		var g: Dictionary = gs[i]
		var c := _frame_to_screen(Vector2(g["x"], g["y"]))
		var r := (_frame_to_screen(Vector2(float(g["x"]) + float(g["r"]), g["y"])) - c).length()
		if s.distance_to(c) <= maxf(r, 24.0):
			return i
	return -1

func _gui_input(e: InputEvent) -> void:
	if texture == null:
		return
	if e is InputEventScreenTouch:
		if e.pressed:
			_touches[e.index] = e.position
			_moved = false
		else:
			_touches.erase(e.index)
			if _touches.is_empty():
				if placing and not _moved:
					var hit := _gauge_at(e.position)
					gauge_tapped.emit(project.image_to_frame("dash", _screen_to_px(e.position), img_size), hit)
				elif _moved:
					fit_changed.emit(true)
		_start = {"t": _touches.duplicate(), "v": project.views["dash"].duplicate()}
		accept_event()
	elif e is InputEventScreenDrag:
		_touches[e.index] = e.position
		var st: Dictionary = _start.get("t", {})
		var keys := _touches.keys()
		var v0: Dictionary = _start["v"]
		var v: Dictionary = project.views["dash"]
		if keys.size() == 1 and st.has(keys[0]):
			var d: Vector2 = (_touches[keys[0]] - st[keys[0]]) / _k()
			if d.length() > 6.0:
				_moved = true
			if placing:
				return
			# outline follows the finger: frame point now maps d pixels further along
			v["cx"] = float(v0["cx"]) - d.x * float(v0["mpp"])
			v["cy"] = float(v0["cy"]) + d.y * float(v0["mpp"])
		elif keys.size() >= 2 and st.has(keys[0]) and st.has(keys[1]):
			_moved = true
			var k: float = (_touches[keys[1]] - _touches[keys[0]]).length() / maxf((st[keys[1]] - st[keys[0]]).length(), 1.0)
			v["mpp"] = clampf(float(v0["mpp"]) / k, 1e-5, 1.0)
		queue_redraw()
		fit_changed.emit(false)
		accept_event()
	elif e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			nudge_size(1.02)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			nudge_size(1.0 / 1.02)

## k > 1 makes the outline bigger on the photo.
func nudge_size(k: float) -> void:
	project.views["dash"]["mpp"] = float(project.views["dash"]["mpp"]) / k
	queue_redraw()
	fit_changed.emit(true)

func nudge_move(dx: float, dy: float) -> void:
	var v: Dictionary = project.views["dash"]
	var m := 3.0 / _k() * float(v["mpp"])
	v["cx"] = float(v["cx"]) - dx * m
	v["cy"] = float(v["cy"]) + dy * m
	queue_redraw()
	fit_changed.emit(true)
