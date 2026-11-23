class_name BlueprintCanvas
extends Control
## Shows one reference photo over its true-scale outline and lets the user
## line them up by touch:
##   PHOTO mode : one finger drags the photo, two fingers pinch to scale and twist to rotate
##   VIEW mode  : one finger pans the view, pinch zooms (for precise taps)
##   ALIGN mode : tap the two reference points the prompt asks for
## Desktop: mouse drag acts as a finger (touch emulation), wheel zooms/scales, Q/E rotate.

enum Mode { PHOTO, VIEW, ALIGN }

signal align_progress(step: int)          # 0 = waiting for first tap, 1 = second, 2 = done
signal transform_changed

var project: PorterProject
var view := "side"
var mode := Mode.PHOTO
var texture: Texture2D
var img_size := Vector2.ONE

# view navigation (screen px per meter and pan offset in px)
var zoom := 1.0
var pan := Vector2.ZERO

var _touches := {}                        # index -> position
var _gesture_start := {}
var _align_pts: Array[Vector2] = []       # tapped image pixels
var _tap_start := Vector2.ZERO

const OUTLINE := Color(0.32, 0.72, 1.0, 0.95)
const GRID := Color(0.32, 0.62, 1.0, 0.16)
const MARK := Color(1.0, 0.72, 0.2)

func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	resized.connect(queue_redraw)

func set_view(p: PorterProject, v: String) -> void:
	project = p
	view = v
	_align_pts.clear()
	var img := project.load_photo(view)
	if img:
		texture = ImageTexture.create_from_image(img)
		img_size = Vector2(img.get_width(), img.get_height())
	else:
		texture = null
		img_size = Vector2.ONE
	reset_view()

func reset_view() -> void:
	zoom = 1.0
	pan = Vector2.ZERO
	queue_redraw()

func start_align() -> void:
	mode = Mode.ALIGN
	_align_pts.clear()
	align_progress.emit(0)
	queue_redraw()

# ---------------------------------------------------------------- coordinates

## Screen pixels per meter with the frame fitted to the control (plus zoom).
func ppm() -> float:
	var r := project.frame_rect(view)
	var fit := minf(size.x * 0.82 / r.size.x, size.y * 0.72 / r.size.y)
	return fit * zoom

func frame_to_screen(p: Vector2) -> Vector2:
	var r := project.frame_rect(view)
	var c := r.get_center()
	return size * 0.5 + pan + Vector2(p.x - c.x, -(p.y - c.y)) * ppm()

func screen_to_frame(s: Vector2) -> Vector2:
	var r := project.frame_rect(view)
	var c := r.get_center()
	var d := (s - size * 0.5 - pan) / ppm()
	return Vector2(c.x + d.x, c.y - d.y)

# ---------------------------------------------------------------- drawing

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.05, 0.09))
	if project == null:
		return
	_draw_grid()
	if texture:
		_draw_photo()
	_draw_outline()
	for i in _align_pts.size():
		var s := frame_to_screen(project.image_to_frame(view, _align_pts[i], img_size)) if mode != Mode.ALIGN \
			else _image_px_to_screen(_align_pts[i])
		_draw_cross(s, MARK, 26.0)
		draw_string(get_theme_default_font(), s + Vector2(14, -14), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 30, MARK)
	if mode == Mode.ALIGN:
		# show where the taps will land
		var tg := project.align_targets(view)
		for i in tg.size():
			var s2 := frame_to_screen(tg[i]["pos"])
			draw_circle(s2, 10.0, Color(OUTLINE, 0.5))
			draw_string(get_theme_default_font(), s2 + Vector2(-8, 40), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 26, OUTLINE)

func _image_px_to_screen(px: Vector2) -> Vector2:
	return frame_to_screen(project.image_to_frame(view, px, img_size))

func _draw_photo() -> void:
	var v: Dictionary = project.views[view]
	var corners := [Vector2(0, 0), Vector2(img_size.x, 0), img_size, Vector2(0, img_size.y)]
	var pts := PackedVector2Array()
	for c in corners:
		pts.append(_image_px_to_screen(c))
	var uvs := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	var col := Color(1, 1, 1, float(v["opacity"]))
	draw_colored_polygon(pts, col, uvs, texture)

func _draw_grid() -> void:
	# 0.5 m grid around the frame
	var r := project.frame_rect(view).grow(1.0)
	var step := 0.5
	var x := snappedf(r.position.x, step)
	while x <= r.end.x:
		draw_line(frame_to_screen(Vector2(x, r.position.y)), frame_to_screen(Vector2(x, r.end.y)), GRID, 1.0)
		x += step
	var y := snappedf(r.position.y, step)
	while y <= r.end.y:
		draw_line(frame_to_screen(Vector2(r.position.x, y)), frame_to_screen(Vector2(r.end.x, y)), GRID, 1.0)
		y += step

func _draw_outline() -> void:
	var r := project.frame_rect(view)
	var a := frame_to_screen(Vector2(r.position.x, r.end.y))
	var b := frame_to_screen(Vector2(r.end.x, r.position.y))
	draw_rect(Rect2(a, b - a), OUTLINE, false, 2.0)
	var d := project.dims
	match view:
		"side":
			# ground line, axle lines and wheel circles
			draw_line(frame_to_screen(Vector2(r.position.x - 0.6, 0)), frame_to_screen(Vector2(r.end.x + 0.6, 0)), OUTLINE, 2.0)
			for ax in [project.front_axle_x(), project.rear_axle_x()]:
				var tr := project.tire_radius(ax != project.front_axle_x())
				var c := frame_to_screen(Vector2(ax, tr))
				draw_arc(c, tr * ppm(), 0, TAU, 48, OUTLINE, 2.0)
				_draw_cross(c, OUTLINE, 12.0)
				draw_dashed_line(frame_to_screen(Vector2(ax, 0)), frame_to_screen(Vector2(ax, d["height_m"])), Color(OUTLINE, 0.5), 1.5, 10.0)
			_label_dim(Vector2(r.get_center().x, -0.25), _len(d["length_m"]))
			_label_dim(Vector2((project.front_axle_x() + project.rear_axle_x()) * 0.5, d["tire_radius_m"] + 0.12), "wheelbase " + _len(d["wheelbase_m"]))
		"front", "rear":
			draw_line(frame_to_screen(Vector2(r.position.x - 0.6, 0)), frame_to_screen(Vector2(r.end.x + 0.6, 0)), OUTLINE, 2.0)
			var t: float = d["track_front_m" if view == "front" else "track_rear_m"] * 0.5
			for sx in [-t, t]:
				_draw_cross(frame_to_screen(Vector2(sx, 0)), OUTLINE, 12.0)
				draw_dashed_line(frame_to_screen(Vector2(sx, 0)), frame_to_screen(Vector2(sx, project.tire_radius(view == "rear") * 2.0)), Color(OUTLINE, 0.5), 1.5, 10.0)
			_label_dim(Vector2(0, -0.25), _len(d["width_m"]))
			draw_dashed_line(frame_to_screen(Vector2(0, 0)), frame_to_screen(Vector2(0, d["height_m"])), Color(OUTLINE, 0.35), 1.0, 8.0)
		"top":
			draw_dashed_line(frame_to_screen(Vector2(r.position.x, 0)), frame_to_screen(Vector2(r.end.x, 0)), Color(OUTLINE, 0.35), 1.0, 8.0)
			for ax in [project.front_axle_x(), project.rear_axle_x()]:
				var tt: float = d["track_front_m" if ax == project.front_axle_x() else "track_rear_m"] * 0.5
				draw_line(frame_to_screen(Vector2(ax, -tt)), frame_to_screen(Vector2(ax, tt)), Color(OUTLINE, 0.5), 1.5)
				for sy in [-tt, tt]:
					_draw_cross(frame_to_screen(Vector2(ax, sy)), OUTLINE, 10.0)
			_label_dim(Vector2(r.get_center().x, r.position.y - 0.25), _len(d["length_m"]))
	var f := get_theme_default_font()
	draw_string(f, Vector2(18, size.y - 18), "◀ FRONT" if view in ["side", "top"] else "", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(OUTLINE, 0.8))

func _label_dim(p: Vector2, text: String) -> void:
	var f := get_theme_default_font()
	var s := frame_to_screen(p)
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
	draw_string(f, s - Vector2(w * 0.5, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, OUTLINE)

func _len(m: float) -> String:
	return PorterUI.fmt_len(m, project.units)

func _draw_cross(c: Vector2, col: Color, s: float) -> void:
	draw_line(c - Vector2(s, 0), c + Vector2(s, 0), col, 2.0)
	draw_line(c - Vector2(0, s), c + Vector2(0, s), col, 2.0)

# ---------------------------------------------------------------- input

func _gui_input(e: InputEvent) -> void:
	if project == null:
		return
	if e is InputEventScreenTouch:
		if e.pressed:
			_touches[e.index] = e.position
			if _touches.size() == 1:
				_tap_start = e.position
			_begin_gesture()
		else:
			if mode == Mode.ALIGN and _touches.size() == 1 and e.position.distance_to(_tap_start) < 24.0:
				_align_tap(e.position)
			_touches.erase(e.index)
			_begin_gesture()
		accept_event()
	elif e is InputEventScreenDrag:
		_touches[e.index] = e.position
		_apply_gesture()
		accept_event()
	elif e is InputEventMouseButton and e.pressed:
		var k := 0.0
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			k = 1.1
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			k = 1.0 / 1.1
		if k != 0.0:
			if mode == Mode.PHOTO and texture:
				_scale_photo_about(e.position, k)
			else:
				_zoom_about(e.position, k)
			accept_event()
	elif e is InputEventKey and e.pressed and mode == Mode.PHOTO and texture:
		if e.keycode == KEY_Q:
			nudge_rotate(-0.25)
		elif e.keycode == KEY_E:
			nudge_rotate(0.25)

func _begin_gesture() -> void:
	_gesture_start = {"touches": _touches.duplicate(), "zoom": zoom, "pan": pan,
		"view": project.views[view].duplicate()}

func _apply_gesture() -> void:
	if _gesture_start.is_empty():
		return
	var st: Dictionary = _gesture_start["touches"]
	var keys := _touches.keys()
	if keys.size() == 1 and st.has(keys[0]):
		var delta: Vector2 = _touches[keys[0]] - st[keys[0]]
		if mode == Mode.PHOTO and texture:
			var v0: Dictionary = _gesture_start["view"]
			var v: Dictionary = project.views[view]
			var dm := Vector2(delta.x, -delta.y) / ppm()
			v["cx"] = v0["cx"] + dm.x
			v["cy"] = v0["cy"] + dm.y
			transform_changed.emit()
		elif mode != Mode.PHOTO or texture == null:
			if delta.length() > 12.0 or mode == Mode.VIEW:
				pan = _gesture_start["pan"] + delta
	elif keys.size() >= 2 and st.has(keys[0]) and st.has(keys[1]):
		var a0: Vector2 = st[keys[0]]
		var b0: Vector2 = st[keys[1]]
		var a1: Vector2 = _touches[keys[0]]
		var b1: Vector2 = _touches[keys[1]]
		var k := (b1 - a1).length() / maxf((b0 - a0).length(), 1.0)
		var m0 := (a0 + b0) * 0.5
		var m1 := (a1 + b1) * 0.5
		if mode == Mode.PHOTO and texture:
			var turn := (b1 - a1).angle() - (b0 - a0).angle()
			var v0: Dictionary = _gesture_start["view"]
			var v: Dictionary = project.views[view]
			# scale/rotate about the gesture midpoint, then follow its movement
			var pivot := _screen_to_frame_with(m0, _gesture_start["zoom"], _gesture_start["pan"])
			var c0 := Vector2(v0["cx"], v0["cy"])
			var c := pivot + (c0 - pivot).rotated(-turn) * k
			var moved := Vector2(m1.x - m0.x, -(m1.y - m0.y)) / ppm()
			v["mpp"] = float(v0["mpp"]) * k
			v["rot"] = float(v0["rot"]) - turn
			v["cx"] = c.x + moved.x
			v["cy"] = c.y + moved.y
			transform_changed.emit()
		else:
			zoom = clampf(float(_gesture_start["zoom"]) * k, 0.3, 12.0)
			pan = _gesture_start["pan"] + (m1 - m0)
	queue_redraw()

func _screen_to_frame_with(s: Vector2, z: float, p: Vector2) -> Vector2:
	var zs := zoom
	var ps := pan
	zoom = z
	pan = p
	var out := screen_to_frame(s)
	zoom = zs
	pan = ps
	return out

func _zoom_about(s: Vector2, k: float) -> void:
	var before := screen_to_frame(s)
	zoom = clampf(zoom * k, 0.3, 12.0)
	var after := frame_to_screen(before)
	pan += s - after
	queue_redraw()

func _scale_photo_about(s: Vector2, k: float) -> void:
	var v: Dictionary = project.views[view]
	var pivot := screen_to_frame(s)
	var c := pivot + (Vector2(v["cx"], v["cy"]) - pivot) * k
	v["cx"] = c.x
	v["cy"] = c.y
	v["mpp"] = float(v["mpp"]) * k
	transform_changed.emit()
	queue_redraw()

func nudge_move(dx_px: float, dy_px: float) -> void:
	var v: Dictionary = project.views[view]
	v["cx"] = float(v["cx"]) + dx_px / ppm()
	v["cy"] = float(v["cy"]) - dy_px / ppm()
	transform_changed.emit()
	queue_redraw()

func nudge_scale(k: float) -> void:
	_scale_photo_about(frame_to_screen(project.frame_rect(view).get_center()), k)

## Stretch the photo along its width (kx) / height (ky) about the frame's middle.
func nudge_stretch(kx: float, ky: float) -> void:
	project.stretch_about(view, project.frame_rect(view).get_center(), kx, ky)
	transform_changed.emit()
	queue_redraw()

func nudge_rotate(deg: float) -> void:
	var v: Dictionary = project.views[view]
	var pivot := project.frame_rect(view).get_center()
	var c := pivot + (Vector2(v["cx"], v["cy"]) - pivot).rotated(deg_to_rad(deg))
	v["cx"] = c.x
	v["cy"] = c.y
	v["rot"] = float(v["rot"]) + deg_to_rad(deg)
	transform_changed.emit()
	queue_redraw()

func _align_tap(s: Vector2) -> void:
	if texture == null:
		return
	var px := project.frame_to_image(view, screen_to_frame(s), img_size)
	_align_pts.append(px)
	if _align_pts.size() >= 2:
		var ok := project.align_two_points(view, _align_pts[0], _align_pts[1], img_size)
		mode = Mode.PHOTO
		if ok:
			reset_view()
			transform_changed.emit()
		align_progress.emit(2 if ok else -1)
		_align_pts.clear()
	else:
		align_progress.emit(1)
	queue_redraw()
