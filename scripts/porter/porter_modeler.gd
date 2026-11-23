class_name PorterModeler
extends VBoxContainer
## Car Porter step 2: model the body over the reference photos.

signal back_to_photos

const TRI_BUDGET := 1500              # GT1-style body budget (full, mirrored)

var project: PorterProject
var mesh: HalfMesh
var view: ModelView
var tabs := {}
var pick_btns := {}
var lock_btns := {}
var info: Label
var hint: Label
var multi_btn: Button
var step_m := 0.01
var _save_t := 0.0
var _picker: Control
var mode_btns := {}
var shape_panel: Control
var paint_panel: Control
var region_btns := {}
var region := "paint"
var photo_src := ""                   # "" = auto, or side/front/rear/top
var src_btns := {}
var src_row: Control
var fill := false
var xray_btn: Button
var add_btn: Button
var _multi_before := false
var wheel_panel: Control
var wheel_view: WheelCropView
var wheel_rear := false
var wheel_axle_btns := {}
var rear_same_btn: Button
var arch_btn: Button
var arch_row: Control
var window_btn: Button
var window_row: Control
var driver_btn: Button

func setup(p: PorterProject) -> void:
	project = p
	mesh = project.load_mesh()
	add_theme_constant_override("separation", 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build()
	view.paint_colors = _paint_colors()
	if mesh == null:
		mesh = HalfMesh.from_template("suv", project.dims)
		view.setup(project, mesh)
		_show_template_picker(true)
	else:
		view.setup(project, mesh)
	_select_view("side")
	_refresh_info()

func _process(delta: float) -> void:
	if _save_t > 0.0:
		_save_t -= delta
		if _save_t <= 0.0:
			project.save_mesh(mesh)

func save_now() -> void:
	if mesh:
		project.save_mesh(mesh)

# ---------------------------------------------------------------- layout

func _build() -> void:
	var bar := PanelContainer.new()
	add_child(bar)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	bar.add_child(hb)
	hb.add_child(PorterUI.button("◀ Photos", func():
		save_now()
		back_to_photos.emit()))
	var title := UIKit.label(project.name, 28, Color.WHITE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.clip_text = true
	hb.add_child(title)
	mode_btns["shape"] = PorterUI.toggle("Shape", true, func(on): _set_mode("shape", on))
	mode_btns["paint"] = PorterUI.toggle("Paint", false, func(on): _set_mode("paint", on))
	mode_btns["wheels"] = PorterUI.toggle("Wheels", false, func(on): _set_mode("wheels", on))
	hb.add_child(mode_btns["shape"])
	hb.add_child(mode_btns["paint"])
	hb.add_child(mode_btns["wheels"])
	hb.add_child(VSeparator.new())
	for v in [["side", "Side"], ["front", "Front"], ["rear", "Rear"], ["top", "Top"], ["3d", "3D"]]:
		var key: String = v[0]
		var b := PorterUI.button(v[1], func(): _select_view(key), 112)
		tabs[key] = b
		hb.add_child(b)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	add_child(body)
	var stage := Control.new()
	stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage.clip_contents = true
	body.add_child(stage)
	view = ModelView.new()
	view.set_anchors_preset(Control.PRESET_FULL_RECT)
	stage.add_child(view)
	view.selection_changed.connect(_refresh_info)
	view.mesh_edited.connect(func(final):
		if final:
			_queue_save()
		_refresh_info())
	view.edge_tapped.connect(_on_edge_tapped)
	view.face_tapped.connect(_on_face_painted)
	view.add_point_tap.connect(_on_add_point_tap)
	hint = UIKit.label("", 24, UIKit.WARN)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.set_anchors_preset(Control.PRESET_TOP_WIDE)
	hint.offset_left = 20; hint.offset_right = -20; hint.offset_top = 12
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(hint)
	shape_panel = _build_panel()
	paint_panel = _build_paint_panel()
	paint_panel.visible = false
	wheel_panel = _build_wheel_panel()
	wheel_panel.visible = false
	body.add_child(shape_panel)
	body.add_child(paint_panel)
	body.add_child(wheel_panel)

func _build_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(540, 0)
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(sc)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_theme_constant_override("margin_right", 22)
	sc.add_child(pad)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 10)
	pad.add_child(v)

	info = UIKit.label("", 22, UIKit.DIM)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(info)

	v.add_child(UIKit.label("SELECT", 24, UIKit.ACCENT))
	var r1 := HBoxContainer.new()
	pick_btns["points"] = _grow(PorterUI.toggle("Points", true, func(on): _set_pick(ModelView.Pick.POINTS, on)))
	pick_btns["faces"] = _grow(PorterUI.toggle("Faces", false, func(on): _set_pick(ModelView.Pick.FACES, on)))
	r1.add_child(pick_btns["points"]); r1.add_child(pick_btns["faces"])
	v.add_child(r1)
	var r2 := HBoxContainer.new()
	multi_btn = _grow(PorterUI.toggle("Add to selection", false, func(on): view.multi = on))
	r2.add_child(multi_btn)
	r2.add_child(PorterUI.button("All", func(): view.select_all(), 90))
	r2.add_child(PorterUI.button("None", func(): view.clear_selection(), 100))
	v.add_child(r2)

	v.add_child(UIKit.label("EDIT", 24, UIKit.ACCENT))
	var r3 := HBoxContainer.new()
	r3.add_child(_grow(PorterUI.button("Extrude", _extrude)))
	r3.add_child(_grow(PorterUI.button("Loop cut", _start_loop_cut)))
	r3.add_child(_grow(PorterUI.button("Delete", _delete)))
	v.add_child(r3)
	var r3b := HBoxContainer.new()
	add_btn = _grow(PorterUI.toggle("Add point", false, func(on): _toggle_add_point(on)))
	r3b.add_child(add_btn)
	r3b.add_child(_grow(PorterUI.button("Connect", _connect)))
	r3b.add_child(_grow(PorterUI.button("Merge", _merge)))
	v.add_child(r3b)
	v.add_child(UIKit.label("WHEEL ARCHES", 24, UIKit.ACCENT))
	var ra := HBoxContainer.new()
	arch_btn = _grow(PorterUI.toggle("Draw an arch", false, func(on): _toggle_draw_arch(on)))
	ra.add_child(arch_btn)
	ra.add_child(_grow(PorterUI.button("Auto arches (both wheels)", _cut_arches)))
	v.add_child(ra)
	arch_row = HBoxContainer.new()
	arch_row.add_child(_grow(PorterUI.button("Finish arch", _finish_arch)))
	arch_row.add_child(_grow(PorterUI.button("Undo point", func():
		if not view.arch_pts.is_empty():
			view.arch_pts.pop_back()
			view.overlay.queue_redraw())))
	arch_row.add_child(_grow(PorterUI.button("Cancel", func(): _toggle_draw_arch(false))))
	arch_row.visible = false
	v.add_child(arch_row)
	var r4 := HBoxContainer.new()
	r4.add_child(_grow(PorterUI.button("↶ Undo", func():
		if mesh.undo(): _after_structural()
		else: _say("Nothing to undo."))))
	r4.add_child(_grow(PorterUI.button("↷ Redo", func():
		if mesh.redo(): _after_structural()
		else: _say("Nothing to redo."))))
	v.add_child(r4)

	v.add_child(UIKit.label("MOVE", 24, UIKit.ACCENT))
	var r5 := HBoxContainer.new()
	for spec in [[0, "Free"], [1, "↔ only"], [2, "↕ only"]]:
		var axis: int = spec[0]
		var b := _grow(PorterUI.toggle(spec[1], axis == 0, func(on): _set_lock(axis, on)))
		lock_btns[axis] = b
		r5.add_child(b)
	v.add_child(r5)
	var g := GridContainer.new()
	g.columns = 5
	for spec in [["◀", Vector2(-1, 0)], ["▶", Vector2(1, 0)], ["▲", Vector2(0, -1)], ["▼", Vector2(0, 1)]]:
		var dir: Vector2 = spec[1]
		g.add_child(_grow(PorterUI.button(spec[0], func(): view.nudge(dir, step_m), 84)))
	var step_btn := PorterUI.button("1 cm", func(): pass, 110)
	step_btn.pressed.connect(func():
		step_m = 0.001 if step_m > 0.005 else 0.01
		step_btn.text = "1 mm" if step_m < 0.005 else "1 cm")
	g.add_child(step_btn)
	v.add_child(g)

	v.add_child(UIKit.label("DISPLAY", 24, UIKit.ACCENT))
	var r6 := HBoxContainer.new()
	xray_btn = _grow(PorterUI.toggle("See-through", true, func(on): view.set_xray(on)))
	r6.add_child(xray_btn)
	r6.add_child(_grow(PorterUI.button("Reset view", func(): _select_view(view.view))))
	v.add_child(r6)
	v.add_child(HSeparator.new())
	v.add_child(_grow(PorterUI.button("Start over from a template…", func(): _show_template_picker(false))))
	var tip := UIKit.label("Tips: tap a point or face to select it, drag it to move. Drag empty space to pan (orbit in 3D), pinch to zoom. Tap the same spot again to reach a point hidden behind another. Green points sit on the centerline and stay there. You edit the left side; the right side mirrors it.", 20, UIKit.DIM)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(tip)
	return panel

func _grow(c: Control) -> Control:
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c

# ---------------------------------------------------------------- state

func _select_view(v: String) -> void:
	if v != "side":
		_end_draw_arch()
	if v != "3d" and driver_btn and driver_btn.button_pressed:
		driver_btn.set_pressed_no_signal(false)
		view.driver_view = false
	view.set_view(v)
	for k in tabs:
		tabs[k].add_theme_color_override("font_color", Color.WHITE if k == v else UIKit.DIM)
	if v != "3d" and project.views[v]["file"] == "":
		_say("No %s photo. Add one in Photos to model over it." % v)
	else:
		_say("")

func _set_pick(p: int, on: bool) -> void:
	if not on and view.pick == p:
		pick_btns["points" if p == ModelView.Pick.POINTS else "faces"].set_pressed_no_signal(true)
		return
	if not on:
		return
	# carry the selection across: faces -> their points, points -> faces fully inside
	if p == ModelView.Pick.POINTS and view.pick == ModelView.Pick.FACES:
		view.sel_verts.clear()
		for i in mesh.verts_of_faces(view.sel_faces.keys()):
			view.sel_verts[i] = true
	elif p == ModelView.Pick.FACES and view.pick == ModelView.Pick.POINTS:
		view.sel_faces.clear()
		for fi in mesh.faces_of_verts(view.sel_verts.keys()):
			view.sel_faces[fi] = true
	view.pick = p
	pick_btns["points"].set_pressed_no_signal(p == ModelView.Pick.POINTS)
	pick_btns["faces"].set_pressed_no_signal(p == ModelView.Pick.FACES)
	view.overlay.queue_redraw()
	_refresh_info()

func _set_lock(axis: int, on: bool) -> void:
	if on:
		view.lock_axis = axis
	for k in lock_btns:
		lock_btns[k].set_pressed_no_signal(k == view.lock_axis)

func _refresh_info() -> void:
	var tris := mesh.triangle_count()
	var sel := view.sel_faces.size() if view.pick == ModelView.Pick.FACES else view.sel_verts.size()
	var what := "faces" if view.pick == ModelView.Pick.FACES else "points"
	info.text = "Triangles: %d / %d budget   ·   %d %s selected" % [tris, TRI_BUDGET, sel, what]
	info.add_theme_color_override("font_color", UIKit.BAD if tris > TRI_BUDGET else (UIKit.WARN if tris > TRI_BUDGET * 0.85 else UIKit.DIM))

func _say(t: String) -> void:
	hint.text = t

func _queue_save() -> void:
	_save_t = 0.8

func _after_structural() -> void:
	view.sel_verts.clear()
	view.sel_faces.clear()
	view.rebuild_body()
	_queue_save()
	_refresh_info()

# ---------------------------------------------------------------- tools

func _extrude() -> void:
	if view.pick != ModelView.Pick.FACES or view.sel_faces.is_empty():
		_say("Switch to Faces and select the face(s) to extrude, e.g. a wheel arch lip or a bumper.")
		return
	mesh.push_undo()
	var faces: Array = view.sel_faces.keys()
	mesh.extrude_faces(faces, 0.05)
	view.rebuild_body()
	view.selection_changed.emit()
	_queue_save()
	_refresh_info()
	_say("Extruded 5 cm. Drag the selected faces to push them further.")

func _toggle_add_point(on: bool) -> void:
	if on:
		_end_draw_arch()
		_set_pick(ModelView.Pick.POINTS, true)
		view.tool = "add_point"
		_multi_before = view.multi
		view.multi = true
		multi_btn.set_pressed_no_signal(true)
		view.clear_selection()
		_say("Tap an edge to add a point on it, or empty space for a free point. Tap an existing point to include it. New points stay selected, so tap Connect next.")
	else:
		if view.tool == "add_point":
			view.tool = ""
			_restore_multi()
		_say("")
	view.overlay.queue_redraw()

func _restore_multi() -> void:
	view.multi = _multi_before
	multi_btn.set_pressed_no_signal(_multi_before)

func _on_add_point_tap(s: Vector2) -> void:
	# tapping right on an existing point selects it (to connect it with new ones)
	var near := view._candidates_verts(s)
	if not near.is_empty() and near[0][1] < 26.0:
		var vid: int = near[0][0]
		if view.sel_verts.has(vid):
			view.sel_verts.erase(vid)
		else:
			view.sel_verts[vid] = true
		view.selection_changed.emit()
		view.overlay.queue_redraw()
		return
	mesh.push_undo()
	var id := -1
	var hit := view.pick_edge_t(s)
	if not hit.is_empty():
		id = mesh.insert_point_on_edge(hit[0], hit[1], hit[2])
		_say("Point added on the edge. Add more, or tap Connect.")
	else:
		id = mesh.add_point(view.screen_to_world_near(s))
		_say("Free point added at the depth of the nearest part of the model. Select 3 or more points and tap Connect to make a face.")
	view.sel_verts[id] = true
	view.rebuild_body()
	view.selection_changed.emit()
	_queue_save()
	_refresh_info()

func _connect() -> void:
	var ids: Array = view.selected_vert_ids() if view.pick == ModelView.Pick.POINTS else []
	if view.pick != ModelView.Pick.POINTS:
		_say("Switch to Points and select the points to connect.")
		return
	mesh.push_undo()
	var msg := mesh.connect_points(ids, view.cam.global_position)
	if msg != "":
		mesh.undo()
		_say(msg)
		return
	_end_add_point()
	_after_structural()
	_say("Connected. A new face starts as body paint; repaint it in Paint." if ids.size() > 2 else "Connected: the face is split by a new edge.")

func _merge() -> void:
	if view.pick != ModelView.Pick.POINTS or view.sel_verts.size() < 2:
		_say("Switch to Points and select 2 or more points to weld together.")
		return
	mesh.push_undo()
	mesh.merge_points(view.sel_verts.keys())
	_end_add_point()
	_after_structural()
	_say("Points welded into one.")

func _end_draw_arch() -> void:
	if arch_btn and arch_btn.button_pressed:
		_toggle_draw_arch(false)

func _end_add_point() -> void:
	if view.tool == "add_point":
		view.tool = ""
		_restore_multi()
	add_btn.set_pressed_no_signal(false)

func _start_loop_cut() -> void:
	_end_add_point()
	_end_draw_arch()
	view.tool = "loop_cut"
	view.overlay.queue_redraw()
	_say("Tap an edge: a new ring of points is added across it, all the way around.")

func _on_edge_tapped(a: int, b: int) -> void:
	mesh.push_undo()
	var added := mesh.loop_cut(a, b)
	view.tool = ""
	if added.is_empty():
		mesh.undo()
		_say("Couldn't cut there. Loop cuts run through four-sided faces.")
	else:
		view.sel_verts.clear()
		view.sel_faces.clear()
		if view.pick == ModelView.Pick.POINTS:
			for i in added:
				view.sel_verts[i] = true
		view.rebuild_body()
		_queue_save()
		_say("Added %d points. They're selected: drag to shape them." % added.size())
	view.selection_changed.emit()
	_refresh_info()

func _delete() -> void:
	if view.pick != ModelView.Pick.FACES or view.sel_faces.is_empty():
		_say("Switch to Faces and select the faces to delete.")
		return
	mesh.push_undo()
	mesh.delete_faces(view.sel_faces.keys())
	_after_structural()

# ---------------------------------------------------------------- templates

func _show_template_picker(first: bool) -> void:
	if _picker:
		_picker.queue_free()
	var pc := PanelContainer.new()
	pc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.035, 0.065, 0.96)
	sb.content_margin_left = 60; sb.content_margin_right = 60; sb.content_margin_top = 40
	pc.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 16)
	pc.add_child(v)
	v.add_child(UIKit.label("CHOOSE A STARTING SHAPE", 36, Color.WHITE))
	v.add_child(UIKit.label("It's scaled to this car's real length, width, height, wheelbase and overhang. You'll shape it to the photos from here.", 24, UIKit.DIM))
	var g := GridContainer.new()
	g.columns = 3
	g.add_theme_constant_override("h_separation", 16)
	g.add_theme_constant_override("v_separation", 16)
	for key in HalfMesh.TEMPLATES:
		var k: String = key
		var b := PorterUI.button(HalfMesh.TEMPLATES[k]["label"], func():
			if not first:
				mesh.push_undo()
			var fresh := HalfMesh.from_template(k, project.dims)
			mesh.restore(fresh.snapshot())
			mesh.template = k
			_after_structural()
			pc.queue_free()
			_picker = null
			_say("Started from %s. Pick a view and drag points onto the photo's outline." % HalfMesh.TEMPLATES[k]["label"]), 380)
		b.custom_minimum_size.y = 110
		g.add_child(b)
	v.add_child(g)
	if not first:
		v.add_child(PorterUI.button("Cancel (keep my model)", func():
			pc.queue_free()
			_picker = null, 420))
	else:
		v.add_child(UIKit.label("Tip: you can always come back to this with “Start over from a template…”.", 22, UIKit.DIM))
	_picker = pc
	add_child(pc)
	# overlay the whole modeler (not part of the VBox flow)
	pc.top_level = true
	pc.position = global_position
	pc.size = size
	resized.connect(func():
		if is_instance_valid(pc):
			pc.position = global_position
			pc.size = size)

# ---------------------------------------------------------------- paint mode

func _set_mode(m: String, on: bool) -> void:
	if not on:
		mode_btns[m].set_pressed_no_signal(true)    # keep one lit
		return
	_end_add_point()
	_end_draw_arch()
	if window_btn and window_btn.button_pressed:
		_toggle_cut_window(false)
	for k in mode_btns:
		mode_btns[k].set_pressed_no_signal(k == m)
	shape_panel.visible = m == "shape"
	paint_panel.visible = m == "paint"
	wheel_panel.visible = m == "wheels"
	var painting := m != "shape"
	view.tool = {"paint": "paint", "wheels": "wheels"}.get(m, "")
	view.show_paint = painting
	view.clear_selection()
	view.set_xray(m == "shape" and xray_btn.button_pressed)
	view.rebuild_body()
	if m == "wheels":
		_select_view("3d")
		_pick_wheel_axle(false)
		_say("The wheel picture is cut from your side photo around each wheel. Drag the photo to center it, pinch to size the orange circle to the tire's edge.")
	else:
		_say("Pick a part on the right, then tap faces to paint them." if painting else "")

func _paint_colors() -> Dictionary:
	var c := {}
	var pc: Array = project.paint.get("color", [0.2, 0.25, 0.45])
	c["paint"] = Color(pc[0], pc[1], pc[2])
	var lc: Array = project.paint.get("lower", pc)
	c["second"] = Color(lc[0], lc[1], lc[2])
	return c

func _build_paint_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(540, 0)
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(sc)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_theme_constant_override("margin_right", 22)
	sc.add_child(pad)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 10)
	pad.add_child(v)
	v.add_child(UIKit.label("PART TO PAINT", 24, UIKit.ACCENT))
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 8)
	g.add_theme_constant_override("v_separation", 8)
	for key in HalfMesh.REGIONS:
		var k: String = key
		var b := PorterUI.toggle("      " + HalfMesh.REGIONS[k]["label"], k == region, func(on): _pick_region(k, on))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var sw := ColorRect.new()
		sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sw.custom_minimum_size = Vector2(30, 30)
		sw.position = Vector2(14, 21)
		sw.size = Vector2(30, 30)
		sw.color = _paint_colors().get(k, HalfMesh.REGIONS[k]["color"])
		b.add_child(sw)
		region_btns[k] = [b, sw]
		g.add_child(b)
	v.add_child(g)
	src_row = VBoxContainer.new()
	src_row.add_child(UIKit.label("Photo to use:", 22, UIKit.DIM))
	var sr := HBoxContainer.new()
	for spec in [["", "Auto"], ["side", "Side"], ["front", "Front"], ["rear", "Rear"], ["top", "Top"]]:
		var key2: String = spec[0]
		var sb := _grow(PorterUI.toggle(spec[1], key2 == photo_src, func(on): _pick_src(key2, on)))
		sb.custom_minimum_size.x = 0
		src_btns[key2] = sb
		sr.add_child(sb)
	src_row.add_child(sr)
	src_row.visible = false
	v.add_child(src_row)
	v.add_child(_grow(PorterUI.toggle("Fill: paint the whole connected area", false, func(on): fill = on)))
	var r4 := HBoxContainer.new()
	r4.add_child(_grow(PorterUI.button("↶ Undo", func():
		if mesh.undo(): _after_structural()
		else: _say("Nothing to undo."))))
	r4.add_child(_grow(PorterUI.button("↷ Redo", func():
		if mesh.redo(): _after_structural()
		else: _say("Nothing to redo."))))
	v.add_child(r4)

	v.add_child(HSeparator.new())
	v.add_child(UIKit.label("WINDOWS + INTERIOR", 24, UIKit.ACCENT))
	window_btn = _grow(PorterUI.toggle("Cut a window", false, func(on): _toggle_cut_window(on)))
	v.add_child(window_btn)
	window_row = HBoxContainer.new()
	window_row.add_child(_grow(PorterUI.button("Finish window", _finish_window)))
	window_row.add_child(_grow(PorterUI.button("Undo point", func():
		if not view.window_pts.is_empty():
			view.window_pts.pop_back()
			view.overlay.queue_redraw())))
	window_row.add_child(_grow(PorterUI.button("Cancel", func(): _toggle_cut_window(false))))
	window_row.visible = false
	v.add_child(window_row)
	var ri := HBoxContainer.new()
	ri.add_child(_grow(PorterUI.toggle("Show interior", true, func(on):
		view.show_interior = on
		view.rebuild_body())))
	driver_btn = _grow(PorterUI.toggle("Driver's seat view", false, func(on): _driver_view(on)))
	ri.add_child(driver_btn)
	v.add_child(ri)
	var wtip := UIKit.label("Cut windows: the panels under your outline are split along it and the piece inside becomes glass (see-through). Delete a glass face in Shape for an open window. The body is a hollow shell with a dark interior, ready for the first-person view.", 20, UIKit.DIM)
	wtip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(wtip)
	v.add_child(HSeparator.new())
	v.add_child(UIKit.label("PHOTO TEXTURES", 24, UIKit.ACCENT))
	v.add_child(_grow(PorterUI.button("Photos on all body paint", func(): _photos_on(["paint", "second"]))))
	v.add_child(_grow(PorterUI.button("Photos on everything (then cut windows)", func(): _photos_on(["paint", "second", "glass", "headlight", "taillight", "chrome", "trim", "grille"]))))
	var ptip := UIKit.label("Each face takes the photo that looks straight at it, lined up from your Photos step. Match the shape to the photos first for the cleanest result. Photo faces keep the photo's color, so the paint shop won't recolor them.", 20, UIKit.DIM)
	ptip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(ptip)
	v.add_child(HSeparator.new())
	v.add_child(UIKit.label("PREVIEW COLOR", 24, UIKit.ACCENT))
	var paints := _factory_paints()
	var pg := GridContainer.new()
	pg.columns = 1
	for pdef in paints:
		var pd: Dictionary = pdef
		var c: Array = pd["color"]
		var b2 := PorterUI.button("      " + pd["name"], func(): _set_preview_paint(pd))
		b2.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b2.clip_text = true
		b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b2.custom_minimum_size = Vector2(0, 64)
		var sw2 := ColorRect.new()
		sw2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sw2.position = Vector2(14, 17)
		sw2.size = Vector2(30, 30)
		sw2.color = Color(c[0], c[1], c[2])
		b2.add_child(sw2)
		pg.add_child(b2)
	v.add_child(pg)
	var tip := UIKit.label("Tips: tap a face to paint it with the chosen part. Need a window frame, headlight or stripe where there's no face? Go back to Shape and use Loop cut to add one. Glass, lights and chrome get their own look in the game; body paint and the second color follow the paint shop.", 20, UIKit.DIM)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(tip)
	return panel

## Factory colors of the car the dimensions came from, or a neutral set.
func _factory_paints() -> Array:
	if project.source_car != "" and Game.cars.has(project.source_car):
		return Game.cars[project.source_car].get("paints", [])
	return [
		{"name": "White", "color": [0.9, 0.9, 0.88]}, {"name": "Black", "color": [0.03, 0.03, 0.035]},
		{"name": "Red", "color": [0.6, 0.05, 0.05]}, {"name": "Silver", "color": [0.6, 0.61, 0.62]},
		{"name": "Blue", "color": [0.12, 0.2, 0.45]}, {"name": "Green", "color": [0.08, 0.25, 0.14]},
	]

func _set_preview_paint(pd: Dictionary) -> void:
	project.paint = {"color": pd["color"], "lower": pd.get("lower", pd["color"])}
	project.save()
	view.paint_colors = _paint_colors()
	for k in ["paint", "second"]:
		region_btns[k][1].color = view.paint_colors[k]
	view.rebuild_body()

func _pick_region(k: String, on: bool) -> void:
	if not on and k == region:
		region_btns[k][0].set_pressed_no_signal(true)
		return
	region = k
	for key in region_btns:
		region_btns[key][0].set_pressed_no_signal(key == k)
	src_row.visible = k == "photo"
	if k == "photo" and project.photo_count() == 0:
		_say("Add photos in the Photos step first.")

func _pick_src(k: String, on: bool) -> void:
	if not on and k == photo_src:
		src_btns[k].set_pressed_no_signal(true)
		return
	photo_src = k
	for key in src_btns:
		src_btns[key].set_pressed_no_signal(key == k)

## Region value to paint with (photo carries its source).
func _paint_value() -> String:
	if region == "photo" and photo_src != "":
		return "photo:" + photo_src
	return region

func _photos_on(parts: Array) -> void:
	if project.photo_count() == 0:
		_say("Add photos in the Photos step first.")
		return
	var ids := []
	for fi in mesh.faces.size():
		if HalfMesh.region_base(mesh.region_of(fi)) in parts:
			ids.append(fi)
	if ids.is_empty():
		return
	mesh.push_undo()
	mesh.set_region(ids, "photo")
	view.rebuild_body()
	_queue_save()
	_say("Photos applied to %d faces. Tap faces with another part to change them, or Undo." % ids.size())

func _on_face_painted(fi: int) -> void:
	var targets: Array = mesh.connected_same_region(fi) if fill else [fi]
	var val := _paint_value()
	if mesh.region_of(fi) == val and targets.size() == 1:
		return
	mesh.push_undo()
	mesh.set_region(targets, val)
	view.rebuild_body()
	_queue_save()

# ---------------------------------------------------------------- wheel arches

func _toggle_draw_arch(on: bool) -> void:
	view.arch_pts.clear()
	arch_btn.set_pressed_no_signal(on)
	arch_row.visible = on
	if on:
		_end_add_point()
		_select_view("side")
		view.tool = "draw_arch"
		view.clear_selection()
		_say("Tap along the wheel well in the photo, from one end of the arch to the other. The two ends drop onto the bottom of the body. Pinch to zoom in for accuracy.")
	else:
		if view.tool == "draw_arch":
			view.tool = ""
		_say("")
	view.overlay.queue_redraw()

func _finish_arch() -> void:
	mesh.push_undo()
	var msg := mesh.cut_arch_profile(view.arch_pts)
	if msg != "":
		mesh.undo()
		_say(msg)
		return
	_toggle_draw_arch(false)
	_after_structural()
	_say("Arch cut. Draw the other one, or Undo to try again.")

func _cut_arches() -> void:
	var d := project.dims
	mesh.push_undo()
	var msgs := []
	for rear in [false, true]:
		var axle_z: float = (d["wheelbase_m"] * 0.5) * (1.0 if rear else -1.0)
		var r := project.tire_radius(rear)
		var msg := mesh.cut_wheel_arch(axle_z, r, r * 1.12 + 0.02, 8)
		if msg != "":
			msgs.append(("Rear: " if rear else "Front: ") + msg)
	if msgs.size() == 2:
		mesh.undo()
		_say(" ".join(msgs))
		return
	_after_structural()
	_say("Wheel arches cut around both axles, sized from the tires." if msgs.is_empty() else "Cut one arch. " + " ".join(msgs))

# ---------------------------------------------------------------- wheels

func _build_wheel_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(620, 0)
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(sc)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_theme_constant_override("margin_right", 22)
	sc.add_child(pad)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 10)
	pad.add_child(v)
	v.add_child(UIKit.label("WHEEL PICTURE", 24, UIKit.ACCENT))
	var tabs_row := HBoxContainer.new()
	wheel_axle_btns["front"] = _grow(PorterUI.toggle("Front wheel", true, func(on): _axle_toggled(false, on)))
	wheel_axle_btns["rear"] = _grow(PorterUI.toggle("Rear wheel", false, func(on): _axle_toggled(true, on)))
	tabs_row.add_child(wheel_axle_btns["front"])
	tabs_row.add_child(wheel_axle_btns["rear"])
	v.add_child(tabs_row)
	rear_same_btn = _grow(PorterUI.toggle("Rear uses the front wheel picture", project.wheels.get("rear_same", true), func(on):
		project.wheels["rear_same"] = on
		project.save()
		_pick_wheel_axle(wheel_rear)
		_apply_wheel()))
	v.add_child(rear_same_btn)
	wheel_view = WheelCropView.new()
	wheel_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wheel_view.crop_changed.connect(func(final):
		if final:
			_store_crop()
			_apply_wheel())
	v.add_child(wheel_view)
	var g := GridContainer.new()
	g.columns = 6
	for spec in [["◀", func(): wheel_view.nudge_move(-1, 0)], ["▶", func(): wheel_view.nudge_move(1, 0)],
			["▲", func(): wheel_view.nudge_move(0, -1)], ["▼", func(): wheel_view.nudge_move(0, 1)],
			["−", func(): wheel_view.nudge_size(1.0 / 1.01)], ["+", func(): wheel_view.nudge_size(1.01)]]:
		g.add_child(_grow(PorterUI.button(spec[0], spec[1], 80)))
	v.add_child(g)
	v.add_child(_grow(PorterUI.button("Reset to the aligned wheel position", func():
		var key := "rear" if wheel_rear and not project.wheels.get("rear_same", true) else "front"
		project.wheels[key] = {}
		project.save()
		_pick_wheel_axle(wheel_rear)
		_apply_wheel())))
	var tip := UIKit.label("The wheel model is built from the tire size: a 16-sided drum with this picture on both faces and rubber on the tread. It's kept separate from the body so the game can spin and steer it. Tip: cut wheel arches in Shape so the wheels show.", 20, UIKit.DIM)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(tip)
	return panel

func _axle_toggled(rear: bool, on: bool) -> void:
	if not on:
		wheel_axle_btns["rear" if rear else "front"].set_pressed_no_signal(true)
		return
	_pick_wheel_axle(rear)

func _pick_wheel_axle(rear: bool) -> void:
	if rear and project.wheels.get("rear_same", true):
		rear = false
		_say("The rear uses the front wheel picture. Turn that off to cut a separate rear wheel.")
	wheel_rear = rear
	wheel_axle_btns["front"].set_pressed_no_signal(not rear)
	wheel_axle_btns["rear"].set_pressed_no_signal(rear)
	wheel_view.setup(project, rear, project.load_photo("side"))
	if project.load_wheel_texture(false) == null:
		_apply_wheel()

func _store_crop() -> void:
	var key := "rear" if wheel_rear else "front"
	project.wheels[key] = wheel_view.crop.duplicate()
	project.save()

## Re-cut the wheel pictures and refresh the wheels on the car.
func _apply_wheel() -> void:
	if project.load_photo("side") == null:
		return
	project.make_wheel_texture(false)
	project.make_wheel_texture(true)
	view.refresh_wheels()

# ---------------------------------------------------------------- windows

func _toggle_cut_window(on: bool) -> void:
	view.window_pts.clear()
	window_btn.set_pressed_no_signal(on)
	window_row.visible = on
	if on:
		_driver_view(false)
		view.tool = "draw_window"
		if view.view == "3d":
			_select_view("side")
		_say("Pick the view that shows the window straight on (Side, Front for the windshield, Rear for the back glass, Top for a sunroof) and tap around its outline on the photo.")
	else:
		if view.tool == "draw_window":
			view.tool = "paint"
		_say("")
	view.overlay.queue_redraw()

func _finish_window() -> void:
	if view.view == "3d":
		_say("Switch to Side, Front, Rear or Top to draw the outline.")
		return
	mesh.push_undo()
	var msg := mesh.cut_window(view.view, PackedVector2Array(view.window_pts))
	if msg != "":
		mesh.undo()
		_say(msg)
		return
	view.window_pts.clear()
	view.rebuild_body()
	_queue_save()
	_refresh_info()
	_say("Window cut. Draw the next one, or check it from the Driver's seat view. Undo takes it back.")
	view.overlay.queue_redraw()

func _driver_view(on: bool) -> void:
	driver_btn.set_pressed_no_signal(on)
	view.driver_view = on
	if on:
		if window_btn.button_pressed:
			_toggle_cut_window(false)
		view.yaw = deg_to_rad(-140.0)
		view.pitch = 0.0
		_select_view("3d")
		_say("Driver's seat: drag to look around. This is roughly what the first-person view will see.")
	else:
		view._update_cam()
	view.overlay.queue_redraw()
