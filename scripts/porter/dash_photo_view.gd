class_name DashPhotoView
extends Control
## An interior photo with the outline of the part it goes on drawn over it:
## the dash (dash photo, with gauges) or, for the door / pillar / ceiling
## photos, the body panels painted with that photo on the inside. Drag to
## slide the outline over the photo, pinch / mouse wheel to size it. In gauge
## mode (dash only) a tap places the chosen gauge or picks an existing one.

signal fit_changed(final: bool)
signal gauge_tapped(frame_pt: Vector2, index: int)   # index = existing gauge hit, or -1

var project: PorterProject
var dash: HalfMesh
var body: HalfMesh                   # for the door / pillar / ceiling outlines
var view_name := "dash"
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

func setup(p: PorterProject, d: HalfMesh, view: String = "dash", body_mesh: HalfMesh = null) -> void:
	project = p
	dash = d
	view_name = view
	body = body_mesh
	var img := project.load_photo(view_name)
	texture = ImageTexture.create_from_image(img) if img else null
	if img:
		img_size = Vector2(img.get_width(), img.get_height())
	queue_redraw()

## Outline edges (frame coordinates) of what this view's photo goes on.
func outline() -> Array:
	if view_name == "dash":
		return InteriorBuilder.dash_outline(dash)
	return panel_outline(project, body, view_name)

## Edges of the body panels painted with an interior photo on the inside
## (or, if none yet, the panels that photo would suit), in its frame.
static func panel_outline(p: PorterProject, m: HalfMesh, view: String) -> Array:
	var out := []
	if m == null:
		return out
	var ids := []
	for fi in m.faces.size():
		if m.inner_region_of(fi) == "photo:" + view:
			ids.append(fi)
	if ids.is_empty():
		ids = InteriorBuilder.suits_inner_photo(m, view)
	for fi in ids:
		var f: PackedInt32Array = m.faces[fi]
		for k in f.size():
			var a := m.verts[f[k]]
			var b := m.verts[f[(k + 1) % f.size()]]
			out.append([PhotoTexturer.world_to_frame(p, view, a), PhotoTexturer.world_to_frame(p, view, b)])
			if view == "ceiling":
				out.append([PhotoTexturer.world_to_frame(p, view, Vector3(-a.x, a.y, a.z)), PhotoTexturer.world_to_frame(p, view, Vector3(-b.x, b.y, b.z))])
	return out

## Fit the photo so its width spans the dash and it sits on the dash face.
static func fit_to_dash(p: PorterProject, d: HalfMesh, img_w: float) -> void:
	fit_to_outline(p, "dash", InteriorBuilder.dash_outline(d), img_w)

## Fit a photo so its width spans an outline, centered on it.
static func fit_to_outline(p: PorterProject, view: String, edges: Array, img_w: float) -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for e in edges:
		for q in e:
			lo = lo.min(q)
			hi = hi.max(q)
	var v: Dictionary = p.views[view]
	v["flip"] = false
	v["rot"] = 0.0
	if lo.x == INF:
		return
	v["mpp"] = (hi.x - lo.x) / maxf(img_w, 1.0)
	v["cx"] = (lo.x + hi.x) * 0.5
	v["cy"] = (lo.y + hi.y) * 0.5
	if view == "door":
		# a door photo shows the front door, not the whole side: ~1.2 m around the seat
		var e := p.driver_eye()
		v["mpp"] = 1.2 / maxf(img_w, 1.0)
		v["cx"] = -(e.z - 0.3)
		v["cy"] = e.y - 0.35

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
	return _px_to_screen(project.frame_to_image(view_name, f, img_size))

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.05, 0.09))
	var font := get_theme_default_font()
	if texture == null:
		draw_string(font, Vector2(20, size.y * 0.5), "Load the %s photo." % PorterProject.VIEW_LABELS[view_name].to_lower(), HORIZONTAL_ALIGNMENT_LEFT, -1, 24, UIKit.WARN)
		return
	draw_texture_rect(texture, Rect2(_ofs(), img_size * _k()), false)
	for e in outline():
		draw_line(_frame_to_screen(e[0]), _frame_to_screen(e[1]), Color(0.35, 0.78, 1.0, 0.9), 2.0, true)
	var gs: Array = project.interior.get("gauges", []) if view_name == "dash" else []
	for i in gs.size():
		var g: Dictionary = gs[i]
		var c := _frame_to_screen(Vector2(g["x"], g["y"]))
		var r := (_frame_to_screen(Vector2(float(g["x"]) + float(g["r"]), g["y"])) - c).length()
		var col := Color(1.0, 0.65, 0.15) if i == selected else Color(1, 1, 1, 0.9)
		draw_arc(c, r, 0, TAU, 32, col, 3.0, true)
		draw_string(font, c + Vector2(-r, -r - 6), InteriorBuilder.GAUGE_TYPES[g["type"]]["label"], HORIZONTAL_ALIGNMENT_LEFT, -1, 18, col)
		if not g.get("on_dash", true):
			draw_string(font, c + Vector2(-r, r + 18), "off the dash", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, UIKit.WARN)
	var tip := "Tap where the gauge goes (or tap a gauge to pick it)" if placing else ("Drag / pinch the photo so the blue dash outline sits on the dash" if view_name == "dash" else "Drag / pinch so the blue panel outline sits on the %s in the photo" % PorterProject.VIEW_LABELS[view_name].to_lower())
	draw_string(font, Vector2(14, 28), tip, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(1, 1, 1, 0.85))

func _gauge_at(s: Vector2) -> int:
	if view_name != "dash":
		return -1
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
				if placing and not _moved and view_name == "dash":
					var hit := _gauge_at(e.position)
					gauge_tapped.emit(project.image_to_frame("dash", _screen_to_px(e.position), img_size), hit)
				elif _moved:
					fit_changed.emit(true)
		_start = {"t": _touches.duplicate(), "v": project.views[view_name].duplicate()}
		accept_event()
	elif e is InputEventScreenDrag:
		_touches[e.index] = e.position
		var st: Dictionary = _start.get("t", {})
		var keys := _touches.keys()
		var v0: Dictionary = _start["v"]
		var v: Dictionary = project.views[view_name]
		if keys.size() == 1 and st.has(keys[0]):
			var d: Vector2 = (_touches[keys[0]] - st[keys[0]]) / _k()
			if d.length() > 6.0:
				_moved = true
			if placing:
				return
			# outline follows the finger: a frame point now maps d pixels further along
			var c := Vector2(v0["cx"], v0["cy"]) - _px_delta_to_frame(d, v0)
			v["cx"] = c.x
			v["cy"] = c.y
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

## A photo-pixel offset as a frame offset, with the view's scale, rotation, flip.
static func _px_delta_to_frame(d: Vector2, v: Dictionary) -> Vector2:
	var local := Vector2(-d.x if v["flip"] else d.x, -d.y) * float(v["mpp"])
	return local.rotated(float(v["rot"]))

## k > 1 makes the outline bigger on the photo.
func nudge_size(k: float) -> void:
	project.views[view_name]["mpp"] = float(project.views[view_name]["mpp"]) / k
	queue_redraw()
	fit_changed.emit(true)

func nudge_move(dx: float, dy: float) -> void:
	var v: Dictionary = project.views[view_name]
	var c := Vector2(v["cx"], v["cy"]) - _px_delta_to_frame(Vector2(dx, dy) * 3.0 / _k(), v)
	v["cx"] = c.x
	v["cy"] = c.y
	queue_redraw()
	fit_changed.emit(true)

func flip() -> void:
	var v: Dictionary = project.views[view_name]
	v["flip"] = not v["flip"]
	queue_redraw()
	fit_changed.emit(true)

func rotate_90() -> void:
	var v: Dictionary = project.views[view_name]
	v["rot"] = wrapf(float(v["rot"]) + PI * 0.5, -PI, PI)
	queue_redraw()
	fit_changed.emit(true)
