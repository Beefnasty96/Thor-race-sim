class_name PorterModeler
extends VBoxContainer
## Car Porter step 2: model the body over the reference photos.

signal back_to_photos
signal photo_requested(view_name: String)     # porter_main opens the picker, then calls on_photo_loaded

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
# interior
var dash_mesh: HalfMesh
var body_mesh: HalfMesh               # the body while the dash is being edited
var editing_dash := false
var dash_bar: Control                 # "editing the dash" banner in the Shape panel
var interior_panel: Control
var dash_view: DashPhotoView
var steer_view: SteeringCropView
var gauge_btns := {}
var gauge_type := ""
var gauge_sel := -1
var gauge_info: Label
var hole_btn: Button
var hole_row: Control
var seat_btn: Button
var dash_seat_btn: Button             # edit the dash from the driver's seat
var wheel_btns: Array = []            # "Hide steering wheel" toggles (kept in sync)
# inside panels (doors, pillars, ceiling)
var inside_view := "door"
var inside_tabs := {}
var inside_photo_view: DashPhotoView
var inside_load_btn: Button
var inside_paint := ""
var inside_paint_btns := {}
var inside_fill := false
# recolouring photo paint
var pick_paint_btn: Button
var key_swatch: ColorRect
var key_label: Label
var recolor_btn: Button
var match_btn: Button
var mask_editor: PaintMaskEditor
var mask_tabs := {}
var brush_btns := {}
# factory paints
var preview_grid: GridContainer
var paint_source_lbl: Label
var add_paint_btn: Button
var add_paint_row: Control
var add_paint_swatch: ColorRect
var add_paint_name: LineEdit
var add_paint_code: LineEdit
var _picked_custom := Color(-1, 0, 0)
var depth_row: Control                # closer / farther (driver's-seat editing)
var steer_labels := {}

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
	dash_mesh = project.load_dash()
	view.dash = dash_mesh
	_select_view("side")
	_refresh_info()

func _process(delta: float) -> void:
	if _save_t > 0.0:
		_save_t -= delta
		if _save_t <= 0.0:
			_save_mesh()

func _save_mesh() -> void:
	if editing_dash:
		project.save_dash(mesh)
	elif mesh:
		project.save_mesh(mesh)

func save_now() -> void:
	_save_mesh()
	if editing_dash and body_mesh:
		project.save_mesh(body_mesh)

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
	mode_btns["interior"] = PorterUI.toggle("Interior", false, func(on): _set_mode("interior", on))
	hb.add_child(mode_btns["shape"])
	hb.add_child(mode_btns["paint"])
	hb.add_child(mode_btns["wheels"])
	hb.add_child(mode_btns["interior"])
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
	view.paint_pick_tap.connect(_on_paint_pick)
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
	interior_panel = _build_interior_panel()
	interior_panel.visible = false
	body.add_child(shape_panel)
	body.add_child(paint_panel)
	body.add_child(wheel_panel)
	body.add_child(interior_panel)

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

	dash_bar = VBoxContainer.new()
	dash_bar.add_child(UIKit.label("EDITING THE DASHBOARD", 24, UIKit.WARN))
	var db_tip := UIKit.label("All the point tools work on the dash now (it mirrors like the body). In Side / Front / Top the body shows as a faint ghost around it.", 20, UIKit.DIM)
	db_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dash_bar.add_child(db_tip)
	dash_seat_btn = _grow(PorterUI.toggle("Edit from the driver's seat", true, func(on): _driver_view(on)))
	dash_bar.add_child(dash_seat_btn)
	dash_bar.add_child(_wheel_toggle())
	dash_bar.add_child(_grow(PorterUI.button("Done editing the dash ▶ Interior", _end_edit_dash)))
	dash_bar.visible = false
	v.add_child(dash_bar)
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
	ra = HBoxContainer.new()
	ra.add_child(_grow(PorterUI.button("Build wheel wells (for arches already cut)", _wheel_wells_button)))
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
	depth_row = HBoxContainer.new()
	depth_row.add_child(_grow(PorterUI.button("Closer to me", func(): view.nudge_depth(step_m))))
	depth_row.add_child(_grow(PorterUI.button("Farther away", func(): view.nudge_depth(-step_m))))
	depth_row.visible = false
	v.add_child(depth_row)

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
	if v != "3d" and view.driver_view:
		driver_btn.set_pressed_no_signal(false)
		if seat_btn:
			seat_btn.set_pressed_no_signal(false)
		if dash_seat_btn:
			dash_seat_btn.set_pressed_no_signal(false)
		if depth_row:
			depth_row.visible = false
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
	if editing_dash:
		_keep_dash_inside([])
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
	v.add_child(UIKit.label("CHOOSE A STARTING SHAPE" if not editing_dash else "CHOOSE A DASHBOARD SHAPE", 36, Color.WHITE))
	v.add_child(UIKit.label("It's scaled to this car's real length, width, height, wheelbase and overhang. You'll shape it to the photos from here." if not editing_dash else "Sized to the cab and placed in front of the driver's seat.", 24, UIKit.DIM))
	var g := GridContainer.new()
	g.columns = 3
	g.add_theme_constant_override("h_separation", 16)
	g.add_theme_constant_override("v_separation", 16)
	if editing_dash:
		for key in InteriorBuilder.DASH_TEMPLATES:
			var dk: String = key
			var db := PorterUI.button(InteriorBuilder.DASH_TEMPLATES[dk]["label"], func():
				mesh.push_undo()
				mesh.restore(InteriorBuilder.dash_from_template(dk, project, body_mesh).snapshot())
				mesh.template = "dash_" + dk
				_after_structural()
				pc.queue_free()
				_picker = null, 380)
			db.custom_minimum_size.y = 110
			g.add_child(db)
	for key in (HalfMesh.TEMPLATES if not editing_dash else {}):
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
	if editing_dash and m != "shape":
		_end_edit_dash(false)
	shape_panel.visible = m == "shape"
	paint_panel.visible = m == "paint"
	wheel_panel.visible = m == "wheels"
	interior_panel.visible = m == "interior"
	if m != "interior":
		_stop_placing()
		if hole_btn and hole_btn.button_pressed:
			_toggle_hole(false)
	var painting := m != "shape"
	view.tool = {"paint": "paint", "wheels": "wheels", "interior": "interior"}.get(m, "")
	view.show_paint = painting
	view.clear_selection()
	view.set_xray(m == "shape" and xray_btn.button_pressed)
	view.rebuild_body()
	if m == "wheels":
		_select_view("3d")
		_pick_wheel_axle(false)
		_say("The wheel picture is cut from your side photo around each wheel. Drag the photo to center it, pinch to size the orange circle to the tire's edge. Only the rim inside the blue circle is kept: the game builds the tire so it can squash, flex and go flat.")
	elif m == "interior":
		_open_interior()
	else:
		_say("Pick a part on the right, then tap faces to paint them." if painting else "")
	if m != "interior":
		_stop_inside_paint()
	if m != "paint" and pick_paint_btn and pick_paint_btn.button_pressed:
		_toggle_pick_paint(false)
	if m == "paint" and mask_editor:
		var cur := "side"
		for t in mask_tabs:
			if mask_tabs[t].button_pressed:
				cur = t
		_pick_mask_view(cur)
		_refresh_key_ui()

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
	var ptip := UIKit.label("Each face takes the photo that looks straight at it, lined up from your Photos step. Match the shape to the photos first for the cleanest result. Pick the paint color below so the paint shop can recolor photo faces too.", 20, UIKit.DIM)
	ptip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(ptip)
	_build_recolor_section(v)
	v.add_child(HSeparator.new())
	v.add_child(UIKit.label("PREVIEW COLOR", 24, UIKit.ACCENT))
	paint_source_lbl = UIKit.label("", 20, UIKit.DIM)
	paint_source_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(paint_source_lbl)
	preview_grid = GridContainer.new()
	preview_grid.columns = 1
	v.add_child(preview_grid)
	_fill_preview_paints()
	add_paint_btn = _grow(PorterUI.toggle("Add a paint from your photo", false, func(on): _toggle_add_paint(on)))
	v.add_child(add_paint_btn)
	add_paint_row = VBoxContainer.new()
	var ar := HBoxContainer.new()
	add_paint_swatch = ColorRect.new()
	add_paint_swatch.custom_minimum_size = Vector2(56, 56)
	ar.add_child(add_paint_swatch)
	add_paint_name = LineEdit.new()
	add_paint_name.placeholder_text = "Factory name (e.g. Victory Red)"
	add_paint_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_paint_name.custom_minimum_size.y = 56
	ar.add_child(add_paint_name)
	add_paint_row.add_child(ar)
	var ar2 := HBoxContainer.new()
	add_paint_code = LineEdit.new()
	add_paint_code.placeholder_text = "Paint code (optional, e.g. 74 / WA9260)"
	add_paint_code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_paint_code.custom_minimum_size.y = 56
	ar2.add_child(add_paint_code)
	ar2.add_child(PorterUI.button("Save paint", _save_custom_paint, 170))
	add_paint_row.add_child(ar2)
	add_paint_row.visible = false
	v.add_child(add_paint_row)
	var tip := UIKit.label("Tips: tap a face to paint it with the chosen part. Need a window frame, headlight or stripe where there's no face? Go back to Shape and use Loop cut to add one. Glass, lights and chrome get their own look in the game; body paint and the second color follow the paint shop.", 20, UIKit.DIM)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(tip)
	return panel

## Factory colors of the car (the game car's list, or the paint database for
## the production car the project came from), plus paints added from photos,
## or a neutral set when the car is unknown.
func _factory_paints() -> Array:
	var out := []
	if project.source_car != "" and Game.cars.has(project.source_car):
		out = Game.cars[project.source_car].get("paints", []).duplicate()
	else:
		out = project.factory_paints()
	for cp in project.custom_paints:
		var lbl: String = cp["name"] if cp["name"] != "" else "My paint"
		if cp.get("code", "") != "":
			lbl += " (%s)" % cp["code"]
		out.append({"name": lbl + "  · from photo", "color": cp["color"], "lower": cp["color"], "metallic": 0.4})
	if not out.is_empty():
		return out
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
	var pc: Array = pd["color"]
	view.recolor_color = Color(pc[0], pc[1], pc[2])
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
	if interior_panel.visible and inside_paint != "":
		_paint_inside(fi)
		return
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
	var wells := _add_wheel_wells()
	_after_structural()
	_say("Arch cut%s. Draw the other one, or Undo to try again." % (" and its wheel well built (liner + inner wall %d cm inboard of the tire)" % int(round(WELL_CLEARANCE * 100.0)) if wells > 0 else ""))

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
	var wells := _add_wheel_wells()
	_after_structural()
	var well_txt := (" %d wheel well%s built inside." % [wells, "" if wells == 1 else "s"]) if wells > 0 else ""
	_say(("Wheel arches cut around both axles, sized from the tires." if msgs.is_empty() else "Cut one arch. " + " ".join(msgs)) + well_txt)

const WELL_CLEARANCE := 0.03          # tire to inner wall
const WELL_STEER := 0.05              # extra at the front for the tire swinging when steering

## Where a wheel well's inner wall goes: the tire's inner face (from the
## track and tire width) plus clearance, more at the front for steering.
func _well_inner_x(rear: bool) -> float:
	var d := project.dims
	var track: float = d["track_rear_m"] if rear else d["track_front_m"]
	var w: float = project.tires.get("rear_width_m" if rear else "front_width_m", 0.22)
	return -track * 0.5 + w * 0.5 + WELL_CLEARANCE + (0.0 if rear else WELL_STEER)

## Build wheel wells behind every open arch. Returns how many were built.
func _add_wheel_wells() -> int:
	var n := 0
	for rear in [false, true]:
		var axle_z: float = (project.dims["wheelbase_m"] * 0.5) * (1.0 if rear else -1.0)
		var r := project.tire_radius(rear)
		if mesh.add_wheel_tub(axle_z, r, r * 1.3, _well_inner_x(rear)) == "":
			n += 1
	return n

func _wheel_wells_button() -> void:
	mesh.push_undo()
	var n := _add_wheel_wells()
	if n == 0:
		mesh.undo()
		_say("No open arches to build wheel wells behind: cut arches first (they get wheel wells automatically), or they already have them.")
		return
	_after_structural()
	_say("Built %d wheel well%s: a liner following your arch line and an inner wall just inboard of the tire. They're black trim; Undo takes them back." % [n, "" if n == 1 else "s"])

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
	var tip := UIKit.label("The wheel is just the rim: this picture on a 16-sided disc, sized from the tire size. The game builds the tire around it so it squashes under load, bulges at low PSI, goes flat and rolls over in corners. Wheels stay separate from the body so the game can spin and steer them. Tip: cut wheel arches in Shape so the wheels show.", 20, UIKit.DIM)
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
	if seat_btn:
		seat_btn.set_pressed_no_signal(on)
	if dash_seat_btn:
		dash_seat_btn.set_pressed_no_signal(on)
	view.driver_view = on
	if depth_row:
		depth_row.visible = on and editing_dash
	if on:
		if window_btn.button_pressed:
			_toggle_cut_window(false)
		view.yaw = deg_to_rad(-140.0)
		view.pitch = 0.0
		_select_view("3d")
		if editing_dash:
			view.pitch = deg_to_rad(-12.0)      # look down at the dash a little
			view._update_cam()
			_say("Editing the dash from the driver's seat: tap points (or faces) to select, drag them to move. Drag empty space to look around, pinch to zoom. “Closer to me / Farther away” push points toward you or away. Side / Front views still work too.")
		else:
			_say("Driver's seat: drag to look around. This is roughly what the first-person view will see.")
	else:
		view._update_cam()
		if editing_dash:
			_select_view("side")
			_say("Editing the dashboard. Side view: drag points to match the dash profile; Front view for its width. “Start over from a template…” offers dash shapes now.")
	view.overlay.queue_redraw()

# ---------------------------------------------------------------- interior

func _section(v: VBoxContainer, title: String) -> void:
	var sep := HSeparator.new()
	v.add_child(sep)
	v.add_child(UIKit.label(title, 24, UIKit.ACCENT))

func _tip(v: VBoxContainer, t: String) -> void:
	var l := UIKit.label(t, 20, UIKit.DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(l)

## A row: label, value, − and + buttons. get_text() -> String shows the value.
func _stepper(v: VBoxContainer, key: String, label: String, minus: Callable, plus: Callable) -> void:
	var row := HBoxContainer.new()
	var l := UIKit.label(label, 22, Color.WHITE)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var val := UIKit.label("", 22, UIKit.ACCENT)
	val.custom_minimum_size.x = 130
	steer_labels[key] = val
	row.add_child(val)
	row.add_child(PorterUI.button("−", minus, 76))
	row.add_child(PorterUI.button("+", plus, 76))
	v.add_child(row)

func _build_interior_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(640, 0)
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

	v.add_child(UIKit.label("DRIVER'S SEAT", 24, UIKit.ACCENT))
	seat_btn = _grow(PorterUI.toggle("Driver's seat view", false, func(on): _driver_view(on)))
	v.add_child(seat_btn)
	_stepper(v, "eye_y", "Eye height", func(): _move_eye(Vector3(0, -0.01, 0)), func(): _move_eye(Vector3(0, 0.01, 0)))
	_stepper(v, "eye_z", "Seat back / forward", func(): _move_eye(Vector3(0, 0, 0.01)), func(): _move_eye(Vector3(0, 0, -0.01)))
	_stepper(v, "eye_x", "Seat toward door / center", func(): _move_eye(Vector3(-0.01, 0, 0)), func(): _move_eye(Vector3(0.01, 0, 0)))

	_section(v, "DASHBOARD")
	var tg := GridContainer.new()
	tg.columns = 3
	for key in InteriorBuilder.DASH_TEMPLATES:
		var k: String = key
		tg.add_child(_grow(PorterUI.button(InteriorBuilder.DASH_TEMPLATES[k]["label"].get_slice(" (", 0), func(): _new_dash(k))))
	v.add_child(tg)
	v.add_child(_grow(PorterUI.button("Edit the dash shape (point tools)", _start_edit_dash)))
	v.add_child(_grow(PorterUI.button("Load dash photo (from the driver's seat)…", func(): photo_requested.emit("dash"))))
	dash_view = DashPhotoView.new()
	dash_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dash_view.fit_changed.connect(func(final):
		if final:
			project.save()
			view.refresh_cabin())
	dash_view.gauge_tapped.connect(_on_gauge_tap)
	v.add_child(dash_view)
	var g := GridContainer.new()
	g.columns = 6
	for spec in [["◀", func(): dash_view.nudge_move(-1, 0)], ["▶", func(): dash_view.nudge_move(1, 0)],
			["▲", func(): dash_view.nudge_move(0, -1)], ["▼", func(): dash_view.nudge_move(0, 1)],
			["−", func(): dash_view.nudge_size(1.0 / 1.01)], ["+", func(): dash_view.nudge_size(1.01)]]:
		g.add_child(_grow(PorterUI.button(spec[0], spec[1], 80)))
	v.add_child(g)
	_stretch_rows(v, dash_view)
	var r1 := HBoxContainer.new()
	r1.add_child(_grow(PorterUI.button("Fit photo to the dash", func():
		var img := project.load_photo("dash")
		if img and dash_mesh:
			DashPhotoView.fit_to_dash(project, dash_mesh, img.get_width())
			project.save()
			dash_view.queue_redraw()
			view.refresh_cabin())))
	r1.add_child(_grow(PorterUI.button("Photo on the dash face", _dash_photo_faces)))
	v.add_child(r1)

	_section(v, "GAUGES (live in the game)")
	var gg := GridContainer.new()
	gg.columns = 3
	for key in InteriorBuilder.GAUGE_TYPES:
		var k: String = key
		gauge_btns[k] = _grow(PorterUI.toggle(InteriorBuilder.GAUGE_TYPES[k]["label"], false, func(on): _pick_gauge_type(k, on)))
		gg.add_child(gauge_btns[k])
	v.add_child(gg)
	v.add_child(_wheel_toggle())
	gauge_info = UIKit.label("", 20, UIKit.DIM)
	gauge_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(gauge_info)
	_stepper(v, "g_size", "Gauge size", func(): _gauge_edit("r", 1.0 / 1.06), func(): _gauge_edit("r", 1.06))
	_stepper(v, "g_max", "Full scale (mph / rpm)", func(): _gauge_edit("max", -1.0), func(): _gauge_edit("max", 1.0))
	var r2 := HBoxContainer.new()
	r2.add_child(_grow(PorterUI.button("Delete gauge", _delete_gauge)))
	r2.add_child(_grow(PorterUI.button("Done placing", _stop_placing)))
	v.add_child(r2)

	_section(v, "STEERING WHEEL")
	v.add_child(_grow(PorterUI.button("Load steering wheel photo (face-on)…", func(): photo_requested.emit("steering"))))
	steer_view = SteeringCropView.new()
	steer_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	steer_view.crop_changed.connect(func(final):
		if final:
			_apply_steer_crop())
	steer_view.hole_point_added.connect(func(): _say("%d points. Keep tapping around the gap, then Finish hole." % steer_view.hole_pts.size()))
	v.add_child(steer_view)
	var g2 := GridContainer.new()
	g2.columns = 6
	for spec in [["◀", func(): steer_view.nudge_move(-1, 0)], ["▶", func(): steer_view.nudge_move(1, 0)],
			["▲", func(): steer_view.nudge_move(0, -1)], ["▼", func(): steer_view.nudge_move(0, 1)],
			["−", func(): steer_view.nudge_size(1.0 / 1.01)], ["+", func(): steer_view.nudge_size(1.01)]]:
		g2.add_child(_grow(PorterUI.button(spec[0], spec[1], 80)))
	v.add_child(g2)
	hole_btn = _grow(PorterUI.toggle("Draw a hole (gap between spokes)", false, func(on): _toggle_hole(on)))
	v.add_child(hole_btn)
	hole_row = HBoxContainer.new()
	hole_row.add_child(_grow(PorterUI.button("Finish hole", _finish_hole)))
	hole_row.add_child(_grow(PorterUI.button("Undo point", func():
		if steer_view.hole_pts.size() > 0:
			steer_view.hole_pts.pop_back()
			steer_view.queue_redraw())))
	hole_row.add_child(_grow(PorterUI.button("Cancel", func(): _toggle_hole(false))))
	hole_row.visible = false
	v.add_child(hole_row)
	v.add_child(_grow(PorterUI.button("Remove the last hole", func():
		var holes: Array = project.steering()["holes"]
		if holes.size() > 0:
			holes.pop_back()
			project.save()
			steer_view.queue_redraw()
			view.refresh_cabin()
			_refresh_interior_labels())))
	_stepper(v, "s_dia", "Diameter", func(): _steer_set("diameter_m", -0.0127), func(): _steer_set("diameter_m", 0.0127))
	_stepper(v, "s_thk", "Rim thickness", func(): _steer_set("thickness_m", -0.005), func(): _steer_set("thickness_m", 0.005))
	_stepper(v, "s_tilt", "Tilt", func(): _steer_set("tilt_deg", -2.0), func(): _steer_set("tilt_deg", 2.0))
	_stepper(v, "s_y", "Height", func(): _steer_move(Vector3(0, -0.01, 0)), func(): _steer_move(Vector3(0, 0.01, 0)))
	_stepper(v, "s_z", "Toward driver / dash", func(): _steer_move(Vector3(0, 0, 0.01)), func(): _steer_move(Vector3(0, 0, -0.01)))
	_build_inside_section(v)
	_tip(v, "The steering wheel is a round template with your photo on it. Fit the orange circle to the rim, then draw around each gap between the spokes: those holes are cut right through, so you see the gauges through them from the driver's seat. In the game it turns with the car's real steering lock.")
	return panel

func _wheel_toggle() -> Button:
	var b := _grow(PorterUI.toggle("Hide steering wheel", not view.show_steering if view else false, func(on): _hide_wheel(on)))
	wheel_btns.append(b)
	return b

func _hide_wheel(on: bool) -> void:
	view.show_steering = not on
	for b in wheel_btns:
		b.set_pressed_no_signal(on)
	view.refresh_cabin()
	_say("Steering wheel hidden: the whole dash is visible for placing gauges. Turn it back on to check the view through the wheel." if on else "Steering wheel shown.")

func _open_interior() -> void:
	if InteriorBuilder.fit_driver_to_body(project, mesh):
		project.save()
		view._update_cam()
	# the body may have been reshaped since: pull the dash back inside it
	if dash_mesh and InteriorBuilder.keep_dash_inside(dash_mesh, mesh, project.driver_eye()) > 0:
		project.save_dash(dash_mesh)
		view.dash = dash_mesh
		view.refresh_cabin()
	dash_view.setup(project, dash_mesh)
	inside_photo_view.setup(project, dash_mesh, inside_view, mesh)
	steer_view.setup(project)
	_refresh_interior_labels()
	_driver_view(true)
	if dash_mesh == null:
		_say("Interior: pick a dashboard shape to start, load a dash photo taken from the driver's seat, place the gauges, then do the steering wheel.")
	else:
		_say("Interior: drag in the 3D view to look around from the driver's seat.")

func _refresh_interior_labels() -> void:
	if steer_labels.is_empty():
		return
	var e := project.driver_eye()
	var s := project.steering()
	var c := project.steering_center()
	steer_labels["eye_y"].text = "%.2f m" % e.y
	steer_labels["eye_z"].text = "%.2f m" % e.z
	steer_labels["eye_x"].text = "%.2f m" % e.x
	steer_labels["s_dia"].text = "%.1f in" % (float(s["diameter_m"]) / 0.0254)
	steer_labels["s_thk"].text = "%.1f cm" % (float(s["thickness_m"]) * 100.0)
	steer_labels["s_tilt"].text = "%d°" % int(round(float(s["tilt_deg"])))
	steer_labels["s_y"].text = "%.2f m" % c.y
	steer_labels["s_z"].text = "%.2f m" % c.z
	var gs: Array = project.interior.get("gauges", [])
	if gauge_sel >= 0 and gauge_sel < gs.size():
		var g: Dictionary = gs[gauge_sel]
		steer_labels["g_size"].text = "%.1f cm" % (float(g["r"]) * 200.0)
		steer_labels["g_max"].text = ("%d" % int(g["max"])) if g["type"] in ["speedo", "tach"] else "—"
	else:
		steer_labels["g_size"].text = "—"
		steer_labels["g_max"].text = "—"
	var holes: int = (s["holes"] as Array).size()
	gauge_info.text = "%d gauges on the dash. Line up (and stretch) the dash photo first, then pick a type and tap where it goes. Tap a gauge to select it.  ·  Steering wheel: %d holes cut." % [gs.size(), holes]

func _interior_changed() -> void:
	project.save()
	view.refresh_cabin()
	_refresh_interior_labels()

func _move_eye(d: Vector3) -> void:
	var had_center: bool = (project.steering().get("center", []) as Array).size() == 3
	var c := project.steering_center()
	project.set_driver_eye(project.driver_eye() + d)
	if not had_center:
		project.set_steering_center(c)       # the wheel stays put when the seat moves
	view._update_cam()
	_interior_changed()

# ---- dashboard

var _body_tris := PackedVector3Array()

## While editing the dash: moved points can't leave the body.
func _keep_dash_inside(ids: Array) -> void:
	if not editing_dash or body_mesh == null:
		return
	InteriorBuilder.keep_dash_inside(mesh, body_mesh, project.driver_eye(), ids, _body_tris)

func _new_dash(key: String) -> void:
	if InteriorBuilder.fit_driver_to_body(project, mesh):
		project.save()
	dash_mesh = InteriorBuilder.dash_from_template(key, project, mesh)
	InteriorBuilder.keep_dash_inside(dash_mesh, mesh, project.driver_eye())
	project.save_dash(dash_mesh)
	view.dash = dash_mesh
	var img := project.load_photo("dash")
	if img:
		DashPhotoView.fit_to_dash(project, dash_mesh, img.get_width())
		project.save()
	# gauges follow the new dash face
	for g in project.interior.get("gauges", []):
		var z := InteriorBuilder.dash_z_at(dash_mesh, g["x"], g["y"])
		g["on_dash"] = not is_nan(z)
		if not is_nan(z):
			g["z"] = snappedf(z, 0.001)
	dash_view.setup(project, dash_mesh)
	_interior_changed()
	_say("Dashboard: %s. Reshape it with “Edit the dash shape”, or load a dash photo." % InteriorBuilder.DASH_TEMPLATES[key]["label"])

func _start_edit_dash() -> void:
	if dash_mesh == null:
		_new_dash("truck")
	_save_mesh()
	body_mesh = mesh
	mesh = dash_mesh
	editing_dash = true
	_body_tris = InteriorBuilder.body_triangles(body_mesh)
	view.constrain_fn = _keep_dash_inside
	view.ghost = body_mesh
	view.mesh = dash_mesh
	dash_bar.visible = true
	_set_mode("shape", true)
	_driver_view(true)

func _end_edit_dash(to_interior: bool = true) -> void:
	if not editing_dash:
		return
	project.save_dash(mesh)
	dash_mesh = mesh
	mesh = body_mesh
	body_mesh = null
	editing_dash = false
	view.constrain_fn = Callable()
	view.ghost = null
	view.mesh = mesh
	view.dash = dash_mesh
	view.clear_selection()
	dash_bar.visible = false
	depth_row.visible = false
	# gauges re-seat on the reshaped dash
	for g in project.interior.get("gauges", []):
		var z := InteriorBuilder.dash_z_at(dash_mesh, g["x"], g["y"])
		g["on_dash"] = not is_nan(z)
		if not is_nan(z):
			g["z"] = snappedf(z, 0.001)
	project.save()
	view.rebuild_body()
	_refresh_info()
	if to_interior:
		_set_mode("interior", true)

## Faces looking at the driver take the dash photo; the rest are black trim.
func _dash_photo_faces() -> void:
	if dash_mesh == null:
		_say("Pick a dashboard shape first.")
		return
	for fi in dash_mesh.faces.size():
		var n := dash_mesh.face_normal(dash_mesh.faces[fi])
		dash_mesh.regions[fi] = "photo:dash" if n.z > 0.35 else "trim"
	project.save_dash(dash_mesh)
	view.refresh_cabin()
	_say("Photo on every face that looks at the driver; the top and sides are black trim. Fine-tune in Paint while editing the dash.")

# ---- gauges

func _pick_gauge_type(k: String, on: bool) -> void:
	for t in gauge_btns:
		gauge_btns[t].set_pressed_no_signal(on and t == k)
	gauge_type = k if on else ""
	dash_view.placing = on
	dash_view.queue_redraw()
	if on:
		if project.load_photo("dash") == null or dash_mesh == null:
			_say("Pick a dashboard shape and load a dash photo first, then place gauges on it.")
		else:
			_say("Tap on the dash photo where the %s goes." % InteriorBuilder.GAUGE_TYPES[k]["label"].to_lower())

func _stop_placing() -> void:
	gauge_type = ""
	for t in gauge_btns:
		gauge_btns[t].set_pressed_no_signal(false)
	if dash_view:
		dash_view.placing = false
		dash_view.queue_redraw()

func _on_gauge_tap(p: Vector2, hit: int) -> void:
	var gs: Array = project.interior.get("gauges", [])
	if hit >= 0:
		gauge_sel = hit
	elif gauge_type != "":
		var g := InteriorBuilder.make_gauge(gauge_type, p.x, p.y, dash_mesh)
		gs.append(g)
		project.interior["gauges"] = gs
		gauge_sel = gs.size() - 1
		if not g["on_dash"]:
			_say("That spot isn't on the dash face (outside the blue outline). Move it with Delete + tap again, or reshape the dash.")
		else:
			_say("%s placed. Size it with Gauge size; pick another type or Done placing." % InteriorBuilder.GAUGE_TYPES[gauge_type]["label"])
	dash_view.selected = gauge_sel
	dash_view.queue_redraw()
	_interior_changed()

func _gauge_edit(key: String, k: float) -> void:
	var gs: Array = project.interior.get("gauges", [])
	if gauge_sel < 0 or gauge_sel >= gs.size():
		_say("Tap a gauge on the dash photo to select it first.")
		return
	var g: Dictionary = gs[gauge_sel]
	if key == "r":
		g["r"] = clampf(snappedf(float(g["r"]) * k, 0.001), 0.008, 0.12)
	else:
		if g["type"] == "speedo":
			g["max"] = clampf(float(g["max"]) + k * 10.0, 40.0, 240.0)
		elif g["type"] == "tach":
			g["max"] = clampf(float(g["max"]) + k * 500.0, 3000.0, 12000.0)
	dash_view.queue_redraw()
	_interior_changed()

func _delete_gauge() -> void:
	var gs: Array = project.interior.get("gauges", [])
	if gauge_sel < 0 or gauge_sel >= gs.size():
		return
	gs.remove_at(gauge_sel)
	gauge_sel = -1
	dash_view.selected = -1
	dash_view.queue_redraw()
	_interior_changed()

# ---- steering wheel

func _apply_steer_crop() -> void:
	project.steering()["crop"] = steer_view.crop.duplicate()
	project.make_steering_texture()
	view.steering_picture_changed()
	_interior_changed()

func _toggle_hole(on: bool) -> void:
	steer_view.hole_pts.clear()
	steer_view.drawing = on
	hole_btn.set_pressed_no_signal(on)
	hole_row.visible = on
	steer_view.queue_redraw()
	if on:
		if project.load_photo("steering") == null:
			_say("Load a steering wheel photo first; the holes are drawn on it.")
		else:
			_say("Tap around one gap between the spokes on the photo, then Finish hole.")

func _finish_hole() -> void:
	if steer_view.hole_pts.size() < 3:
		_say("A hole needs at least 3 points.")
		return
	var poly := PackedVector2Array(steer_view.hole_pts)
	if Geometry2D.triangulate_polygon(poly).is_empty():
		_say("That outline crosses itself. Undo a point or two and go around in order.")
		return
	var arr := []
	for p in poly:
		arr.append([snappedf(p.x, 0.001), snappedf(p.y, 0.001)])
	var holes: Array = project.steering()["holes"]
	holes.append(arr)
	var left := InteriorBuilder.face_area(holes) / PI
	if left < 0.05:
		holes.pop_back()
		_say("That would cut away almost the whole wheel.")
		return
	steer_view.hole_pts.clear()
	steer_view.queue_redraw()
	_interior_changed()
	_say("Hole cut (%d so far). Draw the next gap, or Cancel when done." % holes.size())

func _steer_set(key: String, d: float) -> void:
	var s := project.steering()
	var lim := {"diameter_m": [0.25, 0.50], "thickness_m": [0.015, 0.06], "tilt_deg": [0.0, 60.0]}
	s[key] = clampf(float(s[key]) + d, lim[key][0], lim[key][1])
	_interior_changed()

func _steer_move(d: Vector3) -> void:
	project.set_steering_center(project.steering_center() + d)
	_interior_changed()

## porter_main calls this after a photo for `view_name` was imported.
func on_photo_loaded(view_name: String) -> void:
	if view_name == "dash":
		var img := project.load_photo("dash")
		if img and dash_mesh:
			DashPhotoView.fit_to_dash(project, dash_mesh, img.get_width())
		project.save()
		dash_view.setup(project, dash_mesh)
		if dash_mesh == null:
			_say("Dash photo loaded. Pick a dashboard shape so it has something to sit on.")
		else:
			_dash_photo_faces()
			_say("Dash photo loaded and fitted. Drag / pinch it so the blue outline sits on the dash, then place the gauges.")
	elif view_name in HalfMesh.INNER_PHOTOS:
		view.photo_changed(view_name)
		var img2 := project.load_photo(view_name)
		if img2:
			DashPhotoView.fit_to_outline(project, view_name, DashPhotoView.panel_outline(project, mesh, view_name), img2.get_width())
		project.save()
		_pick_inside_view(view_name)
		view.rebuild_body()
		_say("%s photo loaded. Paint it on: pick “%s photo” under Paint the inside and tap panels from the driver's seat (or Auto). Then drag / pinch it onto the blue outline." % [PorterProject.VIEW_LABELS[view_name], PorterProject.VIEW_LABELS[view_name]])
	elif view_name == "steering":
		project.steering()["crop"] = {}
		steer_view.setup(project)
		project.steering()["crop"] = steer_view.crop.duplicate()
		project.make_steering_texture()
		view.steering_picture_changed()
		_say("Steering photo loaded. Fit the orange circle to the wheel's rim, then draw the holes between the spokes.")
	_interior_changed()

# ---- inside panels: doors, pillars, ceiling

func _build_inside_section(v: VBoxContainer) -> void:
	_section(v, "INSIDE PANELS (doors, pillars, ceiling)")
	var tabs_row := HBoxContainer.new()
	for k in HalfMesh.INNER_PHOTOS:
		var key: String = k
		inside_tabs[key] = _grow(PorterUI.toggle(PorterProject.VIEW_LABELS[key], key == inside_view, func(on): _pick_inside_view(key) if on else inside_tabs[key].set_pressed_no_signal(true)))
		tabs_row.add_child(inside_tabs[key])
	v.add_child(tabs_row)
	inside_load_btn = _grow(PorterUI.button("", func(): photo_requested.emit(inside_view)))
	v.add_child(inside_load_btn)
	inside_photo_view = DashPhotoView.new()
	inside_photo_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inside_photo_view.fit_changed.connect(func(final):
		if final:
			project.save()
			view.rebuild_body())
	v.add_child(inside_photo_view)
	var g := GridContainer.new()
	g.columns = 6
	for spec in [["◀", func(): inside_photo_view.nudge_move(-1, 0)], ["▶", func(): inside_photo_view.nudge_move(1, 0)],
			["▲", func(): inside_photo_view.nudge_move(0, -1)], ["▼", func(): inside_photo_view.nudge_move(0, 1)],
			["−", func(): inside_photo_view.nudge_size(1.0 / 1.01)], ["+", func(): inside_photo_view.nudge_size(1.01)]]:
		g.add_child(_grow(PorterUI.button(spec[0], spec[1], 80)))
	v.add_child(g)
	var r := HBoxContainer.new()
	_stretch_rows(v, inside_photo_view)
	r.add_child(_grow(PorterUI.button("Flip", func(): inside_photo_view.flip())))
	r.add_child(_grow(PorterUI.button("Rotate 90°", func(): inside_photo_view.rotate_90())))
	r.add_child(_grow(PorterUI.button("Fit to outline", func():
		var img := project.load_photo(inside_view)
		if img:
			DashPhotoView.fit_to_outline(project, inside_view, DashPhotoView.panel_outline(project, mesh, inside_view), img.get_width())
			project.save()
			inside_photo_view.queue_redraw()
			view.rebuild_body())))
	v.add_child(r)
	v.add_child(UIKit.label("Paint the inside (tap panels from the driver's seat)", 22, Color.WHITE))
	var pg := GridContainer.new()
	pg.columns = 3
	var choices := []
	for k in HalfMesh.INNER_PHOTOS:
		choices.append(["photo:" + k, PorterProject.VIEW_LABELS[k] + " photo"])
	for k in ["lining", "dark", "tan", "carpet"]:
		choices.append([k, HalfMesh.INNER_REGIONS[k]["label"]])
	for c in choices:
		var val: String = c[0]
		inside_paint_btns[val] = _grow(PorterUI.toggle(c[1], false, func(on): _pick_inside_paint(val, on)))
		pg.add_child(inside_paint_btns[val])
	v.add_child(pg)
	var r2 := HBoxContainer.new()
	r2.add_child(_grow(PorterUI.toggle("Fill connected", false, func(on): inside_fill = on)))
	r2.add_child(_grow(PorterUI.button("Auto (photos where loaded)", _auto_inside)))
	r2.add_child(_grow(PorterUI.button("Done", _stop_inside_paint, 120)))
	v.add_child(r2)
	_tip(v, "Take the door photo from the passenger seat looking straight at the driver's door, the A-pillar from the driver's seat, and the ceiling with the phone overhead, top toward the windshield. Both doors and both pillars use the same photo (mirrored). Paint with “… photo”, then drag / pinch the photo onto the blue outline; Flip / Rotate if it's turned.")
	_pick_inside_view(inside_view)

func _pick_inside_view(k: String) -> void:
	inside_view = k
	for t in inside_tabs:
		inside_tabs[t].set_pressed_no_signal(t == k)
	inside_load_btn.text = "Load %s photo…" % PorterProject.VIEW_LABELS[k].to_lower()
	inside_photo_view.setup(project, dash_mesh, k, mesh)

func _pick_inside_paint(val: String, on: bool) -> void:
	for t in inside_paint_btns:
		inside_paint_btns[t].set_pressed_no_signal(on and t == val)
	inside_paint = val if on else ""
	if on:
		_stop_placing()
		view.tool = "paint"
		if not view.driver_view:
			_driver_view(true)
		if val.begins_with("photo:"):
			var pv := val.get_slice(":", 1)
			_pick_inside_view(pv)
			if project.load_photo(pv) == null:
				_say("Load the %s photo first (button above), then tap panels." % PorterProject.VIEW_LABELS[pv].to_lower())
				return
		_say("Tap panels inside the car to paint them %s. Drag empty space to look around." % (inside_paint_btns[val].text.to_lower()))
	else:
		view.tool = "interior"

func _stop_inside_paint() -> void:
	inside_paint = ""
	for t in inside_paint_btns:
		inside_paint_btns[t].set_pressed_no_signal(false)
	if view.tool == "paint" and interior_panel.visible:
		view.tool = "interior"

func _paint_inside(fi: int) -> void:
	if HalfMesh.region_base(mesh.regions[fi]) == "glass":
		_say("That's glass (a window): tap the panel around it.")
		return
	var targets: Array = mesh.connected_same_region(fi, true) if inside_fill else [fi]
	if mesh.inner_region_of(fi) == inside_paint and targets.size() == 1:
		return
	mesh.push_undo()
	mesh.set_inner_region(targets, inside_paint)
	view.rebuild_body()
	inside_photo_view.queue_redraw()
	_queue_save()

func _auto_inside() -> void:
	var has := {}
	for k in HalfMesh.INNER_PHOTOS:
		has[k] = project.load_photo(k) != null
	mesh.push_undo()
	var n := InteriorBuilder.auto_inside(mesh, has)
	view.rebuild_body()
	inside_photo_view.queue_redraw()
	_queue_save()
	_say("Inside painted: %d panels (ceiling, doors, pillars, carpet floor). Tap panels with a choice above to fix any, or Undo in Shape." % n)

## Stretch controls under a photo fit view: wider / narrower / taller /
## shorter buttons, a pinch-to-stretch toggle and a reset.
func _stretch_rows(v: VBoxContainer, pv: DashPhotoView) -> void:
	var g := GridContainer.new()
	g.columns = 4
	for spec in [["↔ wider", 1.01, 1.0], ["↔ narrower", 1.0 / 1.01, 1.0], ["↕ taller", 1.0, 1.01], ["↕ shorter", 1.0, 1.0 / 1.01]]:
		var kx: float = spec[1]
		var ky: float = spec[2]
		g.add_child(_grow(PorterUI.button(spec[0], func(): pv.stretch(kx, ky), 80)))
	v.add_child(g)
	var r := HBoxContainer.new()
	var tb := _grow(PorterUI.toggle("Pinch stretches", false, func(on):
		pv.stretching = on
		pv.queue_redraw()))
	r.add_child(tb)
	r.add_child(_grow(PorterUI.button("Reset stretch", func():
		var vv: Dictionary = project.views[pv.view_name]
		pv.stretch(1.0 / float(vv.get("sx", 1.0)), 1.0 / float(vv.get("sy", 1.0))))))
	v.add_child(r)

# ---------------------------------------------------------------- recolouring photo paint

func _build_recolor_section(v: VBoxContainer) -> void:
	v.add_child(HSeparator.new())
	v.add_child(UIKit.label("RECOLOR PHOTO PAINT", 24, UIKit.ACCENT))
	var kr := HBoxContainer.new()
	key_swatch = ColorRect.new()
	key_swatch.custom_minimum_size = Vector2(56, 56)
	kr.add_child(key_swatch)
	key_label = UIKit.label("", 20, UIKit.DIM)
	key_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	key_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kr.add_child(key_label)
	v.add_child(kr)
	pick_paint_btn = _grow(PorterUI.toggle("Pick the paint color (tap the paint on a photo)", false, func(on): _toggle_pick_paint(on)))
	v.add_child(pick_paint_btn)
	_stepper(v, "tol", "How close counts as paint", func(): _set_tolerance(-0.02), func(): _set_tolerance(0.02))
	var r := HBoxContainer.new()
	recolor_btn = _grow(PorterUI.toggle("Preview in the color above", false, func(on):
		view.recolor_on = on
		if on:
			view.show_paint_match = false
			match_btn.set_pressed_no_signal(false)
		view.rebuild_body()))
	match_btn = _grow(PorterUI.toggle("Show what's paint", false, func(on):
		view.show_paint_match = on
		if on:
			view.recolor_on = false
			recolor_btn.set_pressed_no_signal(false)
		view.rebuild_body()))
	r.add_child(recolor_btn)
	r.add_child(match_btn)
	v.add_child(r)
	v.add_child(UIKit.label("Touch up (stickers, stripes, misses):", 22, Color.WHITE))
	var tr := HBoxContainer.new()
	for k in PorterProject.VIEWS:
		var key: String = k
		mask_tabs[key] = _grow(PorterUI.toggle(PorterProject.VIEW_LABELS[key], key == "side", func(on): _pick_mask_view(key) if on else mask_tabs[key].set_pressed_no_signal(true)))
		mask_tabs[key].custom_minimum_size.x = 0
		tr.add_child(mask_tabs[key])
	v.add_child(tr)
	mask_editor = PaintMaskEditor.new()
	mask_editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mask_editor.mask_changed.connect(func():
		view.paint_mask_changed(mask_editor.view_name)
		view.rebuild_body())
	v.add_child(mask_editor)
	var br := HBoxContainer.new()
	for spec in [[0.0, "Not paint"], [1.0, "Paint"], [0.5, "Auto (erase)"]]:
		var val: float = spec[0]
		brush_btns[val] = _grow(PorterUI.toggle(spec[1], val == 0.0, func(on): _pick_brush(val, on)))
		br.add_child(brush_btns[val])
	v.add_child(br)
	_stepper(v, "brush", "Brush size", func(): _brush_size(1.0 / 1.25), func(): _brush_size(1.25))
	v.add_child(_grow(PorterUI.button("Clear touch-ups on this photo", func(): mask_editor.clear())))
	_tip(v, "Tap the car's paint once on a Side / Front / Rear / Top photo. Everything close to that color becomes paint the game can recolor, keeping the photo's reflections and shading; badges, chrome, rubber and lights keep their real color. Check it with “Show what's paint”, paint stickers with “Not paint”, then try colors from Preview color below. Evenly lit (overcast) photos work best.")
	_refresh_key_ui()

func _refresh_key_ui() -> void:
	if key_swatch == null:
		return
	var has := project.has_paint_key()
	key_swatch.color = project.paint_key_color() if has else Color(0.15, 0.15, 0.17)
	if not has:
		key_label.text = "No paint color picked yet."
	elif PaintKey.is_grey(project.paint_key_color()):
		key_label.text = "Paint picked. It's white / black / silver, so matching leans on brightness: expect more touch-ups."
	else:
		key_label.text = "Paint picked. Pixels this hue (light or shaded) get recolored."
	if steer_labels.has("tol"):
		steer_labels["tol"].text = "%d%%" % int(round(project.paint_tolerance() * 100.0))
	if steer_labels.has("brush") and mask_editor:
		steer_labels["brush"].text = "%d px" % int(mask_editor.brush_px)
	if mask_editor:
		mask_editor.refresh_key()

func _toggle_pick_paint(on: bool) -> void:
	pick_paint_btn.set_pressed_no_signal(on)
	if on:
		_driver_view(false)
		view.tool = "pick_paint"
		if not (view.view in PorterProject.VIEWS):
			_select_view("side")
		_say("Tap a clean, evenly lit spot of the paint on the photo (not a reflection or shadow).")
	else:
		if view.tool == "pick_paint":
			view.tool = "paint"

func _fill_preview_paints() -> void:
	for c in preview_grid.get_children():
		c.queue_free()
	var paints := _factory_paints()
	var id := project.car_identity()
	var db_n := 0
	var near := false
	for pdef in paints:
		if pdef.get("factory_db", false):
			db_n += 1
			near = near or pdef.get("near_year", false)
	if project.source_car != "":
		paint_source_lbl.text = "Factory colors of the game car%s." % (" (%d from the paint database)" % db_n if db_n > 0 else "")
	elif not id.is_empty():
		paint_source_lbl.text = ("%d factory colors for %d %s from the paint database%s. Colors are estimated from the names." % [db_n, id["year"], id["make"].capitalize(), " (nearby years: none listed for this exact year yet)" if near else ""]) if db_n > 0 else "No factory colors for %d %s in the paint database yet: add yours from the photo." % [id["year"], id["make"].capitalize()]
	else:
		paint_source_lbl.text = "Generic colors (this project wasn't started from a production car)."
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
		preview_grid.add_child(b2)

var _pick_for_custom := false

func _toggle_add_paint(on: bool) -> void:
	add_paint_btn.set_pressed_no_signal(on)
	add_paint_row.visible = on
	_pick_for_custom = on
	if on:
		_picked_custom = Color(-1, 0, 0)
		add_paint_swatch.color = Color(0.15, 0.15, 0.17)
		_driver_view(false)
		view.tool = "pick_paint"
		if not (view.view in PorterProject.VIEWS):
			_select_view("side")
		_say("Tap a clean, evenly lit spot of the paint on the photo, then type its factory name (and code if you know it) and Save paint.")
	elif view.tool == "pick_paint" and not pick_paint_btn.button_pressed:
		view.tool = "paint"

func _save_custom_paint() -> void:
	if _picked_custom.r < 0.0:
		_say("Tap the paint on the photo first.")
		return
	project.add_custom_paint(add_paint_name.text, add_paint_code.text, _picked_custom)
	project.save()
	add_paint_name.text = ""
	add_paint_code.text = ""
	_toggle_add_paint(false)
	_fill_preview_paints()
	_say("Paint saved to this car: it's in Preview color now, and export will add it to the car's paint list.")

func _on_paint_pick(s: Vector2) -> void:
	var pv: String = view.view
	if not (pv in PorterProject.VIEWS):
		_say("Switch to Side, Front, Rear or Top to tap the photo.")
		return
	var img: Image = view._photo(pv)["img"]
	if img == null:
		_say("This view has no photo.")
		return
	var world := view.cam.project_position(s, 5.0)
	var sz := Vector2(img.get_width(), img.get_height())
	var px := project.frame_to_image(pv, PhotoTexturer.world_to_frame(project, pv, world), sz)
	if px.x < 0 or px.y < 0 or px.x >= sz.x or px.y >= sz.y:
		_say("That's off the photo. Tap on the car's paint.")
		return
	var sampled := PaintKey.sample(img, Vector2i(px), 4)
	if _pick_for_custom:
		_picked_custom = sampled
		add_paint_swatch.color = sampled
		_say("Color picked. Type its factory name (and code if you know it), then Save paint. Tap again to re-pick.")
		return
	project.set_paint_key(sampled)
	project.save()
	_toggle_pick_paint(false)
	view.show_paint_match = true
	view.recolor_on = false
	match_btn.set_pressed_no_signal(true)
	recolor_btn.set_pressed_no_signal(false)
	view.rebuild_body()
	_refresh_key_ui()
	_pick_mask_view(pv)
	_say("Paint color picked. Blue shows what will be recolored; adjust “How close counts as paint”, touch up below, then try “Preview in the color above”.")

func _set_tolerance(d: float) -> void:
	project.paint_key["tolerance"] = clampf(snappedf(project.paint_tolerance() + d, 0.01), 0.06, 0.6)
	project.save()
	_refresh_key_ui()
	view.rebuild_body()

func _pick_mask_view(k: String) -> void:
	for t in mask_tabs:
		mask_tabs[t].set_pressed_no_signal(t == k)
	mask_editor.setup(project, k)

func _pick_brush(val: float, on: bool) -> void:
	for t in brush_btns:
		brush_btns[t].set_pressed_no_signal(t == val)
	mask_editor.brush_value = val
	mask_editor.queue_redraw()

func _brush_size(k: float) -> void:
	mask_editor.brush_px = clampf(mask_editor.brush_px * k, 8.0, 200.0)
	_refresh_key_ui()
