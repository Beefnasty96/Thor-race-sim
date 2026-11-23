extends SceneTree
## Checks the Car Porter pickup bed tool: hollowing the bed of the Pickup
## template, its rails / walls / floor / wheel-well humps, depth changes,
## bed photos, and saving.
##   godot --headless -s res://scripts/tests/bed_test.gd

var fails := 0

func _check(cond: bool, what: String) -> void:
	print(("  ok    " if cond else "  FAIL  ") + what)
	if not cond:
		fails += 1

func _initialize() -> void:
	var def: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/cars/chevrolet_tahoe_1999.json"))
	var p := PorterProject.create("bed test")
	p.fill_from_car(def, "4door")
	var m := HalfMesh.from_template("pickup", p.dims)
	var tri_before := m.triangle_count()

	# --- finding the bed
	var cover := m.find_bed_cover()
	_check(cover.size() >= 1, "pickup: flat bed top found (%d face(s))" % cover.size())
	var sedan := HalfMesh.from_template("sedan", p.dims)
	_check(sedan.find_bed_cover().is_empty() and HalfMesh.from_template("coupe", p.dims).find_bed_cover().is_empty(), "sedan / coupe: the trunk lid behind a sloped rear window isn't a bed")
	var suv := HalfMesh.from_template("suv", p.dims)
	_check(suv.hollow_bed(0.5, 0.05) != "", "SUV: hollowing says there's no bed")

	# --- hollowing
	var axle_z: float = p.dims["wheelbase_m"] * 0.5
	var r := p.tire_radius(true)
	var humps := [[axle_z - r * 1.15, axle_z + r * 1.15, r * 2.0 + 0.09, -0.62]]
	var rail_y := -INF
	for fi in cover:
		for i in m.faces[fi]:
			rail_y = maxf(rail_y, m.verts[i].y)
	var msg := m.hollow_bed(0.5, 0.05, humps)
	_check(msg == "", "bed hollowed (%s)" % msg)
	_check(m.has_bed(), "mesh reports a bed")
	_check(m.find_bed_cover().is_empty(), "no flat bed top left over the bed")
	_check(m.hollow_bed(0.5, 0.05) != "", "hollowing twice is refused")
	var h := m.bed_heights()
	_check(absf(float(h[1]) - float(h[0]) - 0.5) < 0.01, "bed is 0.5 m deep (%.3f)" % (float(h[1]) - float(h[0])))
	var left := true
	for v in m.verts:
		if v.x > 1e-6:
			left = false
	_check(left, "all points stay on the left half")
	# no edge used by more than two faces; open edges only on the centerline or the body's existing openings
	var use := m.edge_use()
	var over := 0
	for e in use:
		if use[e] > 2:
			over += 1
	_check(over == 0, "no edge shared by more than two faces")
	var open_new := 0
	for e in use:
		if use[e] == 1:
			var a: int = (e as Vector2i).x
			var b: int = (e as Vector2i).y
			if not (m.is_center(a) and m.is_center(b)):
				open_new += 1
	# humps sit on the floor without sharing its edges (their bottom edges are open by design)
	_check(open_new <= 6 * humps.size(), "only the humps' edges against the floor and bed wall are open (%d)" % open_new)
	# faces by kind
	var floor_up := 0
	var walls := {"bedside": 0, "bedfront": 0, "bedgate": 0}
	var bad_wall := 0
	var cx := -0.4
	for fi in m.faces.size():
		if not HalfMesh.is_bed_region(m.regions[fi]):
			continue
		var n := m.face_normal(m.faces[fi])
		var kind := HalfMesh.bed_view_of(n)
		if kind == "bedfloor":
			floor_up += 1
		else:
			walls[kind] += 1
			# a wall faces into the bed: toward the bed's middle line (x ~ cx) or along z
			var c := m.face_center(m.faces[fi])
			if kind == "bedside" and n.x * (cx - c.x) < 0.0 and c.x < -0.65:
				bad_wall += 1
	_check(floor_up >= 2, "floor and hump tops face up (%d)" % floor_up)
	_check(walls["bedside"] >= 2 and walls["bedfront"] >= 1 and walls["bedgate"] >= 1, "side, front and tailgate walls built %s" % str(walls))
	_check(bad_wall == 0, "bed side walls face into the bed")
	var rails := 0
	for fi in m.faces.size():
		if HalfMesh.region_outer(m.regions[fi]) == "paint" and m.face_normal(m.faces[fi]).y > 0.9 and absf(m.face_center(m.faces[fi]).y - rail_y) < 0.02:
			rails += 1
	_check(rails >= 3, "body-colored rails on the side, front and tailgate (%d)" % rails)
	_check(m.triangle_count() - tri_before < 60, "bed adds few triangles (%d)" % (m.triangle_count() - tri_before))

	# --- depth
	m.set_bed_depth(0.3)
	h = m.bed_heights()
	_check(absf(float(h[1]) - float(h[0]) - 0.3) < 0.01, "depth change moves the floor (%.3f)" % (float(h[1]) - float(h[0])))
	m.set_bed_depth(5.0)
	h = m.bed_heights()
	var bottom := INF
	for v in m.verts:
		if v.z > 0.5:
			bottom = minf(bottom, v.y)
	_check(float(h[0]) >= bottom + HalfMesh.BED_MIN_FLOOR - 0.001, "floor never goes through the body's bottom")
	m.set_bed_depth(0.3)
	var hump_ok := true
	h = m.bed_heights()
	for fi in m.bed_faces_for("bedfloor"):
		for i in m.faces[fi]:
			if m.verts[i].y < float(h[0]) - 0.001:
				hump_ok = false
	_check(hump_ok, "wheel-well humps stay above a raised floor")
	m.set_bed_depth(0.5)

	# --- photos
	_check(HalfMesh.region_valid("photo:bedfloor") and HalfMesh.region_valid("photo:bedgate|carpet"), "bed photo paints are valid")
	for view in HalfMesh.BED_PHOTOS:
		_check(not m.bed_faces_for(view).is_empty(), "%s photo has faces to go on" % view)
	var img := Image.create(800, 600, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.15, 0.1))
	p.import_image("bedfloor", img)
	var outline := DashPhotoView.panel_outline(p, m, "bedfloor")
	_check(outline.size() >= 8, "bed floor outline for fitting the photo (%d edges, both sides)" % outline.size())
	DashPhotoView.fit_to_outline(p, "bedfloor", outline, 800, 600)
	var n_painted := m.auto_bed_paint({"bedfloor": true})
	var photo_n := 0
	for fi in m.faces.size():
		if m.region_of(fi) == "photo:bedfloor":
			photo_n += 1
	_check(n_painted > 5 and photo_n == m.bed_faces_for("bedfloor").size(), "auto paint: floor gets the photo, walls get liner (%d photo faces)" % photo_n)
	var built := PhotoTexturer.build(m, p, {}, {"bedfloor": p.load_photo("bedfloor")})
	_check((built[1] as Array).has("bedfloor"), "bed floor photo textures the floor")
	var am: ArrayMesh = built[0]
	var uvs: PackedVector2Array = am.surface_get_arrays(1)[Mesh.ARRAY_TEX_UV]
	var inside := true
	for uv in uvs:
		if uv.x < -0.05 or uv.x > 1.05 or uv.y < -0.05 or uv.y > 1.05:
			inside = false
	_check(inside, "fitted floor photo covers the floor (UVs inside the photo)")
	var tops := InteriorBuilder.suits_inner_photo(m, "ceiling")
	var bed_in_ceiling := false
	for fi in tops:
		if HalfMesh.is_bed_region(m.regions[fi]):
			bed_in_ceiling = true
	_check(not bed_in_ceiling, "bed faces aren't mistaken for the ceiling")

	# --- save / load
	var m2 := HalfMesh.from_dict(m.to_dict())
	_check(m2.has_bed() and m2.faces.size() == m.faces.size(), "bed survives save/load")
	p.save()
	var p2 := PorterProject.load_project(p.id)
	_check(p2.views["bedfloor"]["file"] == "bedfloor.png", "bed photo survives save/load")

	for f in DirAccess.get_files_at(p.dir()):
		DirAccess.remove_absolute(p.dir() + f)
	DirAccess.remove_absolute(p.dir())
	print("ALL PASSED (0 failed)" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails > 0 else 0)
