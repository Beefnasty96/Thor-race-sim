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

## A three-spoke steering wheel, face-on.
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
			app.modeler._driver_view(true)
			app.modeler.view.yaw = deg_to_rad(-140.0 + 55.0)
			app.modeler.view._update_cam()
		19:
			_shot("porter_14c_driver_seat")
			app.modeler._driver_view(false)
			# Add point + Connect, driven by simulated taps in the side view
			var md: PorterModeler = app.modeler
			md._set_mode("shape", true)
			md._select_view("side")
		20:
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
		21:
			var md3: PorterModeler = app.modeler
			var nf := md3.mesh.faces.size()
			md3._connect()
			print("CONNECT TEST: faces %d -> %d, message: %s" % [nf, md3.mesh.faces.size(), md3.hint.text])
		22:
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
		23:
			_shot("porter_17a_drawing_arch")
			var mdw: PorterModeler = app.modeler
			mdw._finish_arch()
			mdw._cut_arches()
			print("ARCH TEST: ", mdw.hint.text)
			mdw._select_view("side")
		24:
			_shot("porter_17b_arches_side")
			app.modeler._set_mode("wheels", true)
		25:
			_shot("porter_17c_wheels")
			app.modeler.view.yaw = deg_to_rad(-75.0)
			app.modeler.view.pitch = deg_to_rad(8.0)
			app.modeler.view._update_cam()
			app.modeler.view.overlay.queue_redraw()
		26:
			_shot("porter_17d_wheels_low")
			# interior: dash template, dash + steering photos
			var mdi: PorterModeler = app.modeler
			mdi._set_mode("interior", true)
			mdi._new_dash("truck")
			app.project.import_image("dash", fake_dash_photo())
			mdi.on_photo_loaded("dash")
			app.project.import_image("steering", fake_steering_photo())
			mdi.on_photo_loaded("steering")
		27:
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
		28:
			_shot("porter_22_driver_seat")
			var sc: ScrollContainer = app.modeler.interior_panel.get_child(0)
			sc.scroll_vertical = int(app.modeler.dash_view.position.y) - 40
		29:
			_shot("porter_23_dash_photo_gauges")
			var sc2: ScrollContainer = app.modeler.interior_panel.get_child(0)
			sc2.scroll_vertical = int(app.modeler.steer_view.position.y) - 60
		30:
			_shot("porter_24_steering_holes")
			app.modeler._start_edit_dash()
		31:
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
		32:
			_shot("porter_25b_edit_dash_seat_moved")
			app.modeler._end_edit_dash()
			app.modeler._set_mode("shape", true)
			var p2: PorterProject = app.project
			for f in DirAccess.get_files_at(p2.dir()):
				DirAccess.remove_absolute(p2.dir() + f)
			DirAccess.remove_absolute(p2.dir())
			app.show_finder()
		33:
			var fd: CarFinder = app.screen.get_child(0)
			fd._pick_year(1999)
			fd._pick_make("Chevrolet")
			fd.search.text = "tahoe 4dr"
			fd._fill_models()
		34:
			var fd2: CarFinder = app.screen.get_child(0)
			var r: Dictionary = VehicleDB.models(1999, "Chevrolet", "tahoe k1500 4dr")[0]
			fd2._pick_model(r)
			fd2.tire_form.front_size.text = "P245/75R16"
			fd2.tire_form.front_psi.text = "35"
			fd2.tire_form._update()
		35:
			_shot("porter_18_car_finder")
			var fd3: CarFinder = app.screen.get_child(0)
			fd3.create_btn.pressed.emit()
		36:
			_shot("porter_19_from_database")
			print("DB PROJECT: %s  L %.3f  WB %.3f  overhang %.3f  tires %s/%s @ %d psi, radius %.3f" % [app.project.name, app.project.dims["length_m"], app.project.dims["wheelbase_m"], app.project.dims["front_overhang_m"], app.project.tires["front"], app.project.tires["rear"], app.project.tires["front_psi"], app.project.dims["tire_radius_m"]])
			var p3: PorterProject = app.project
			for f in DirAccess.get_files_at(p3.dir()):
				DirAccess.remove_absolute(p3.dir() + f)
			DirAccess.remove_absolute(p3.dir())
			app.show_tire_step("My new car", {}, func(_p): pass)
		37:
			_shot("porter_20_tire_step_empty")
			var form: TireForm = app.screen.find_children("*", "TireForm", true, false)[0]
			form.front_size.text = "245/40ZR18"
			form.rear_size.text = "285/35zr18"
			form.front_psi.text = "36"
			form._update()
		38:
			_shot("porter_21_tire_step_staggered")
			get_tree().quit()
	step += 1
