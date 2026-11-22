extends SceneTree
## Headless checks for Car Porter's body modeling (HalfMesh). Run:
##   godot --headless -s res://scripts/tests/modeler_test.gd

var fails := 0

func _check(cond: bool, what: String) -> void:
	print(("  ok    " if cond else "  FAIL  ") + what)
	if not cond:
		fails += 1

## Every edge of the full mirrored body is shared by exactly two faces, and
## shared edges run in opposite directions (consistent outward winding).
func _closed_and_consistent(m: HalfMesh) -> bool:
	var dirs := {}
	var key_of := func(p: Vector3) -> String:
		return "%.4f,%.4f,%.4f" % [p.x + 0.0, p.y + 0.0, p.z + 0.0]   # + 0.0 turns -0 into 0
	var all_faces := []
	for f in m.faces:
		var a := []
		for i in f:
			a.append(key_of.call(m.verts[i]))
		all_faces.append(a)
		var b := []
		for k in range(f.size() - 1, -1, -1):
			var p := m.verts[f[k]]
			b.append(key_of.call(Vector3(-p.x, p.y, p.z)))
		all_faces.append(b)
	for f in all_faces:
		for k in f.size():
			var e := [f[k], f[(k + 1) % f.size()]]
			var id: String = e[0] + "|" + e[1]
			if dirs.has(id):
				return false                    # same direction twice: flipped face
			dirs[id] = true
	for id in dirs:
		var parts: PackedStringArray = id.split("|")
		if not dirs.has(parts[1] + "|" + parts[0]):
			return false                        # hole
	return true

func _all_left(m: HalfMesh) -> bool:
	for p in m.verts:
		if p.x > 1e-6:
			return false
	return true

func _initialize() -> void:
	var def = JSON.parse_string(FileAccess.get_file_as_string("res://data/cars/chevrolet_tahoe_1999.json"))
	var p := PorterProject.new()
	p.fill_from_car(def, "4door")
	var d := p.dims

	for key in HalfMesh.TEMPLATES:
		var m := HalfMesh.from_template(key, d)
		_check(_closed_and_consistent(m), "%s template is a closed, consistently wound body" % key)
		var lo := Vector3(1e9, 1e9, 1e9)
		var hi := -lo
		for v in m.verts:
			lo = lo.min(v); hi = hi.max(v)
		var full_w := -lo.x * 2.0
		_check(absf((hi.z - lo.z) - d["length_m"]) < 0.002, "%s length matches the car (%.3f m)" % [key, hi.z - lo.z])
		_check(absf(hi.y - d["height_m"]) < 0.002, "%s height matches the car" % key)
		_check(absf(full_w - d["width_m"]) < 0.002, "%s width matches the car" % key)

	var m := HalfMesh.from_template("suv", d)
	var mid: float = d["front_overhang_m"] + d["wheelbase_m"] * 0.5
	var front_z := INF
	for v in m.verts:
		front_z = minf(front_z, v.z)
	_check(absf(front_z + mid) < 0.002, "front bumper sits front-overhang + half-wheelbase ahead of the origin")
	var tris0 := m.triangle_count()
	_check(tris0 > 0 and tris0 < 400, "SUV starts low-poly (%d triangles)" % tris0)
	_check(m.build_mesh().get_surface_count() == 1, "builds a renderable mesh")

	# move: centerline points stay on the centerline, others stay on the left
	var center := -1
	var side := -1
	for i in m.verts.size():
		if m.is_center(i) and center < 0:
			center = i
		elif not m.is_center(i) and side < 0:
			side = i
	m.push_undo()
	m.move_verts([center, side], Vector3(0.5, 0.1, 0.0))
	_check(m.verts[center].x == 0.0, "centerline point can't leave the centerline")
	_check(m.verts[side].x < 0.0, "side point can't cross to the right half")
	_check(m.undo() and m.verts[center].y < 10.0, "undo restores")
	_check(m.redo(), "redo works")
	m.undo()

	# extrude a side face
	var fi := -1
	for i in m.faces.size():
		var n := m.face_normal(m.faces[i])
		if n.x < -0.9:
			fi = i
			break
	_check(fi >= 0, "found a side-facing face")
	var nf := m.faces.size()
	var nv := m.verts.size()
	var c0 := m.face_center(m.faces[fi])
	var moved := m.extrude_faces([fi], 0.05)
	_check(moved.size() == 4 and m.verts.size() == nv + 4, "extrude adds 4 points for a quad")
	_check(m.faces.size() == nf + 4, "extrude adds 4 side walls")
	_check(m.face_center(m.faces[fi]).x < c0.x - 0.04, "extruded face moved outward")
	_check(_closed_and_consistent(m), "body stays closed after extrude")

	# extrude a face touching the centerline (roof): no wall in the centerline plane
	var m2 := HalfMesh.from_template("suv", d)
	var roof := -1
	for i in m2.faces.size():
		var f: PackedInt32Array = m2.faces[i]
		var touches := false
		for k in f:
			if m2.is_center(k):
				touches = true
		if touches and m2.face_normal(f).y > 0.95:
			roof = i
	m2.extrude_faces([roof], 0.05)
	_check(_closed_and_consistent(m2), "extruding a centerline face keeps the body closed (no inner wall)")
	_check(_all_left(m2), "all points stay on the left half")

	# loop cut across the body
	var m3 := HalfMesh.from_template("suv", d)
	var e: Vector2i = Vector2i(-1, -1)
	for edge in m3.edges():
		var a := m3.verts[edge.x]
		var b := m3.verts[edge.y]
		if absf(a.z - b.z) > 1.0 and not (m3.is_center(edge.x) and m3.is_center(edge.y)):
			e = edge          # a long edge running front-to-back (the side of the body)
			break
	var tv := m3.verts.size()
	var added := m3.loop_cut(e.x, e.y)
	_check(added.size() >= 5, "loop cut adds a ring of points (%d)" % added.size())
	_check(m3.verts.size() == tv + added.size(), "one new point per crossed edge")
	_check(_closed_and_consistent(m3), "body stays closed after loop cut")
	var on_center := 0
	for i in added:
		if m3.is_center(i):
			on_center += 1
	_check(on_center == 2, "loop cut meets the centerline top and bottom")

	# delete + save/load
	var m4 := HalfMesh.from_template("box", d)
	var before := m4.faces.size()
	m4.delete_faces([0])
	_check(m4.faces.size() == before - 1, "delete removes a face")
	var m5 := HalfMesh.from_dict(JSON.parse_string(JSON.stringify(m3.to_dict())))
	_check(m5.verts.size() == m3.verts.size() and m5.faces.size() == m3.faces.size(), "save/load keeps the model")
	_check(m5.template == "suv", "template name survives")

	# paint regions
	var r := HalfMesh.from_template("suv", d)
	var counts := {}
	for reg in r.regions:
		counts[reg] = counts.get(reg, 0) + 1
	_check(r.regions.size() == r.faces.size(), "one paint region per face")
	_check(counts.get("glass", 0) >= 4, "SUV template has glass: side windows, windshield, rear window (%d faces)" % counts.get("glass", 0))
	_check(counts.get("grille", 0) == 1, "SUV template has a grille on the front")
	_check(counts.get("trim", 0) >= 1, "SUV underbody is black trim")
	var glass_ok := true
	for pf in r.faces.size():
		if r.regions[pf] == "glass" and r.face_center(r.faces[pf]).y < d["height_m"] * 0.5:
			glass_ok = false
	_check(glass_ok, "glass is only on the upper body")
	var box := HalfMesh.from_template("box", d)
	_check(not box.regions.has("glass"), "plain box starts all paint (plus underbody)")
	# regions follow edits
	var side_fi := -1
	for pf in r.faces.size():
		if r.regions[pf] == "glass" and r.face_normal(r.faces[pf]).x < -0.8:
			side_fi = pf
			break
	r.extrude_faces([side_fi], 0.02)
	_check(r.regions.size() == r.faces.size(), "extrude keeps one region per face")
	_check(r.regions[r.faces.size() - 1] == "glass", "extrude walls take the extruded face's region")
	var e2: Vector2i = Vector2i(-1, -1)
	for edge in r.edges():
		if absf(r.verts[edge.x].z - r.verts[edge.y].z) > 1.0:
			e2 = edge
			break
	r.loop_cut(e2.x, e2.y)
	_check(r.regions.size() == r.faces.size(), "loop cut keeps one region per face")
	# fill + paint + undo + save/load
	var paint_fi := r.regions.find("paint")
	var area := r.connected_same_region(paint_fi)
	_check(area.size() >= 2, "fill finds the connected body-paint area (%d faces)" % area.size())
	var all_same := true
	for pf in area:
		if r.regions[pf] != "paint":
			all_same = false
	_check(all_same, "fill only takes faces of the same part")
	r.push_undo()
	r.set_region(area, "second")
	_check(r.regions[paint_fi] == "second", "painting a face changes its part")
	r.undo()
	_check(r.regions[paint_fi] == "paint", "undo restores paint")
	r.set_region([paint_fi], "headlight")
	var r2 := HalfMesh.from_dict(JSON.parse_string(JSON.stringify(r.to_dict())))
	_check(r2.regions == r.regions, "paint survives save/load")
	var old := HalfMesh.from_dict({"verts": [[0,0,0],[-1,0,0],[-1,1,0]], "faces": [[0,1,2]]})
	_check(old.regions == ["paint"], "models saved before paint existed load as body paint")
	_check(r.build_mesh({"paint": Color.RED}).get_surface_count() == 1, "colored preview mesh builds")

	# photo textures
	var pp := PorterProject.create("photo texture test")
	pp.fill_from_car(def, "4door")
	var img := Image.create(1600, 700, false, Image.FORMAT_RGBA8)
	img.fill(Color.GRAY)
	pp.import_image("side", img)
	var isz := Vector2(1600, 700)
	pp.align_two_points("side", Vector2(400, 560), Vector2(1250, 560), isz)
	var fa := Vector3(-0.5, pp.dims["tire_radius_m"], -pp.dims["wheelbase_m"] * 0.5)   # front axle center, any x
	var uv := PhotoTexturer.uv_for(pp, "side", fa, isz)
	_check((uv * isz).distance_to(Vector2(400, 560)) < 0.5, "front axle center maps to the tapped wheel pixel in the side photo")
	var uv_m := PhotoTexturer.uv_for(pp, "side", Vector3(-fa.x, fa.y, fa.z), isz)
	_check(uv_m.is_equal_approx(uv), "the mirrored side uses the same side-photo pixel")
	var avail := {"side": true, "front": true, "rear": true, "top": true}
	_check(PhotoTexturer.choose_view("photo", Vector3(-1, 0.1, 0), avail) == "side", "side-facing face takes the side photo")
	_check(PhotoTexturer.choose_view("photo", Vector3(-0.1, 0.95, 0.1), avail) == "top", "roof face takes the top photo")
	_check(PhotoTexturer.choose_view("photo", Vector3(0, 0.2, -0.95), avail) == "front", "nose face takes the front photo")
	_check(PhotoTexturer.choose_view("photo", Vector3(0, 0.2, 0.95), avail) == "rear", "tail face takes the rear photo")
	_check(PhotoTexturer.choose_view("photo:front", Vector3(-1, 0, 0), avail) == "front", "a forced photo is used")
	_check(PhotoTexturer.choose_view("photo", Vector3(0, 1, 0), {"side": true}) == "side", "falls back to an available photo")
	_check(PhotoTexturer.choose_view("photo", Vector3(0, 1, 0), {}) == "", "no photos: face stays plain")
	var pm := HalfMesh.from_template("suv", pp.dims)
	for pf in pm.faces.size():
		if pm.regions[pf] == "paint":
			pm.regions[pf] = "photo"
	var built := PhotoTexturer.build(pm, pp, {}, {"side": pp.load_photo("side"), "front": null, "rear": null, "top": null})
	var am: ArrayMesh = built[0]
	_check(am.get_surface_count() == 2 and built[1] == ["side"], "textured preview: plain surface + side-photo surface")
	_check(HalfMesh.region_valid("photo:top") and not HalfMesh.region_valid("photo:roof") and not HalfMesh.region_valid("paint:side"), "photo source names are validated")
	pm.regions[0] = "photo:front"
	var pm2 := HalfMesh.from_dict(JSON.parse_string(JSON.stringify(pm.to_dict())))
	_check(pm2.regions[0] == "photo:front", "photo source survives save/load")
	for f in DirAccess.get_files_at(pp.dir()):
		DirAccess.remove_absolute(pp.dir() + f)
	DirAccess.remove_absolute(pp.dir())

	print("\n%s (%d failed)" % ["ALL PASSED" if fails == 0 else "FAILURES", fails])
	quit(1 if fails else 0)
