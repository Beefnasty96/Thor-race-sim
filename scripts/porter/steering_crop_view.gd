class_name SteeringCropView
extends Control
## The steering wheel photo with the round template (orange circle) over it.
## Drag / pinch to fit the circle to the wheel's outer rim. In hole mode, taps
## add points of a cut-out outline (the gaps between the spokes); finished
## holes are shaded and get cut through the wheel.

signal crop_changed(final: bool)
signal hole_point_added

var project: PorterProject
var texture: Texture2D
var img_size := Vector2.ONE
var crop := {}                      # cx, cy, r in photo pixels
var drawing := false                # taps add hole points
var hole_pts: Array = []            # unit-circle points of the hole being drawn
var _touches := {}
var _start := {}
var _moved := false

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	custom_minimum_size = Vector2(0, 420)

func setup(p: PorterProject) -> void:
	project = p
	var img := project.load_photo("steering")
	texture = ImageTexture.create_from_image(img) if img else null
	if img:
		img_size = Vector2(img.get_width(), img.get_height())
	crop = project.steering_crop().duplicate()
	queue_redraw()

## Screen pixels per photo pixel: the circle fills ~80% of the height.
func _scale() -> float:
	return size.y * 0.40 / maxf(float(crop.get("r", 1.0)), 1.0)

func _photo_to_screen(p: Vector2) -> Vector2:
	return size * 0.5 + (p - Vector2(crop["cx"], crop["cy"])) * _scale()

func unit_to_screen(u: Vector2) -> Vector2:
	return size * 0.5 + u * float(crop["r"]) * _scale()

func screen_to_unit(s: Vector2) -> Vector2:
	return (s - size * 0.5) / (float(crop["r"]) * _scale())

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.05, 0.09))
	var font := get_theme_default_font()
	if texture == null or crop.is_empty():
		draw_string(font, Vector2(20, size.y * 0.5), "Load a photo of the steering wheel (face-on).", HORIZONTAL_ALIGNMENT_LEFT, -1, 24, UIKit.WARN)
		return
	var a := _photo_to_screen(Vector2.ZERO)
	var b := _photo_to_screen(img_size)
	draw_texture_rect(texture, Rect2(a, b - a), false)
	var c := size * 0.5
	var r: float = float(crop["r"]) * _scale()
	# shade outside the template
	draw_arc(c, r + 400.0, 0, TAU, 64, Color(0, 0, 0, 0.5), 800.0, true)
	draw_arc(c, r, 0, TAU, 64, Color(1.0, 0.72, 0.2), 3.0, true)
	for h in project.steering()["holes"]:
		var poly := PackedVector2Array()
		for p in h:
			poly.append(unit_to_screen(Vector2(p[0], p[1])))
		if poly.size() >= 3 and Geometry2D.triangulate_polygon(poly).size() > 0:
			draw_colored_polygon(poly, Color(0.02, 0.03, 0.06, 0.8))
		poly.append(poly[0])
		draw_polyline(poly, Color(0.35, 0.78, 1.0), 2.5, true)
	if hole_pts.size() > 0:
		var live := PackedVector2Array()
		for p in hole_pts:
			live.append(unit_to_screen(p))
		if live.size() > 1:
			draw_polyline(live, Color(1.0, 0.65, 0.15), 3.0, true)
			draw_line(live[live.size() - 1], live[0], Color(1.0, 0.65, 0.15, 0.4), 2.0, true)
		for q in live:
			draw_circle(q, 7.0, Color(1.0, 0.65, 0.15))
	var tip := "Tap around a gap between the spokes, then Finish hole" if drawing else "Drag / pinch so the orange circle sits on the wheel's outer edge"
	draw_string(font, Vector2(14, 28), tip, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(1, 1, 1, 0.85))

func _gui_input(e: InputEvent) -> void:
	if texture == null or crop.is_empty():
		return
	if e is InputEventScreenTouch:
		if e.pressed:
			_touches[e.index] = e.position
			_moved = false
		else:
			_touches.erase(e.index)
			if _touches.is_empty():
				if drawing and not _moved:
					var u := screen_to_unit(e.position)
					if u.length() <= 1.05:
						hole_pts.append(u.limit_length(1.0))
						hole_point_added.emit()
						queue_redraw()
				elif _moved:
					crop_changed.emit(true)
		_start = {"t": _touches.duplicate(), "crop": crop.duplicate(), "scale": _scale()}
		accept_event()
	elif e is InputEventScreenDrag:
		_touches[e.index] = e.position
		var st: Dictionary = _start.get("t", {})
		var keys := _touches.keys()
		var c0: Dictionary = _start["crop"]
		if keys.size() == 1 and st.has(keys[0]):
			var d: Vector2 = (_touches[keys[0]] - st[keys[0]]) / float(_start["scale"])
			if d.length() * float(_start["scale"]) > 6.0:
				_moved = true
			if drawing:
				return
			crop["cx"] = float(c0["cx"]) - d.x
			crop["cy"] = float(c0["cy"]) - d.y
		elif keys.size() >= 2 and st.has(keys[0]) and st.has(keys[1]):
			_moved = true
			if drawing:
				return
			var k: float = (_touches[keys[1]] - _touches[keys[0]]).length() / maxf((st[keys[1]] - st[keys[0]]).length(), 1.0)
			crop["r"] = clampf(float(c0["r"]) * k, 8.0, 4000.0)
		queue_redraw()
		crop_changed.emit(false)
		accept_event()
	elif e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			nudge_size(1.02)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			nudge_size(1.0 / 1.02)

func nudge_size(k: float) -> void:
	crop["r"] = float(crop["r"]) * k
	queue_redraw()
	crop_changed.emit(true)

func nudge_move(dx: float, dy: float) -> void:
	var px := 2.0 / _scale()
	crop["cx"] = float(crop["cx"]) + dx * px
	crop["cy"] = float(crop["cy"]) + dy * px
	queue_redraw()
	crop_changed.emit(true)
