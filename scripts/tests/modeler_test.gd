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

	print("\n%s (%d failed)" % ["ALL PASSED" if fails == 0 else "FAILURES", fails])
	quit(1 if fails else 0)
