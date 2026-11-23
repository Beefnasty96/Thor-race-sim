extends Node
## Dev tool: run Car Porter with `-- --shots` to capture screenshots of each
## screen using a generated test photo (checks the UI without a phone).

var app: Node
var out_dir := "user://shots/"
var t := 0.0
var step := 0
var browser: Node

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)

func _shot(n: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(out_dir + n + ".png")
	print("saved ", ProjectSettings.globalize_path(out_dir + n + ".png"))

## A crude side-view "photo" of a boxy SUV: body, glass, wheels, ground.
static func fake_side_photo() -> Image:
	var img := Image.create(1800, 820, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.62, 0.7, 0.78))
	img.fill_rect(Rect2i(0, 640, 1800, 180), Color(0.35, 0.36, 0.35))
	img.fill_rect(Rect2i(170, 330, 1460, 250), Color(0.55, 0.06, 0.06))       # body
	img.fill_rect(Rect2i(560, 150, 1050, 190), Color(0.55, 0.06, 0.06))       # cab/roof
	img.fill_rect(Rect2i(600, 175, 300, 140), Color(0.15, 0.2, 0.28))         # windows
	img.fill_rect(Rect2i(930, 175, 300, 140), Color(0.15, 0.2, 0.28))
	img.fill_rect(Rect2i(1260, 175, 320, 140), Color(0.15, 0.2, 0.28))
	for cx in [470, 1350]:
		for y in range(440, 650):
			for x in range(cx - 110, cx + 110):
				var d := Vector2(x - cx, y - 540).length()
				if d < 105:
					img.set_pixel(x, y, Color(0.08, 0.08, 0.08) if d > 60 else Color(0.7, 0.7, 0.72))
	return img

## Front view of the same fake SUV: body, windshield, grille, headlights, tires.
static func fake_front_photo() -> Image:
	var img := Image.create(1200, 900, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.62, 0.7, 0.78))
	img.fill_rect(Rect2i(0, 760, 1200, 140), Color(0.35, 0.36, 0.35))
	img.fill_rect(Rect2i(210, 380, 780, 330), Color(0.55, 0.06, 0.06))      # body
	img.fill_rect(Rect2i(260, 170, 680, 220), Color(0.5, 0.05, 0.05))       # cab
	img.fill_rect(Rect2i(290, 195, 620, 170), Color(0.15, 0.2, 0.28))       # windshield
	img.fill_rect(Rect2i(330, 480, 540, 120), Color(0.06, 0.06, 0.07))      # grille
	img.fill_rect(Rect2i(235, 480, 90, 120), Color(0.92, 0.93, 0.95))       # headlights
	img.fill_rect(Rect2i(875, 480, 90, 120), Color(0.92, 0.93, 0.95))
	img.fill_rect(Rect2i(230, 640, 740, 50), Color(0.8, 0.8, 0.82))         # bumper
	img.fill_rect(Rect2i(250, 690, 120, 80), Color(0.08, 0.08, 0.08))       # tires
	img.fill_rect(Rect2i(830, 690, 120, 80), Color(0.08, 0.08, 0.08))
	return img

## The dash seen from the driver's seat: dark dash, gauge cluster on the left.
static func fake_dash_photo() -> Image:
	var img := Image.create(1600, 700, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.6, 0.66, 0.72))                                            # windshield / sky
	img.fill_rect(Rect2i(0, 150, 1600, 550), Color(0.16, 0.16, 0.17))           # dash face
	img.fill_rect(Rect2i(0, 130, 1600, 40), Color(0.09, 0.09, 0.1))             # top pad
	img.fill_rect(Rect2i(250, 200, 560, 340), Color(0.05, 0.05, 0.06))          # cluster
	img.fill_rect(Rect2i(1000, 260, 260, 170), Color(0.1, 0.1, 0.11))           # radio
	img.fill_rect(Rect2i(1040, 300, 180, 40), Color(0.2, 0.6, 0.3))
	img.fill_rect(Rect2i(1300, 250, 160, 60), Color(0.08, 0.08, 0.09))          # vent
	for g in [[420, 300, 90], [640, 300, 90], [330, 470, 38], [730, 470, 38]]:
		for y in range(g[1] - g[2], g[1] + g[2]):
			for x in range(g[0] - g[2], g[0] + g[2]):
				var d := Vector2(x - g[0], y - g[1]).length()
				if d < g[2] and d > g[2] - 5:
					img.set_pixel(x, y, Color(0.9, 0.9, 0.92))
	return img

## Inside of the driver's door, seen from the passenger seat (forward = right).
static func fake_door_photo() -> Image:
	var img := Image.create(1400, 800, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.42, 0.33, 0.24))                                          # tan door card
	img.fill_rect(Rect2i(0, 0, 1400, 230), Color(0.62, 0.68, 0.74))            # window
	img.fill_rect(Rect2i(0, 230, 1400, 30), Color(0.15, 0.13, 0.12))           # sill
	img.fill_rect(Rect2i(150, 420, 900, 60), Color(0.3, 0.23, 0.17))           # armrest
	img.fill_rect(Rect2i(1050, 330, 140, 50), Color(0.75, 0.75, 0.78))         # handle
	for y in range(560, 740):
		for x in range(250, 430):
			if Vector2(x - 340, y - 650).length() < 85:
				img.set_pixel(x, y, Color(0.08, 0.08, 0.08))                    # speaker
	return img

## Headliner from below: grey cloth, dome light in the middle.
static func fake_ceiling_photo() -> Image:
	var img := Image.create(1000, 1400, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.68, 0.67, 0.64))
	img.fill_rect(Rect2i(420, 640, 160, 120), Color(0.95, 0.93, 0.8))         # dome light
	img.fill_rect(Rect2i(0, 0, 1000, 60), Color(0.2, 0.2, 0.22))              # front edge
	return img

## A three-spoke steering wheel, face-on.
## Looking down into a bed: ribbed black liner, wheel-well humps.
static func fake_bed_floor_photo() -> Image:
	var img := Image.create(900, 1100, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.35, 0.36, 0.38))
	img.fill_rect(Rect2i(60, 40, 780, 1020), Color(0.09, 0.09, 0.1))
	for x in range(110, 820, 70):
		img.fill_rect(Rect2i(x, 40, 22, 1020), Color(0.16, 0.16, 0.17))
	for side in [60, 700]:
		img.fill_rect(Rect2i(side, 560, 140, 330), Color(0.13, 0.13, 0.14))
	return img

## A bed wall from across the bed: liner below a body-colored rail.
static func fake_bed_side_photo() -> Image:
	var img := Image.create(1200, 500, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.55, 0.6, 0.65))
	img.fill_rect(Rect2i(40, 80, 1120, 40), Color(0.15, 0.2, 0.42))
	img.fill_rect(Rect2i(40, 120, 1120, 330), Color(0.1, 0.1, 0.11))
	for x in range(80, 1150, 90):
		img.fill_rect(Rect2i(x - 8, 140, 16, 16), Color(0.25, 0.25, 0.26))
	img.fill_rect(Rect2i(560, 300, 380, 150), Color(0.14, 0.14, 0.15))
	return img

static func fake_steering_photo() -> Image:
	var img := Image.create(800, 800, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.3, 0.3, 0.32))
	var c := Vector2(400, 400)
	for y in 800:
		for x in 800:
			var q := Vector2(x, y) - c
			var d := q.length()
			var col := Color(0.3, 0.3, 0.32)
			if d < 330 and d > 280:
				col = Color(0.1, 0.09, 0.08)                                    # rim
			elif d <= 95:
				col = Color(0.35, 0.35, 0.38)                                   # hub
				if d < 30:
					col = Color(0.85, 0.7, 0.2)                                 # logo
			elif d <= 280:
				var spoke: bool = (absf(q.y + 10) < 40 and absf(q.x) > 60) or (q.y > 0 and absf(q.x) < 45)
				col = Color(0.32, 0.32, 0.34) if spoke else Color(0.55, 0.62, 0.7)  # spokes / gaps
			img.set_pixel(x, y, col)
	return img

func _tap(v: Control, p: Vector2) -> void:
	var t := InputEventScreenTouch.new(); t.index = 0; t.position = p; t.pressed = true
	v._gui_input(t)
	var u := InputEventScreenTouch.new(); u.index = 0; u.position = p; u.pressed = false
	v._gui_input(u)

func _process(delta: float) -> void:
	t += delta
	if t < 1.0:
		return
	t = 0.0
	match step:
		0:
			_shot("porter_01_projects")
		1:
			var def: Dictionary = Game.cars["chevrolet_tahoe_1999"]
			var p := PorterProject.create("Screenshot Tahoe")
			p.fill_from_car(def, "4door")
			p.import_image("side", fake_side_photo())
			# wheel centres in the fake photo are at (470,540) and (1350,540)
			p.align_two_points("side", Vector2(470, 540), Vector2(1350, 540), Vector2(1800, 820))
			p.import_image("rear", fake_front_photo())
			p.align_two_points("rear", Vector2(310, 770), Vector2(890, 770), Vector2(1200, 900))
			p.save()
			app._open(p)
		2:
			_shot("porter_02_side_aligned")
			app.canvas.start_align()
		3:
			_shot("porter_03_align_prompt")
			app._select_view("front")
		4:
			_shot("porter_04_front_empty")
			# photo browser over a folder of generated photos
			var dir := OS.get_user_data_dir().path_join("shots_photos")
			DirAccess.make_dir_recursive_absolute(dir)
			for i in 9:
				var im := fake_side_photo()
				im.adjust_bcs(1.0 - i * 0.05, 1.0, 1.0)
				im.save_jpg(dir.path_join("IMG_%04d.jpg" % i), 0.8)
			var b := PhotoBrowser.new()
			b.folders = [dir]
			b.picked.connect(func(path): app._import_photo_file(path))
			app.safe.add_child(b)
			browser = b
		5:
			_shot("porter_04b_photo_browser")
			var first: TextureButton = browser.grid.get_child(0)
			first.pressed.emit()
		6:
			_shot("porter_04c_front_loaded")
			app._select_view("3d")
		7:
			_shot("porter_05_3d_check")
			app.show_modeler()
		8:
			_shot("porter_06_template_picker")
			# pick the SUV template (first button in the picker grid)
			var picker: Control = app.modeler._picker
			var grid := picker.find_children("*", "GridContainer", true, false)[0] as GridContainer
			(grid.get_child(0) as Button).pressed.emit()
		9:
			_shot("porter_07_model_side")
			var mv: ModelView = app.modeler.view
			# select the four points of a side window region and show them selected
			for i in mv.mesh.verts.size():
				var v: Vector3 = mv.mesh.verts[i]
				if v.y > app.project.dims["height_m"] * 0.9 and not mv.mesh.is_center(i):
					mv.sel_verts[i] = true
			mv.overlay.queue_redraw()
		10:
			_shot("porter_08_model_selected")
			# simulate a finger dragging one selected roof point 60 px up
			var mv2: ModelView = app.modeler.view
			var id: int = mv2.sel_verts.keys()[0]
			var before: Vector3 = mv2.mesh.verts[id]
			var s0 := mv2.project_point(before)
			var t := InputEventScreenTouch.new(); t.index = 0; t.position = s0; t.pressed = true
			mv2._gui_input(t)
			for k in 6:
				var dr := InputEventScreenDrag.new(); dr.index = 0; dr.position = s0 + Vector2(0, -10 * (k + 1))
				mv2._gui_input(dr)
			var up := InputEventScreenTouch.new(); up.index = 0; up.position = s0 + Vector2(0, -60); up.pressed = false
			mv2._gui_input(up)
			var after: Vector3 = mv2.mesh.verts[id]
			print("DRAG TEST: moved %.3f m up, %.4f m sideways, %.4f m along (expected up only)" % [after.y - before.y, absf(after.x - before.x), absf(after.z - before.z)])
			# a tap on empty space clears the selection
			var t2 := InputEventScreenTouch.new(); t2.index = 0; t2.position = Vector2(30, mv2.size.y - 30); t2.pressed = true
			mv2._gui_input(t2)
			t2 = t2.duplicate(); t2.pressed = false
			mv2._gui_input(t2)
			print("TAP TEST: selection after tapping empty space = %d" % mv2.sel_verts.size())
			print("UNDO TEST: ", mv2.mesh.undo(), " back to %.3f" % (mv2.mesh.verts[id].y - before.y))
			app.modeler._select_view("front")
		11:
			_shot("porter_09_model_front")
			app.modeler._select_view("3d")
		12:
			_shot("porter_10_model_3d")
			app.modeler._set_mode("paint", true)
		13:
			_shot("porter_11_paint_3d")
			app.modeler._select_view("side")
		14:
			_shot("porter_12_paint_side")
			app.modeler._select_view("3d")
			app.modeler._photos_on(["paint", "second", "grille", "glass"])
			app.modeler.view.yaw = deg_to_rad(-120.0)
			app.modeler.view._update_cam()
			app.modeler.view.overlay.queue_redraw()
		15:
			_shot("porter_13_photo_textures")
			app.modeler.view.yaw = deg_to_rad(-30.0)
			app.modeler.view._update_cam()
			app.modeler.view.overlay.queue_redraw()
		16:
			_shot("porter_14_photo_textures_rear")
			var mdp: PorterModeler = app.modeler
			mdp._select_view("side")
			mdp.window_btn.button_pressed = true
		17:
			# cut the three side windows of the fake photo by tapping their corners
			var mdp2: PorterModeler = app.modeler
			var szw := Vector2(1800, 820)
			var nwin := 0
			for rect in [Rect2(600, 175, 300, 140), Rect2(930, 175, 300, 140), Rect2(1260, 175, 320, 140)]:
				for c in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
					var f: Vector2 = app.project.image_to_frame("side", c, szw)
					var mid3: float = app.project.front_axle_x() + app.project.dims["wheelbase_m"] * 0.5
					_tap(mdp2.view, mdp2.view.project_point(Vector3(-5, f.y, f.x - mid3)))
				mdp2._finish_window()
				print("WINDOW TEST msg: ", mdp2.hint.text.left(90))
				if mdp2.hint.text.begins_with("Window cut"):
					nwin += 1
			print("WINDOW TEST: %d windows cut, glass faces %d" % [nwin, mdp2.mesh.regions.count("glass")])
			mdp2._toggle_cut_window(false)
			mdp2._select_view("3d")
			mdp2.view.yaw = deg_to_rad(-110.0)
			mdp2.view.pitch = deg_to_rad(12.0)
			mdp2.view._update_cam()
			mdp2.view.overlay.queue_redraw()
		18:
			_shot("porter_14b_windows_outside")
			# recolour photo paint: pick the red on the side photo
			var mr: PorterModeler = app.modeler
			mr._select_view("side")
			mr._toggle_pick_paint(true)
			var fp: Vector2 = app.project.image_to_frame("side", Vector2(1000, 470), Vector2(1800, 820))
			var midp: float = app.project.front_axle_x() + app.project.dims["wheelbase_m"] * 0.5
			_tap(mr.view, mr.view.project_point(Vector3(-5, fp.y, fp.x - midp)))
			print("PAINT TEST: key ", app.project.paint_key, " grey ", PaintKey.is_grey(app.project.paint_key_color()), " msg ", mr.hint.text.left(60))
			mr._select_view("3d")
			mr.view.yaw = deg_to_rad(-110.0)
			mr.view.pitch = deg_to_rad(12.0)
			mr.view._update_cam()
			mr.view.overlay.queue_redraw()
		19:
			_shot("porter_14d_paint_match")
			var mr2: PorterModeler = app.modeler
			mr2._set_preview_paint({"name": "Blue", "color": [0.1, 0.22, 0.6]})
			mr2.recolor_btn.button_pressed = true
		20:
			_shot("porter_14e_recolor_blue")
			var mr3: PorterModeler = app.modeler
			var sc5: ScrollContainer = mr3.paint_panel.get_child(0)
			sc5.scroll_vertical = int(mr3.mask_editor.position.y) - 260
			mr3.match_btn.button_pressed = true
			# brush "Not paint" across the middle of the side photo (a stripe / sticker)
			var me: PaintMaskEditor = mr3.mask_editor
			var y0: float = me.size.y * 0.55
			var tch := InputEventScreenTouch.new(); tch.index = 0; tch.position = Vector2(me.size.x * 0.25, y0); tch.pressed = true
			me._gui_input(tch)
			for k in 12:
				var dr := InputEventScreenDrag.new(); dr.index = 0; dr.position = Vector2(me.size.x * (0.25 + 0.04 * (k + 1)), y0)
				me._gui_input(dr)
			var up := InputEventScreenTouch.new(); up.index = 0; up.position = Vector2(me.size.x * 0.73, y0); up.pressed = false
			me._gui_input(up)
			var mk: Image = app.project.load_paint_mask("side")
			print("PAINT TEST: touch-up saved %s" % str(mk != null))
		21:
			_shot("porter_14f_touchup")
			var mr4: PorterModeler = app.modeler
			mr4.match_btn.button_pressed = false
			mr4.recolor_btn.button_pressed = false
			mr4._driver_view(true)
			mr4.view.yaw = deg_to_rad(-140.0 + 55.0)
			mr4.view._update_cam()
		22:
			_shot("porter_14c_driver_seat")
			app.modeler._driver_view(false)
			# Add point + Connect, driven by simulated taps in the side view
			var md: PorterModeler = app.modeler
			md._set_mode("shape", true)
			md._select_view("side")
		23:
			var md2: PorterModeler = app.modeler
			var mv3: ModelView = md2.view
			md2.add_btn.button_pressed = true
			var nv := mv3.mesh.verts.size()
			# a long roof edge: tap its middle
			var e := Vector2i(-1, -1)
			for edge in mv3.mesh.edges():
				var pa: Vector3 = mv3.mesh.verts[edge.x]
				var pb: Vector3 = mv3.mesh.verts[edge.y]
				if not mv3.mesh.is_center(edge.x) and not mv3.mesh.is_center(edge.y) and absf(pa.z - pb.z) > 2.0 and pa.y > 1.5:
					e = edge
			var mid := (mv3.project_point(mv3.mesh.verts[e.x]) + mv3.project_point(mv3.mesh.verts[e.y])) * 0.5
			_tap(mv3, mid)
			_tap(mv3, mid + Vector2(0, -90))          # free point above the roof
			_tap(mv3, mid + Vector2(160, -90))        # another
			print("ADD TEST: points %d -> %d, selected %d" % [nv, mv3.mesh.verts.size(), mv3.sel_verts.size()])
			_shot("porter_16_add_points")
		24:
			var md3: PorterModeler = app.modeler
			var nf := md3.mesh.faces.size()
			md3._connect()
			print("CONNECT TEST: faces %d -> %d, message: %s" % [nf, md3.mesh.faces.size(), md3.hint.text])
		25:
			_shot("porter_17_connected")
			var mdw: PorterModeler = app.modeler
			mdw.mesh.undo()
			# draw a squared front arch by tapping the side view, auto-cut the rear
			mdw.arch_btn.button_pressed = true
			var mvw: ModelView = mdw.view
			var fz: float = -app.project.dims["wheelbase_m"] * 0.5
			var xs: float = -app.project.dims["width_m"] * 0.5
			for zy in [Vector2(fz - 0.5, 0.35), Vector2(fz - 0.38, 0.9), Vector2(fz + 0.38, 0.9), Vector2(fz + 0.52, 0.35)]:
				_tap(mvw, mvw.project_point(Vector3(xs, zy.y, zy.x)))
			print("ARCH TEST: %d points drawn" % mvw.arch_pts.size())
		26:
			_shot("porter_17a_drawing_arch")
			var mdw: PorterModeler = app.modeler
			mdw._finish_arch()
			mdw._cut_arches()
			print("ARCH TEST: ", mdw.hint.text)
			mdw._select_view("side")
		27:
			_shot("porter_17b_arches_side")
			app.modeler._set_mode("wheels", true)
		28:
			_shot("porter_17c_wheels")
			app.modeler.view.yaw = deg_to_rad(-75.0)
			app.modeler.view.pitch = deg_to_rad(8.0)
			app.modeler.view._update_cam()
			app.modeler.view.overlay.queue_redraw()
		29:
			_shot("porter_17d_wheels_low")
			var mvl: ModelView = app.modeler.view
			mvl.yaw = deg_to_rad(-118.0)
			mvl.pitch = deg_to_rad(-14.0)
			mvl.dist = 3.3
			mvl._update_cam()
			mvl.overlay.queue_redraw()
			await get_tree().process_frame
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			_shot("porter_17e_wheel_well_close")
			# interior: dash template, dash + steering photos
			var mdi: PorterModeler = app.modeler
			mdi._set_mode("interior", true)
			mdi._new_dash("truck")
			app.project.import_image("dash", fake_dash_photo())
			mdi.on_photo_loaded("dash")
			app.project.import_image("steering", fake_steering_photo())
			mdi.on_photo_loaded("steering")
		30:
			var mdi2: PorterModeler = app.modeler
			var pj: PorterProject = app.project
			var dsz := Vector2(1600, 700)
			for gp in [["speedo", Vector2(420, 300)], ["tach", Vector2(640, 300)], ["fuel", Vector2(330, 470)], ["temp", Vector2(730, 470)]]:
				mdi2._pick_gauge_type(gp[0], true)
				mdi2._on_gauge_tap(pj.image_to_frame("dash", gp[1], dsz), -1)
			mdi2._stop_placing()
			var gs: Array = pj.interior["gauges"]
			gs[0]["r"] = 0.085
			gs[1]["r"] = 0.085
			gs[2]["r"] = 0.035
			gs[3]["r"] = 0.035
			# three gaps between the spokes of the fake wheel
			mdi2._toggle_hole(true)
			for poly in [[Vector2(-0.78, -0.12), Vector2(-0.6, -0.5), Vector2(0.0, -0.8), Vector2(0.6, -0.5), Vector2(0.78, -0.12), Vector2(0.0, -0.3)],
					[Vector2(-0.8, 0.12), Vector2(-0.3, 0.2), Vector2(-0.12, 0.75), Vector2(-0.55, 0.58)],
					[Vector2(0.8, 0.12), Vector2(0.55, 0.58), Vector2(0.12, 0.75), Vector2(0.3, 0.2)]]:
				mdi2.steer_view.hole_pts = poly.duplicate()
				mdi2._finish_hole()
			mdi2._toggle_hole(false)
			print("INTERIOR TEST: gauges %d (on dash %s), holes %d, msg: %s" % [gs.size(), str(gs.map(func(g): return g["on_dash"])), pj.steering()["holes"].size(), mdi2.hint.text])
		31:
			_shot("porter_22_driver_seat")
			app.modeler._hide_wheel(true)
			app.modeler.dash_view.stretch(1.08, 0.94)
			print("STRETCH TEST: dash sx %.3f sy %.3f" % [app.project.views["dash"]["sx"], app.project.views["dash"]["sy"]])
			var sc: ScrollContainer = app.modeler.interior_panel.get_child(0)
			sc.scroll_vertical = int(app.modeler.dash_view.position.y) - 40
		32:
			_shot("porter_23_dash_photo_gauges")
			var has_wheel := false
			for c in app.modeler.view.cabin.get_children():
				if c.name == "SteeringWheel" and not c.is_queued_for_deletion():
					has_wheel = true
			print("WHEEL TOGGLE: wheel shown while hidden = %s" % str(has_wheel))
			app.modeler._hide_wheel(false)
			var sc2: ScrollContainer = app.modeler.interior_panel.get_child(0)
			sc2.scroll_vertical = int(app.modeler.steer_view.position.y) - 60
		33:
			_shot("porter_24_steering_holes")
			# inside panels: door + ceiling photos, Auto paint, look toward the driver's door
			var mdp: PorterModeler = app.modeler
			app.project.import_image("door", fake_door_photo())
			mdp.on_photo_loaded("door")
			app.project.import_image("ceiling", fake_ceiling_photo())
			mdp.on_photo_loaded("ceiling")
			mdp._auto_inside()
			mdp._hide_wheel(true)
			mdp.view.yaw = deg_to_rad(-140.0 + 70.0)
			mdp.view.pitch = deg_to_rad(10.0)
			mdp.view._update_cam()
			var cnt := {}
			for fi in mdp.mesh.faces.size():
				var ir := mdp.mesh.inner_region_of(fi)
				cnt[ir] = cnt.get(ir, 0) + 1
			print("INSIDE TEST: ", cnt, " surfaces ", mdp.view.interior_mi.mesh.get_surface_count() if mdp.view.interior_mi.mesh else 0)
		34:
			_shot("porter_24b_inside_door")
			var mdp2: PorterModeler = app.modeler
			mdp2.view.yaw = deg_to_rad(-140.0 + 30.0)
			mdp2.view.pitch = deg_to_rad(70.0)
			mdp2.view._update_cam()
			var sc3: ScrollContainer = mdp2.interior_panel.get_child(0)
			sc3.scroll_vertical = int(mdp2.inside_photo_view.position.y) - 120
		35:
			_shot("porter_24c_inside_ceiling_panel")
			app.modeler._hide_wheel(false)
			app.modeler._start_edit_dash()
		36:
			_shot("porter_25_edit_dash")
			# from the driver's seat: tap the top-rear corner of the dash at the door, drag it up
			var mde: PorterModeler = app.modeler
			var mv: ModelView = mde.view
			var best := -1
			var best_d := INF
			for i in mv.mesh.verts.size():
				var q := mv.mesh.verts[i]
				var score := absf(q.x + 0.45) + absf(q.y - 1.05) * 2.0 + absf(q.z + 0.98)
				if score < best_d:
					best_d = score
					best = i
			var before := mv.mesh.verts[best]
			var sp := mv.project_point(before)
			_tap(mv, sp)
			var tch := InputEventScreenTouch.new(); tch.index = 0; tch.position = sp; tch.pressed = true
			mv._gui_input(tch)
			for k in 6:
				var dr := InputEventScreenDrag.new(); dr.index = 0; dr.position = sp + Vector2(0, -12.0 * (k + 1))
				mv._gui_input(dr)
			var up := InputEventScreenTouch.new(); up.index = 0; up.position = sp + Vector2(0, -72); up.pressed = false
			mv._gui_input(up)
			print("SEAT EDIT: cabin editing %s, selected %d, moved %.3f m up, %.3f m sideways" % [str(mv.cabin_editing()), mv.sel_verts.size(), mv.mesh.verts[best].y - before.y, absf(mv.mesh.verts[best].x - before.x)])
		37:
			_shot("porter_25b_edit_dash_seat_moved")
			app.modeler._end_edit_dash()
			app.modeler._set_mode("shape", true)
			var p2: PorterProject = app.project
			for f in DirAccess.get_files_at(p2.dir()):
				DirAccess.remove_absolute(p2.dir() + f)
			DirAccess.remove_absolute(p2.dir())
			app.show_finder()
		38:
			var fd: CarFinder = app.screen.get_child(0)
			fd._pick_year(1999)
			fd._pick_make("Chevrolet")
			fd.search.text = "tahoe 4dr"
			fd._fill_models()
		39:
			var fd2: CarFinder = app.screen.get_child(0)
			var r: Dictionary = VehicleDB.models(1999, "Chevrolet", "tahoe k1500 4dr")[0]
			fd2._pick_model(r)
			fd2.tire_form.front_size.text = "P245/75R16"
			fd2.tire_form.front_psi.text = "35"
			fd2.tire_form._update()
		40:
			_shot("porter_18_car_finder")
			var fd3: CarFinder = app.screen.get_child(0)
			fd3.create_btn.pressed.emit()
		41:
			_shot("porter_19_from_database")
			print("DB PROJECT: %s  L %.3f  WB %.3f  overhang %.3f  tires %s/%s @ %d psi, radius %.3f" % [app.project.name, app.project.dims["length_m"], app.project.dims["wheelbase_m"], app.project.dims["front_overhang_m"], app.project.tires["front"], app.project.tires["rear"], app.project.tires["front_psi"], app.project.dims["tire_radius_m"]])
			var p3: PorterProject = app.project
			for f in DirAccess.get_files_at(p3.dir()):
				DirAccess.remove_absolute(p3.dir() + f)
			DirAccess.remove_absolute(p3.dir())
			app.show_tire_step("My new car", {}, func(_p): pass)
		42:
			_shot("porter_20_tire_step_empty")
			var form: TireForm = app.screen.find_children("*", "TireForm", true, false)[0]
			form.front_size.text = "245/40ZR18"
			form.rear_size.text = "285/35zr18"
			form.front_psi.text = "36"
			form._update()
		43:
			_shot("porter_21_tire_step_staggered")
			var pk := PorterProject.create("Screenshot pickup")
			pk.fill_from_car(Game.cars["chevrolet_tahoe_1999"], "4door")
			pk.save()
			app._open(pk)
			app.show_modeler()
		44:
			var mk: PorterModeler = app.modeler
			if mk._picker:
				mk._picker.queue_free()
				mk._picker = null
			mk.mesh.restore(HalfMesh.from_template("pickup", app.project.dims).snapshot())
			mk.mesh.template = "pickup"
			mk._cut_arches()
			mk._hollow_bed()
			print("BED: ", mk.hint.text if mk.hint else "")
			mk._select_view("3d")
			mk.view.yaw = deg_to_rad(-35.0)
			mk.view.pitch = deg_to_rad(38.0)
			mk.view._update_cam()
			var scb: ScrollContainer = mk.shape_panel.get_child(0) if mk.shape_panel.get_child(0) is ScrollContainer else null
			if scb:
				scb.scroll_vertical = 520
		45:
			_shot("porter_26_bed_hollowed")
			var mk2: PorterModeler = app.modeler
			mk2._set_mode("paint", true)
			app.project.import_image("bedfloor", fake_bed_floor_photo())
			mk2.on_photo_loaded("bedfloor")
			app.project.import_image("bedside", fake_bed_side_photo())
			mk2.on_photo_loaded("bedside")
			mk2._pick_bed_view("bedfloor")
			var scp: ScrollContainer = mk2.paint_panel.get_child(0) if mk2.paint_panel.get_child(0) is ScrollContainer else null
			if scp:
				scp.scroll_vertical = int(mk2.bed_photo_view.position.y) - 160
			mk2.view.yaw = deg_to_rad(-25.0)
			mk2.view.pitch = deg_to_rad(55.0)
			mk2.view._update_cam()
		46:
			_shot("porter_27_bed_photos")
			var p4: PorterProject = app.project
			for f in DirAccess.get_files_at(p4.dir()):
				DirAccess.remove_absolute(p4.dir() + f)
			DirAccess.remove_absolute(p4.dir())
			get_tree().quit()
	step += 1
