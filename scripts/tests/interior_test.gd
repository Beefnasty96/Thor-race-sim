extends SceneTree
## Checks the Car Porter interior: dashboard templates, dash photo, gauges,
## steering wheel with cut holes, and saving it all.
##   godot --headless -s res://scripts/tests/interior_test.gd

var fails := 0

func _check(cond: bool, what: String) -> void:
	print(("  ok    " if cond else "  FAIL  ") + what)
	if not cond:
		fails += 1

func _initialize() -> void:
	var def: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/cars/chevrolet_tahoe_1999.json"))
	var p := PorterProject.create("interior test")
	p.fill_from_car(def, "4door")
	var eye := p.driver_eye()
	_check(eye.x < 0.0 and eye.y > 1.0 and eye.y < p.dims["height_m"], "driver's eye is left of center at head height (%.2f, %.2f, %.2f)" % [eye.x, eye.y, eye.z])

	# --- dashboards
	for key in InteriorBuilder.DASH_TEMPLATES:
		var d := InteriorBuilder.dash_from_template(key, p)
		var left := true
		var photo_ok := true
		var photo_n := 0
		for v in d.verts:
			if v.x > 1e-6:
				left = false
		for fi in d.faces.size():
			if d.regions[fi] == "photo:dash":
				photo_n += 1
				if d.face_normal(d.faces[fi]).z < 0.3:
					photo_ok = false
		_check(left and d.faces.size() >= 9, "%s dash: left half only, %d faces" % [key, d.faces.size()])
		_check(photo_n >= 2 and photo_ok, "%s dash: %d photo faces, all looking at the driver" % [key, photo_n])
		var lo := INF
		var hi := -INF
		for v in d.verts:
			lo = minf(lo, v.z)
			hi = maxf(hi, v.z)
		_check(hi < eye.z - 0.4 and hi > eye.z - 0.9, "%s dash sits 40-90 cm ahead of the driver's eye" % key)
		_check(d.build_mesh({}, true).get_surface_count() == 1, "%s dash builds a mirrored mesh" % key)
	var dash := InteriorBuilder.dash_from_template("truck", p)
	var fr := InteriorBuilder.dash_frame(p)
	var zf := InteriorBuilder.dash_z_at(dash, -0.3, float(fr["y_top"]) - 0.15)
	_check(absf(zf - float(fr["z_face"])) < 0.002, "point on the truck dash face finds the face (z %.3f)" % zf)
	_check(is_nan(InteriorBuilder.dash_z_at(dash, -0.3, float(fr["y_top"]) + 0.3)), "point above the dash is off the dash")
	_check(absf(InteriorBuilder.dash_z_at(dash, 0.3, float(fr["y_top"]) - 0.15) - zf) < 1e-4, "the mirrored right side of the dash is found too")
	_check(HalfMesh.region_valid("photo:dash"), "photo:dash is a valid paint region")
	p.save_dash(dash)
	var d2 := p.load_dash()
	_check(d2 != null and d2.faces.size() == dash.faces.size() and d2.regions == dash.regions, "dash saves and loads with its regions")

	# --- dash photo
	var img := Image.create(1200, 600, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.2, 0.2))
	for y in 600:
		for x in 600:
			img.set_pixel(x, y, Color(0.9, 0.1, 0.1))     # left half red, right half grey
	_check(p.import_image("dash", img) == "", "dash photo imports")
	DashPhotoView.fit_to_dash(p, dash, 1200)
	var c_px := p.frame_to_image("dash", Vector2(0.0, float(p.views["dash"]["cy"])), Vector2(1200, 600))
	_check(absf(c_px.x - 600.0) < 0.5, "fitted dash photo is centered on the dash")
	var edge_px := p.frame_to_image("dash", Vector2(-float(fr["hw"]), float(p.views["dash"]["cy"])), Vector2(1200, 600))
	_check(absf(edge_px.x) < 1.0, "fitted dash photo spans the dash width")
	var built := PhotoTexturer.build(dash, p, {}, {"dash": p.load_photo("dash")})
	_check((built[1] as Array) == ["dash"], "dash faces take the dash photo")
	var am: ArrayMesh = built[0]
	var arr := am.surface_get_arrays(1)
	var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var sides_ok := true
	for i in vs.size():
		if vs[i].x < -0.05 and uvs[i].x > 0.5:
			sides_ok = false
		if vs[i].x > 0.05 and uvs[i].x < 0.5:
			sides_ok = false
	_check(sides_ok, "driver's side of the dash samples the left of the photo, passenger side the right")

	# --- gauges
	var g := InteriorBuilder.make_gauge("speedo", -0.37, float(fr["y_top"]) - 0.12, dash)
	_check(g["on_dash"] and absf(float(g["z"]) - float(fr["z_face"])) < 0.002 and g["max"] == 100.0, "speedo lands on the dash face")
	var g_off := InteriorBuilder.make_gauge("fuel", -0.37, float(fr["y_top"]) + 0.4, dash)
	_check(not g_off["on_dash"], "a gauge tapped above the dash is flagged off the dash")
	_check(is_equal_approx(InteriorBuilder.needle_angle(0.0), -deg_to_rad(120.0)) and is_equal_approx(InteriorBuilder.needle_angle(1.0), deg_to_rad(120.0)), "needles sweep 240° centered on straight up")
	p.interior["gauges"] = [g]

	# --- steering wheel
	var full := InteriorBuilder.face_area([])
	_check(absf(full - PI) < 0.04, "uncut wheel face is the unit circle (%.3f)" % full)
	var hole := [[-0.5, -0.6], [0.5, -0.6], [0.5, -0.2], [-0.5, -0.2]]      # inside, above the hub
	var a1 := InteriorBuilder.face_area([hole])
	_check(absf((full - a1) - 0.4) < 0.002, "a hole inside the wheel removes its own area (%.3f)" % (full - a1))
	var pieces: Array = InteriorBuilder.steering_pieces([hole])[0]
	var simple := true
	for poly in pieces:
		if Geometry2D.triangulate_polygon(poly).is_empty():
			simple = false
	_check(pieces.size() >= 2 and simple, "a hole inside one piece splits it into simple polygons (%d)" % pieces.size())
	var hole2 := [[-0.7, 0.15], [-0.15, 0.15], [-0.15, 0.6], [-0.7, 0.45]]
	var hole3 := [[0.15, 0.15], [0.7, 0.15], [0.7, 0.45], [0.15, 0.6]]
	var a3 := InteriorBuilder.face_area([hole, hole2, hole3])
	var h2a := absf(InteriorBuilder._signed(PackedVector2Array([Vector2(-0.7, 0.15), Vector2(-0.15, 0.15), Vector2(-0.15, 0.6), Vector2(-0.7, 0.45)])))
	_check(absf((full - a3) - (0.4 + 2.0 * h2a)) < 0.003, "three spoke gaps remove three holes' worth (%.3f)" % (full - a3))
	var rim_cut := [[0.6, -0.2], [1.3, -0.2], [1.3, 0.2], [0.6, 0.2]]
	var a4 := InteriorBuilder.face_area([rim_cut])
	_check(a4 < full and a4 > full - 0.4 * 0.8, "a hole drawn past the rim just trims the edge")
	var wm := InteriorBuilder.steering_mesh(0.40, 0.03, [hole, hole2, hole3])
	var wv: PackedVector3Array = wm.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var wn: PackedVector3Array = wm.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	var wound := true
	var r_max := 0.0
	for t in range(0, wv.size(), 3):
		if (wv[t + 1] - wv[t]).cross(wv[t + 2] - wv[t]).dot(wn[t]) >= 0.0:
			wound = false
		for k in 3:
			r_max = maxf(r_max, Vector2(wv[t + k].x, wv[t + k].y).length())
	_check(wound, "every steering wheel triangle is a front face for its normal")
	_check(absf(r_max - 0.20) < 1e-4 and absf(wm.get_aabb().size.z - 0.03) < 1e-4, "wheel is 40 cm across and 3 cm thick")
	var walls := 0
	var hole_walls := 0
	for t in range(0, wv.size(), 3):
		if absf(wn[t].z) < 0.01:
			walls += 1
			var ctr := (wv[t] + wv[t + 1] + wv[t + 2]) / 3.0
			if Vector2(ctr.x, ctr.y).length() < 0.19:
				hole_walls += 1
	_check(walls >= 24 * 2 and hole_walls >= 4 * 2 * 3, "rim and hole edges get walls (%d walls, %d around holes)" % [walls, hole_walls])
	var split_walls := 0
	for t in range(0, wv.size(), 3):
		if absf(wn[t].z) < 0.01 and absf(wn[t].y) < 0.01:
			var cx := (wv[t].x + wv[t + 1].x + wv[t + 2].x) / 3.0
			if absf(cx) < 0.001 and absf((wv[t].y + wv[t + 1].y + wv[t + 2].y) / 3.0) < 0.19:
				split_walls += 1
	_check(split_walls == 0, "no walls along the internal split lines")
	var xf := InteriorBuilder.steering_transform(Vector3(0, 1, 0), 22.0)
	var n_face := xf.basis.z
	_check(n_face.z > 0.85 and n_face.y > 0.3, "tilted wheel faces the driver and up (%.2f, %.2f)" % [n_face.y, n_face.z])
	var xf2 := InteriorBuilder.steering_transform(Vector3(0, 1, 0), 22.0, PI * 0.5)
	_check(xf2.basis.z.is_equal_approx(n_face), "turning the wheel spins it about its own axis")

	# steering photo
	var simg := Image.create(800, 800, false, Image.FORMAT_RGBA8)
	simg.fill(Color(0.1, 0.8, 0.1))
	_check(p.import_image("steering", simg) == "", "steering photo imports")
	var crop := p.steering_crop()
	_check(absf(float(crop["cx"]) - 400.0) < 0.5 and absf(float(crop["r"]) - 360.0) < 0.5, "default crop is centered on the photo")
	var tex := p.make_steering_texture()
	_check(tex != null and tex.get_width() == PorterProject.STEERING_TEX_PX and tex.get_pixel(256, 256).g > 0.7, "steering picture is cut from the photo")

	# --- inside panels (paint on the inside of the shell)
	var body := HalfMesh.from_template("suv", p.dims)
	var fi0 := 0
	for fi in body.faces.size():
		if body.regions[fi] == "paint" and body.face_normal(body.faces[fi]).x < -0.6:
			fi0 = fi
			break
	_check(body.inner_region_of(fi0) == "dark", "inside paint defaults to dark plastic")
	body.set_inner_region([fi0], "photo:door")
	_check(body.region_of(fi0) == "paint" and body.inner_region_of(fi0) == "photo:door" and body.regions[fi0] == "paint|photo:door", "inside paint is kept next to the outside paint")
	body.set_region([fi0], "photo:side")
	_check(body.region_of(fi0) == "photo:side" and body.inner_region_of(fi0) == "photo:door", "repainting the outside keeps the inside")
	_check(HalfMesh.region_base(body.regions[fi0]) == "photo" and HalfMesh.inner_base(body.regions[fi0]) == "photo", "region parts read back")
	_check(HalfMesh.region_valid("paint|photo:ceiling") and HalfMesh.region_valid("glass|tan") and not HalfMesh.region_valid("paint|photo:side") and not HalfMesh.region_valid("paint|chrome"), "inside regions validate")
	var loaded := HalfMesh.from_dict(body.to_dict())
	_check(loaded.regions[fi0] == "photo:side|photo:door", "inside paint saves and loads")
	# a window cut through a panel keeps the panel's inside paint on the pieces around it
	var before_n := body.faces.size()
	var zc := body.face_center(body.faces[fi0])
	var win := PackedVector2Array()
	for q in [Vector2(-0.12, -0.08), Vector2(0.12, -0.08), Vector2(0.12, 0.08), Vector2(-0.12, 0.08)]:
		win.append(HalfMesh.view_to2d("side", zc) + q)
	var msg := body.cut_window("side", win)
	var kept := 0
	for fi in body.faces.size():
		if body.inner_region_of(fi) == "photo:door" and HalfMesh.region_base(body.regions[fi]) != "glass":
			kept += 1
	_check(msg == "" and body.faces.size() > before_n and kept >= 2, "window cut: the panel's pieces keep the door photo inside (%d)" % kept)
	_check(body.connected_same_region(fi0, true).size() >= 1, "fill can follow the inside paint")
	# projections of the inside photos
	_check(PhotoTexturer.world_to_frame(p, "door", Vector3(-0.9, 1.0, -0.5)) == Vector2(0.5, 1.0), "door photo: forward is to the right")
	_check(PhotoTexturer.world_to_frame(p, "pillar", Vector3(0.7, 1.4, -1.0)) == PhotoTexturer.world_to_frame(p, "pillar", Vector3(-0.7, 1.4, -1.0)), "both A-pillars use the same photo")
	_check(PhotoTexturer.world_to_frame(p, "ceiling", Vector3(-0.4, 1.8, -0.6)) == Vector2(0.4, 0.6), "ceiling photo: top toward the windshield")
	# build with photos
	var dimg := Image.create(800, 500, false, Image.FORMAT_RGBA8)
	dimg.fill(Color(0.6, 0.3, 0.2))
	_check(p.import_image("door", dimg) == "", "door photo imports")
	DashPhotoView.fit_to_outline(p, "door", DashPhotoView.panel_outline(p, body, "door"), 800)
	_check(absf(float(p.views["door"]["mpp"]) * 800.0 - 1.2) < 1e-6, "door photo starts fitted to the front door (1.2 m), not the whole side")
	var built_in := PhotoTexturer.build_inside(body, p, {}, {"door": p.load_photo("door")})
	_check((built_in[1] as Array) == ["door"] and (built_in[0] as ArrayMesh).get_surface_count() == 2, "inside builds a colour surface and a door-photo surface")
	var tv: PackedVector3Array = (built_in[0] as ArrayMesh).surface_get_arrays(1)[Mesh.ARRAY_VERTEX]
	var tn: PackedVector3Array = (built_in[0] as ArrayMesh).surface_get_arrays(1)[Mesh.ARRAY_NORMAL]
	var faces_in := true
	for t in range(0, tv.size(), 3):
		var ctr := (tv[t] + tv[t + 1] + tv[t + 2]) / 3.0
		if tn[t].dot(Vector3(-ctr.x, 0, 0)) <= 0.0:
			faces_in = false
	_check(faces_in and tv.size() > 0, "door photo faces point into the cabin on both sides")
	var plain_in := body.build_interior(0.02)
	_check(plain_in.get_surface_count() == 1, "plain inside still builds (one colour per face)")
	# auto
	var body2 := HalfMesh.from_template("suv", p.dims)
	var n_auto := InteriorBuilder.auto_inside(body2, {"door": true, "ceiling": false, "pillar": true})
	var got := {}
	for fi in body2.faces.size():
		got[body2.inner_region_of(fi)] = got.get(body2.inner_region_of(fi), 0) + 1
	_check(n_auto > 0 and got.get("photo:door", 0) > 0 and got.get("lining", 0) > 0 and got.get("carpet", 0) > 0, "auto: door photo on the sides, grey cloth roof without a ceiling photo, carpet floor %s" % str(got))
	_check(got.get("photo:pillar", 0) > 0, "auto: the panels beside the windshield get the pillar photo")
	_check(DashPhotoView.panel_outline(p, body2, "door").size() > 0, "the door photo editor has an outline to fit to")

	# --- what export hands the game
	p.interior["gauges"] = [g, InteriorBuilder.make_gauge("speedo", -0.2, float(fr["y_top"]) - 0.12, dash), g_off]
	var mi := p.interior_model_info()
	var cl: Dictionary = mi["cluster"]
	_check(cl.has("speedo") and not cl.has("fuel") and (cl["speedo"]["pos"] as Array)[0] == g["x"], "model info: first speedo only, off-dash gauges left out")
	_check(cl["speedo"]["max"] == 100.0 and cl["speedo"]["r"] == g["r"] and cl["tilt_deg"] == 0, "model info: gauge size and full scale, no extra tilt")
	_check((mi["driver_eye"] as Array).size() == 3 and mi["steering_rake_deg"] == p.steering()["tilt_deg"], "model info: driver's eye and steering rake")
	p.interior["gauges"] = [g]

	# --- save / load
	p.steering()["holes"] = [hole, hole2]
	p.steering()["tilt_deg"] = 30.0
	p.set_driver_eye(eye + Vector3(0, 0.02, 0))
	p.set_steering_center(Vector3(-0.4, 1.1, -0.9))
	p.save()
	var p2 := PorterProject.load_project(p.id)
	_check(p2.steering()["holes"].size() == 2 and float(p2.steering()["tilt_deg"]) == 30.0, "steering holes and tilt survive save/load")
	_check(p2.driver_eye().is_equal_approx(p.driver_eye()) and p2.steering_center().is_equal_approx(Vector3(-0.4, 1.1, -0.9)), "seat and wheel position survive save/load")
	_check((p2.interior["gauges"] as Array).size() == 1 and p2.interior["gauges"][0]["type"] == "speedo", "gauges survive save/load")
	_check(p2.views["dash"]["file"] == "dash.png" and p2.views["steering"]["file"] == "steering.png", "interior photos survive save/load")
	_check(p2.photo_count() == 0, "interior photos don't count toward the 4 blueprint photos")
	var old := PorterProject.new()
	_check(old.steering()["diameter_m"] == 0.40 and old.interior["gauges"].is_empty(), "old projects get default interior settings")

	for f in DirAccess.get_files_at(p.dir()):
		DirAccess.remove_absolute(p.dir() + f)
	DirAccess.remove_absolute(p.dir())
	print("ALL PASSED (0 failed)" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails > 0 else 0)
