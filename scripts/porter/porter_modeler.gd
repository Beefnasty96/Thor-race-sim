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

func setup(p: PorterProject) -> void:
	project = p
	mesh = project.load_mesh()
	add_theme_constant_override("separation", 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build()
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
	hb.add_child(UIKit.label("MODEL", 22, UIKit.DIM))
	for v in [["side", "Side"], ["front", "Front"], ["top", "Top"], ["3d", "3D"]]:
		var key: String = v[0]
		var b := PorterUI.button(v[1], func(): _select_view(key), 130)
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
	hint = UIKit.label("", 24, UIKit.WARN)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.set_anchors_preset(Control.PRESET_TOP_WIDE)
	hint.offset_left = 20; hint.offset_right = -20; hint.offset_top = 12
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(hint)
	body.add_child(_build_panel())

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
	r6.add_child(_grow(PorterUI.toggle("See-through", true, func(on): view.set_xray(on))))
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

func _start_loop_cut() -> void:
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
