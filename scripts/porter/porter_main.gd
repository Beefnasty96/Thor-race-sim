extends Control
## Car Porter: companion app for building cars for the game on a phone.
## v0.1: projects + reference photo setup (side/front/rear/top photos aligned
## to the car's true dimensions). Modeling, paint regions, specs and export
## come next.

var project: PorterProject
var canvas: BlueprintCanvas
var preview: BlueprintPreview
var current_view := "side"
var screen: Control
var prompt: Label
var tabs := {}
var dim_edits := {}
var mode_buttons := {}
var opacity_slider: HSlider
var _save_timer := 0.0
var _file_dialog: FileDialog
var safe: MarginContainer          # everything sits inside the phone's safe area
var _safe_check := 0.0
var modeler: PorterModeler
var _modeler_photo := ""            # interior photo the modeler asked for ("" = editor view)

const DIM_FIELDS := [
	["length_m", "Length"], ["width_m", "Width"], ["height_m", "Height"],
	["wheelbase_m", "Wheelbase"], ["front_overhang_m", "Front overhang"],
	["track_front_m", "Front track"], ["track_rear_m", "Rear track"],
]

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = UIKit.theme()
	theme.default_font_size = 28
	get_tree().set_quit_on_go_back(false)
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.035, 0.065)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	safe = MarginContainer.new()
	safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(safe)
	get_viewport().size_changed.connect(_apply_safe_area)
	_apply_safe_area()
	show_projects()
	if "--shots" in OS.get_cmdline_user_args():
		var d = load("res://scripts/tests/porter_shots.gd").new()
		d.app = self
		add_child(d)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if modeler and is_instance_valid(modeler):
			modeler.save_now()
			show_editor()
		elif project:
			_close_project()
		else:
			get_tree().quit()

## Keep the UI clear of the status bar, navigation bar and camera cutout.
## Android reports the safe area in window pixels; the UI is laid out in a
## stretched 1920x1080-based canvas, so convert.
func _apply_safe_area() -> void:
	if safe == null:
		return
	var win := Vector2(DisplayServer.window_get_size())
	var canvas := get_viewport().get_visible_rect().size
	var m := [0.0, 0.0, 0.0, 0.0]          # left, top, right, bottom (canvas px)
	if win.x > 0 and win.y > 0 and OS.has_feature("mobile"):
		var area := Rect2(DisplayServer.get_display_safe_area())
		var k := canvas / win
		m = [area.position.x * k.x, area.position.y * k.y,
			maxf(0.0, win.x - area.end.x) * k.x, maxf(0.0, win.y - area.end.y) * k.y]
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--fake-safe="):     # dev: simulate phone insets, window px "l,t,r,b"
			var f := arg.trim_prefix("--fake-safe=").split(",")
			var k2 := canvas / win
			m = [f[0].to_float() * k2.x, f[1].to_float() * k2.y, f[2].to_float() * k2.x, f[3].to_float() * k2.y]
	var names := ["left", "top", "right", "bottom"]
	for i in 4:
		safe.add_theme_constant_override("margin_" + names[i], int(ceil(m[i])))

func _process(delta: float) -> void:
	# insets can arrive or change after start-up and on rotation; recheck now and then
	_safe_check -= delta
	if _safe_check <= 0.0:
		_safe_check = 1.0
		_apply_safe_area()
	if _save_timer > 0.0:
		_save_timer -= delta
		if _save_timer <= 0.0 and project:
			project.save()

func _queue_save() -> void:
	_save_timer = 0.6

func _set_screen(c: Control) -> void:
	if screen:
		screen.queue_free()
	screen = c
	safe.add_child(c)

# =============================================================== projects screen

func show_projects() -> void:
	project = null
	modeler = null
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 48)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 16)
	m.add_child(v)
	v.add_child(UIKit.label("CAR PORTER", 56, Color.WHITE))
	v.add_child(UIKit.label("Build cars for Racing Sim: reference photos → model → paint → specs → export", 24, UIKit.DIM))

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 40)
	h.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(h)

	# left: start a new car
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 12)
	left.custom_minimum_size = Vector2(760, 0)
	h.add_child(left)
	left.add_child(UIKit.label("NEW CAR", 30, UIKit.ACCENT))
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "Name, e.g. 1994 Mazda MX-5"
	name_edit.custom_minimum_size = Vector2(0, PorterUI.BTN_H)
	left.add_child(name_edit)
	var find := PorterUI.button("Find a production car (year, make, model)", func():
		show_finder(name_edit.text.strip_edges()))
	find.add_theme_color_override("font_color", UIKit.GOOD)
	left.add_child(find)
	left.add_child(PorterUI.button("Start blank (enter dimensions yourself)", func():
		var n := name_edit.text.strip_edges()
		show_tire_step(n if n != "" else "New car", {}, func(p: PorterProject): pass)))
	left.add_child(UIKit.label("Or copy real dimensions from a car already in the game:", 22, UIKit.DIM))
	for car_id in Game.cars:
		var def: Dictionary = Game.cars[car_id]
		for body_key in def["bodies"]:
			var b: Dictionary = def["bodies"][body_key]
			var label := "%d %s %s, %s" % [def["year"], def["make"], def["model"], b.get("label", body_key)]
			left.add_child(PorterUI.button(label, func():
				var n := name_edit.text.strip_edges()
				var draft := PorterProject.new()
				draft.fill_from_car(def, body_key)
				show_tire_step(n if n != "" else label, draft.tires,
					func(p: PorterProject): p.fill_from_car(def, body_key))))

	# right: existing projects
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 12)
	h.add_child(right)
	right.add_child(UIKit.label("YOUR PROJECTS", 30, UIKit.ACCENT))
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(sc)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 10)
	sc.add_child(list)
	var projects := PorterProject.list_projects()
	if projects.is_empty():
		list.add_child(UIKit.label("No projects yet.", 24, UIKit.DIM))
	for info in projects:
		var p := PorterProject.load_project(info["id"])
		if p == null:
			continue
		var b2 := PorterUI.button("%s    ·  %d/4 photos" % [p.name, p.photo_count()], func(): _open(PorterProject.load_project(info["id"])))
		b2.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_child(b2)
	_set_screen(m)

## Tire step for new projects that don't come from the finder. `fill` sets up
## the new project's dimensions before the tires are applied.
func show_tire_step(project_name: String, prefill: Dictionary, fill: Callable) -> void:
	var m := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 48)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 18)
	m.add_child(v)
	var top := HBoxContainer.new()
	top.add_child(PorterUI.button("◀ Back", show_projects, 160))
	var t := UIKit.label("NEW CAR: " + project_name, 34, Color.WHITE)
	t.clip_text = true
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(t)
	v.add_child(top)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 40)
	v.add_child(row)
	var form := TireForm.new()
	form.custom_minimum_size = Vector2(900, 0)
	row.add_child(form)
	var side_v := VBoxContainer.new()
	side_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(side_v)
	var tip := UIKit.label("The tire size sets the wheel size in the photos and the model. Leave Rear empty if it matches the front. Pressures are the cold PSI from the door sticker.", 22, UIKit.DIM)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side_v.add_child(tip)
	var go := PorterUI.button("Create project ▶", func(): pass)
	go.add_theme_color_override("font_color", UIKit.GOOD)
	go.pressed.connect(func():
		var tv := form.values()
		var p := PorterProject.create(project_name)
		fill.call(p)
		var err := p.set_tires(tv[0], tv[1], tv[2], tv[3])
		if err != "":
			return
		p.save()
		_open(p))
	side_v.add_child(go)
	var refresh := func():
		go.disabled = not form.is_valid()
		go.text = "Create project ▶" if form.is_valid() else "Enter tire sizes and PSI"
	form.changed.connect(refresh)
	_set_screen(m)
	form.set_values(prefill)
	refresh.call()

func show_finder(custom_name: String = "") -> void:
	var m := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 32)
	var f := CarFinder.new()
	m.add_child(f)
	f.cancelled.connect(show_projects)
	f.chosen.connect(func(r: Dictionary, tv: Array):
		var label := "%d %s %s" % [r["year"], r["make"], VehicleDB.pretty(r["model"])]
		var p := PorterProject.create(custom_name if custom_name != "" else label)
		p.fill_from_db(r)
		p.set_tires(tv[0], tv[1], tv[2], tv[3])
		p.save()
		_open(p))
	_set_screen(m)

func _open(p: PorterProject) -> void:
	project = p
	project.save()
	current_view = "side"
	show_editor()

func _close_project() -> void:
	if project:
		project.save()
	show_projects()

# =============================================================== modeler

func show_modeler() -> void:
	project.save()
	modeler = PorterModeler.new()
	modeler.setup(project)
	modeler.back_to_photos.connect(show_editor)
	modeler.photo_requested.connect(func(v: String):
		_modeler_photo = v
		_pick_photo())
	_set_screen(modeler)

# =============================================================== reference photo editor

func show_editor() -> void:
	modeler = null
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)

	# --- top bar
	var bar := PanelContainer.new()
	root.add_child(bar)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	bar.add_child(hb)
	hb.add_child(PorterUI.button("◀ Projects", _close_project))
	var title := UIKit.label(project.name, 28, Color.WHITE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.clip_text = true
	hb.add_child(title)
	hb.add_child(UIKit.label("REFERENCE PHOTOS", 22, UIKit.DIM))
	tabs.clear()
	for v in PorterProject.VIEWS:
		var t := PorterUI.button("", func(): _select_view(v), 150)
		tabs[v] = t
		hb.add_child(t)
	var t3d := PorterUI.button("3D check", func(): _select_view("3d"), 170)
	tabs["3d"] = t3d
	hb.add_child(t3d)
	var next := PorterUI.button("Next: Model ▶", show_modeler, 230)
	next.add_theme_color_override("font_color", UIKit.GOOD)
	hb.add_child(next)

	# --- body: canvas + side panel
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	root.add_child(body)
	var stage := Control.new()
	stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage.clip_contents = true
	body.add_child(stage)
	canvas = BlueprintCanvas.new()
	canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	stage.add_child(canvas)
	canvas.transform_changed.connect(func():
		_queue_save()
		_refresh_tabs())
	canvas.align_progress.connect(_on_align_progress)
	preview = BlueprintPreview.new()
	preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	preview.visible = false
	stage.add_child(preview)
	prompt = UIKit.label("", 26, UIKit.WARN)
	prompt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	prompt.set_anchors_preset(Control.PRESET_TOP_WIDE)
	prompt.offset_left = 24; prompt.offset_right = -24; prompt.offset_top = 16
	prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(prompt)

	body.add_child(_build_side_panel())
	_set_screen(root)
	_select_view(current_view)

func _build_side_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(560, 0)
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(sc)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_theme_constant_override("margin_right", 22)   # room for the scroll bar
	sc.add_child(pad)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 10)
	pad.add_child(v)

	v.add_child(UIKit.label("PHOTO", 24, UIKit.ACCENT))
	var r1 := HBoxContainer.new()
	r1.add_child(_grow(PorterUI.button("Load photo…", _pick_photo)))
	r1.add_child(_grow(PorterUI.button("Mirror", func():
		var vw: Dictionary = project.views[current_view]
		vw["flip"] = not vw["flip"]
		canvas.queue_redraw(); _queue_save())))
	v.add_child(r1)
	v.add_child(_grow(PorterUI.button("Align: tap 2 points", func():
		if canvas.texture == null:
			_say("Load a photo for this view first.")
			return
		canvas.start_align())))

	v.add_child(UIKit.label("Finger moves:", 22, UIKit.DIM))
	var r2 := HBoxContainer.new()
	mode_buttons.clear()
	mode_buttons["photo"] = _grow(PorterUI.toggle("Photo", true, func(on): _mode_toggled(on, BlueprintCanvas.Mode.PHOTO)))
	mode_buttons["view"] = _grow(PorterUI.toggle("View", false, func(on): _mode_toggled(on, BlueprintCanvas.Mode.VIEW)))
	r2.add_child(mode_buttons["photo"]); r2.add_child(mode_buttons["view"])
	v.add_child(r2)

	v.add_child(UIKit.label("Fine adjust:", 22, UIKit.DIM))
	var g := GridContainer.new()
	g.columns = 4
	for spec in [["◀", func(): canvas.nudge_move(-2, 0)], ["▶", func(): canvas.nudge_move(2, 0)],
			["▲", func(): canvas.nudge_move(0, -2)], ["▼", func(): canvas.nudge_move(0, 2)],
			["−", func(): canvas.nudge_scale(1.0 / 1.005)], ["+", func(): canvas.nudge_scale(1.005)],
			["⟲", func(): canvas.nudge_rotate(0.2)], ["⟳", func(): canvas.nudge_rotate(-0.2)]]:
		g.add_child(_grow(PorterUI.button(spec[0], spec[1], 110)))
	v.add_child(g)
	var oh := HBoxContainer.new()
	oh.add_child(UIKit.label("Opacity", 22, UIKit.DIM))
	opacity_slider = HSlider.new()
	opacity_slider.min_value = 0.15; opacity_slider.max_value = 1.0; opacity_slider.step = 0.05
	opacity_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opacity_slider.custom_minimum_size = Vector2(0, 56)
	opacity_slider.value_changed.connect(func(x):
		project.views[current_view]["opacity"] = x
		canvas.queue_redraw(); _queue_save())
	oh.add_child(opacity_slider)
	v.add_child(oh)

	v.add_child(HSeparator.new())
	var dh := HBoxContainer.new()
	var dl := UIKit.label("REAL DIMENSIONS", 24, UIKit.ACCENT)
	dl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dh.add_child(dl)
	dh.add_child(PorterUI.button("in / mm", func():
		project.units = "metric" if project.units == "imperial" else "imperial"
		_refresh_dims(); canvas.queue_redraw(); _queue_save()))
	v.add_child(dh)
	dim_edits.clear()
	for f in DIM_FIELDS:
		var row := HBoxContainer.new()
		var l := UIKit.label(f[1], 24)
		l.custom_minimum_size = Vector2(250, 0)
		row.add_child(l)
		var e := LineEdit.new()
		e.custom_minimum_size = Vector2(0, 64)
		e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		e.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER_DECIMAL
		e.select_all_on_focus = true
		var key: String = f[0]
		e.text_submitted.connect(func(_t): _commit_dim(key))
		e.focus_exited.connect(func(): _commit_dim(key))
		row.add_child(e)
		var u := UIKit.label("", 22, UIKit.DIM)
		u.custom_minimum_size = Vector2(44, 0)
		row.add_child(u)
		dim_edits[key] = [e, u]
		v.add_child(row)
	v.add_child(HSeparator.new())
	var tf := TireForm.new()
	v.add_child(tf)
	tf.set_values(project.tires)
	var apply_t := _grow(PorterUI.button("Apply tires", func():
		var tv := tf.values()
		var err := project.set_tires(tv[0], tv[1], tv[2], tv[3])
		if err != "":
			_say(err)
			return
		project.save()
		canvas.queue_redraw()
		if preview.visible:
			preview.rebuild()
		_say("Tires updated: %s front, %s rear." % [project.tires["front"], project.tires["rear"]])))
	v.add_child(apply_t)
	if project.source_db != "":
		v.add_child(UIKit.label("Dimensions from the production car database: %s." % project.source_db, 20, UIKit.DIM))
		v.get_child(v.get_child_count() - 1).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	elif project.source_car != "":
		v.add_child(UIKit.label("Copied from the game's %s data. Front overhang is an estimate: check it against the side photo." % project.source_car, 20, UIKit.DIM))
		v.get_child(v.get_child_count() - 1).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_refresh_dims()
	return panel

func _grow(c: Control) -> Control:
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c

func _refresh_dims() -> void:
	for key in dim_edits:
		dim_edits[key][0].text = PorterUI.value_in_units(project.dims[key], project.units)
		dim_edits[key][1].text = PorterUI.unit_suffix(project.units)

func _commit_dim(key: String) -> void:
	var e: LineEdit = dim_edits[key][0]
	var m := PorterUI.parse_len(e.text, project.units)
	if m > 0.0 and m < 30.0:
		if absf(m - float(project.dims[key])) > 0.0004:
			project.dims[key] = m
			_queue_save()
			canvas.queue_redraw()
			if preview.visible:
				preview.rebuild()
	else:
		_say("Couldn't read that number.")
	e.text = PorterUI.value_in_units(project.dims[key], project.units)

func _mode_toggled(on: bool, m: int) -> void:
	if on:
		_set_mode(m)
	else:
		_set_mode(canvas.mode)   # keep one button lit

func _set_mode(m: int) -> void:
	canvas.mode = m
	mode_buttons["photo"].set_pressed_no_signal(m == BlueprintCanvas.Mode.PHOTO)
	mode_buttons["view"].set_pressed_no_signal(m == BlueprintCanvas.Mode.VIEW)
	_say("")

func _select_view(v: String) -> void:
	if v == "3d":
		project.save()
		canvas.visible = false
		preview.visible = true
		preview.show_project(project)
		current_view = current_view if current_view != "3d" else "side"
		_say("3D check: each photo sits on its own side of a true-size box. Drag to orbit, pinch to zoom.")
		_refresh_tabs(true)
		return
	current_view = v
	preview.visible = false
	canvas.visible = true
	canvas.set_view(project, v)
	opacity_slider.set_value_no_signal(project.views[v]["opacity"])
	_set_mode(BlueprintCanvas.Mode.PHOTO)
	if canvas.texture == null:
		_say("No %s photo yet. Tap “Load photo…”. A straight-on shot with little perspective works best." % PorterProject.VIEW_LABELS[v].to_lower())
	_refresh_tabs()

func _refresh_tabs(three_d: bool = false) -> void:
	for v in PorterProject.VIEWS:
		var has: bool = project.views[v]["file"] != ""
		tabs[v].text = ("✓ " if has else "") + PorterProject.VIEW_LABELS[v]
		tabs[v].add_theme_color_override("font_color", Color.WHITE if (v == current_view and not three_d) else UIKit.DIM)
	tabs["3d"].add_theme_color_override("font_color", Color.WHITE if three_d else UIKit.DIM)

func _on_align_progress(step: int) -> void:
	var tg := project.align_targets(current_view)
	match step:
		0:
			_say("Tap 1 of 2: %s. (Pinch to zoom in for accuracy.)" % tg[0]["label"])
		1:
			_say("Tap 2 of 2: %s." % tg[1]["label"])
		2:
			_say("Aligned. Fine-tune with the arrows if needed.")
			_set_mode(BlueprintCanvas.Mode.PHOTO)
			_queue_save()
		_:
			_say("Those taps were too close together. Try again.")
			_set_mode(BlueprintCanvas.Mode.PHOTO)

func _say(t: String) -> void:
	if prompt:
		prompt.text = t

# --------------------------------------------------------------- photo picking

func _pick_photo() -> void:
	var b := PhotoBrowser.new()
	b.picked.connect(func(path: String):
		if path == "__system_picker__":
			b.queue_free()
			_system_picker()
		else:
			_import_photo_file.call_deferred(path))
	safe.add_child(b)

## Android's own document picker (also reaches cloud drives and USB storage).
func _system_picker() -> void:
	var filters := PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Images"])
	if DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		DisplayServer.file_dialog_show("Choose the %s photo" % PorterProject.VIEW_LABELS[_modeler_photo if _modeler_photo != "" else current_view].to_lower(),
			OS.get_system_dir(OS.SYSTEM_DIR_PICTURES), "", false, DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
			filters, _on_native_pick)
	else:
		if _file_dialog == null:
			_file_dialog = FileDialog.new()
			_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
			_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
			_file_dialog.filters = filters
			_file_dialog.size = Vector2i(1400, 900)
			_file_dialog.file_selected.connect(_import_photo_file)
			add_child(_file_dialog)
		_file_dialog.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_PICTURES)
		_file_dialog.popup_centered()

func _on_native_pick(status: bool, paths: PackedStringArray, _filter: int) -> void:
	if status and paths.size() > 0:
		_import_photo_file.call_deferred(paths[0])
	elif status or paths.is_empty():
		# Godot's picker can't turn some sources (e.g. the Gallery app) into a file path
		_say("No photo loaded. If you picked one, Android's picker couldn't open it from that app: use the thumbnails in “Load photo…”, or pick it under “Images” or “Downloads” in the picker's side menu.")

func _import_photo_file(path: String) -> void:
	if _modeler_photo != "" and modeler and is_instance_valid(modeler):
		var v := _modeler_photo
		_modeler_photo = ""
		var e := project.import_photo(v, path)
		if e != "":
			modeler._say(e + " (" + path.get_file() + ")")
			return
		modeler.on_photo_loaded(v)
		return
	_modeler_photo = ""
	_say("Loading photo…")
	var err := project.import_photo(current_view, path)
	if err != "":
		_say(err + " (" + path.get_file() + ")")
		return
	_select_view(current_view)
	_say("Photo loaded. Now tap “Align: tap 2 points”, or drag and pinch it into the outline.")
