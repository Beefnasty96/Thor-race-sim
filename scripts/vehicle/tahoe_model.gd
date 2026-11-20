class_name TahoeModel
extends Node3D
## Procedural GMT400 Tahoe body built from the real dimensions (stand-in until
## a hand-modelled mesh is imported). PS2-era detail level: slab sides with
## wheel arches, separate greenhouse with tumblehome, chrome bumpers, grille,
## quad-rectangle headlights, tall taillights, two-tone lower cladding,
## mirrors, roof rails and door seams.

var paint_mat: StandardMaterial3D
var wheel_nodes: Array[Node3D] = []

func build(body: Dictionary, paint: Dictionary, wheel_radius: float, four_door: bool) -> void:
	for c in get_children():
		c.queue_free()
	wheel_nodes.clear()
	var wb: float = body["wheelbase_m"]
	var L: float = body["length_m"]
	var W: float = body["width_m"]
	var front_oh := 0.93
	var F := -wb * 0.5 - front_oh
	var R := F + L
	var hw := W * 0.5 - 0.02
	var zf := -wb * 0.5
	var zr := wb * 0.5

	paint_mat = StandardMaterial3D.new()
	var pc: Array = paint["color"]
	paint_mat.albedo_color = Color(pc[0], pc[1], pc[2])
	paint_mat.metallic = paint.get("metallic", 0.4)
	paint_mat.roughness = 0.22
	paint_mat.clearcoat_enabled = true
	paint_mat.clearcoat = 1.0
	paint_mat.clearcoat_roughness = 0.05
	paint_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var glass := _mat(Color(0.04, 0.05, 0.06), 0.9, 0.04)
	var chrome := _mat(Color(0.85, 0.86, 0.88), 1.0, 0.12)
	var trim := _mat(Color(0.36, 0.37, 0.38), 0.2, 0.55)     # argent/grey cladding
	var black := _mat(Color(0.03, 0.03, 0.03), 0.0, 0.6)
	var lamp := _mat(Color(0.95, 0.95, 0.9), 0.6, 0.05)
	lamp.emission_enabled = true
	lamp.emission = Color(1, 0.97, 0.85)
	lamp.emission_energy_multiplier = 0.4
	var tail := _mat(Color(0.7, 0.03, 0.02), 0.3, 0.1)
	tail.emission_enabled = true
	tail.emission = Color(0.6, 0.0, 0.0)
	tail.emission_energy_multiplier = 0.3
	var amber := _mat(Color(0.95, 0.55, 0.05), 0.3, 0.1)

	# ---------- lower body (side profile with wheel arches) ----------
	var zw := F + 1.45           # windshield base
	var ra := 0.47
	var ca := 0.40
	var rocker := 0.50
	var lower := PackedVector2Array()
	lower.append(Vector2(F + 0.06, rocker + 0.06))
	lower.append(Vector2(F, 0.62))
	lower.append(Vector2(F, 1.06))
	lower.append(Vector2(F + 0.07, 1.13))
	lower.append(Vector2(F + 0.6, 1.16))
	lower.append(Vector2(zw, 1.21))
	lower.append(Vector2(R - 0.03, 1.24))
	lower.append(Vector2(R, 1.20))
	lower.append(Vector2(R, 0.58))
	lower.append(Vector2(R - 0.06, rocker))
	_arch(lower, zr, ca, ra, rocker)
	_arch(lower, zf, ca, ra, rocker)
	add_child(_extrude(lower, func(_y): return hw, paint_mat, {}))

	# inner wheel wells / underbody so you can't see through the arches
	_box(Vector3(W * 0.82, 0.25, L * 0.92), Vector3(0, rocker + 0.05, (F + R) * 0.5), black)
	for z in [zf, zr]:
		_box(Vector3(W * 0.7, ra * 1.2, ra * 2.0), Vector3(0, ca + 0.15, z), black)

	# ---------- greenhouse ----------
	var roof := 1.80
	var gh := PackedVector2Array([
		Vector2(zw + 0.02, 1.21), Vector2(zw + 0.80, roof - 0.02), Vector2(zw + 0.86, roof),
		Vector2(R - 0.12, roof), Vector2(R - 0.05, roof - 0.04), Vector2(R - 0.04, 1.24)])
	var gh_w := func(y: float) -> float: return lerpf(hw - 0.03, hw - 0.11, clampf((y - 1.21) / 0.6, 0.0, 1.0))
	# edge materials: 0 windshield, 1 small front roof edge, 2 roof, 3 rear edge, 4 rear glass, 5 belt
	add_child(_extrude(gh, gh_w, glass, {0: glass, 1: paint_mat, 2: paint_mat, 3: paint_mat, 4: glass, 5: paint_mat}))
	# pillars (body colour strips on the glass sides)
	var pillars := [zw + 0.02, (zw + 0.86 + R) * 0.5 - (0.35 if four_door else 0.0)]
	if four_door:
		pillars.append(R - 0.85)
	pillars.append(R - 0.06)
	for s in [-1.0, 1.0]:
		for i in pillars.size():
			var z: float = pillars[i]
			var wpil := 0.09 if i == 0 else 0.14
			if i == 0:
				# A-pillar follows the windshield rake
				var a := Vector3(s * (hw - 0.07), 1.22, zw + 0.03)
				var b := Vector3(s * (hw - 0.16), roof - 0.01, zw + 0.84)
				_beam(a, b, 0.07, paint_mat)
			else:
				_box(Vector3(0.03, roof - 1.22, wpil), Vector3(s * (gh_w.call(1.5) + 0.005), (roof + 1.22) * 0.5, z), paint_mat if i < pillars.size() - 1 else paint_mat)
	# roof rails
	for s in [-1.0, 1.0]:
		_box(Vector3(0.05, 0.05, R - zw - 1.3), Vector3(s * (hw - 0.3), roof + 0.04, (zw + 0.95 + R - 0.2) * 0.5), black)

	# ---------- front end ----------
	var fz := F - 0.005
	_box(Vector3(W - 0.5, 0.33, 0.04), Vector3(0, 0.92, fz), black)                 # grille opening
	for k in 3:
		_box(Vector3(W - 0.56, 0.035, 0.05), Vector3(0, 0.82 + k * 0.1, fz - 0.005), chrome)
	_box(Vector3(0.05, 0.33, 0.05), Vector3(0, 0.92, fz - 0.006), chrome)
	for s in [-1.0, 1.0]:
		# stacked rectangular composite headlamps + amber marker wrapping the corner
		_box(Vector3(0.33, 0.16, 0.04), Vector3(s * (hw - 0.30), 0.97, fz - 0.004), lamp)
		_box(Vector3(0.33, 0.07, 0.04), Vector3(s * (hw - 0.30), 0.83, fz - 0.004), amber)
		_box(Vector3(0.04, 0.12, 0.2), Vector3(s * (hw + 0.004), 0.92, F + 0.12), amber)
	# chrome bumper
	_box(Vector3(W - 0.02, 0.22, 0.16), Vector3(0, 0.55, F - 0.06), chrome)
	_box(Vector3(W - 0.3, 0.1, 0.12), Vector3(0, 0.40, F - 0.02), black)          # air dam
	# ---------- rear end ----------
	var rz := R + 0.005
	for s in [-1.0, 1.0]:
		_box(Vector3(0.16, 0.48, 0.04), Vector3(s * (hw - 0.09), 0.98, rz), tail)
	_box(Vector3(W - 0.5, 0.012, 0.02), Vector3(0, 1.10, rz), chrome)              # tailgate handle line
	_box(Vector3(W - 0.02, 0.2, 0.16), Vector3(0, 0.56, R + 0.06), chrome)
	_box(Vector3(0.012, 0.6, 0.02), Vector3(0, 0.9, rz + 0.002), black)            # barn door split
	# ---------- sides ----------
	for s in [-1.0, 1.0]:
		var x: float = s * (hw + 0.006)
		# two-tone lower cladding between and outside the arches
		var segs := [[F + 0.05, zf - ra - 0.02], [zf + ra + 0.02, zr - ra - 0.02], [zr + ra + 0.02, R - 0.05]]
		for seg in segs:
			var len: float = seg[1] - seg[0]
			_box(Vector3(0.012, 0.24, len), Vector3(x, rocker + 0.12, (seg[0] + seg[1]) * 0.5), trim)
		# door seams
		var seams := [zw - 0.05, (R - 0.85) if four_door else (zw + 1.35), R - 0.04]
		if four_door:
			seams.insert(1, zw + 1.05)
		for z in seams:
			_box(Vector3(0.008, 0.62, 0.012), Vector3(x + s * 0.002, 0.93, z), black)
		# door handles
		_box(Vector3(0.02, 0.04, 0.16), Vector3(x + s * 0.008, 1.05, zw + 0.85), black)
		if four_door:
			_box(Vector3(0.02, 0.04, 0.16), Vector3(x + s * 0.008, 1.05, zw + 1.85), black)
		# mirror
		_box(Vector3(0.18, 0.22, 0.08), Vector3(s * (hw + 0.11), 1.33, zw + 0.12), black)
		# fender flare lips
		for z in [zf, zr]:
			_arch_lip(s, hw, z, ca, ra, trim)

	# ---------- wheels ----------
	for i in 4:
		var wn := Node3D.new()
		wn.name = ["FL", "FR", "RL", "RR"][i]
		var left := i % 2 == 0
		var pivot := Node3D.new()
		wn.add_child(pivot)
		var tire_mesh := CylinderMesh.new()
		tire_mesh.top_radius = wheel_radius
		tire_mesh.bottom_radius = wheel_radius
		tire_mesh.height = 0.235
		tire_mesh.radial_segments = 20
		tire_mesh.rings = 1
		var t := MeshInstance3D.new()
		t.mesh = tire_mesh
		t.material_override = _mat(Color(0.05, 0.05, 0.05), 0.0, 0.85)
		t.rotation = Vector3(0, 0, PI * 0.5)
		pivot.add_child(t)
		var rim := CylinderMesh.new()
		rim.top_radius = 0.2; rim.bottom_radius = 0.2; rim.height = 0.24
		rim.radial_segments = 16
		var rmi := MeshInstance3D.new()
		rmi.mesh = rim
		rmi.material_override = _mat(Color(0.78, 0.78, 0.8), 0.9, 0.25)
		rmi.rotation = Vector3(0, 0, PI * 0.5)
		pivot.add_child(rmi)
		# five spokes so wheel rotation is visible
		for k in 5:
			var sp := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.02, 0.32, 0.06)
			sp.mesh = bm
			sp.material_override = _mat(Color(0.3, 0.3, 0.32), 0.8, 0.3)
			sp.position = Vector3((-0.125 if left else 0.125), 0, 0)
			sp.rotation = Vector3(TAU * k / 5.0, 0, 0)
			pivot.add_child(sp)
		add_child(wn)
		wheel_nodes.append(wn)

func set_paint(paint: Dictionary) -> void:
	if paint_mat:
		var pc: Array = paint["color"]
		paint_mat.albedo_color = Color(pc[0], pc[1], pc[2])
		paint_mat.metallic = paint.get("metallic", 0.4)

# ------------------------------------------------------------------
func _mat(c: Color, metal: float, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metal
	m.roughness = rough
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

func _box(size: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	add_child(mi)

func _beam(a: Vector3, b: Vector3, thick: float, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(thick * 0.5, thick, a.distance_to(b))
	mi.mesh = bm
	mi.material_override = mat
	var mid := (a + b) * 0.5
	mi.transform = Transform3D(Basis.looking_at(b - a, Vector3.UP), mid)
	add_child(mi)

## Append an arch (semicircle over the wheel) to a profile running rear→front.
func _arch(poly: PackedVector2Array, zc: float, yc: float, r: float, bottom: float) -> void:
	var a0 := asin(clampf((bottom - yc) / r, -1.0, 1.0))
	var n := 12
	for k in n + 1:
		var th := lerpf(a0, PI - a0, float(k) / n)
		poly.append(Vector2(zc + r * cos(th), yc + r * sin(th)))

func _arch_lip(s: float, hw: float, zc: float, yc: float, r: float, mat: Material) -> void:
	var n := 8
	for k in n:
		var t0 := lerpf(0.15, PI - 0.15, float(k) / n)
		var t1 := lerpf(0.15, PI - 0.15, float(k + 1) / n)
		var a := Vector3(s * (hw + 0.015), yc + (r + 0.03) * sin(t0), zc + (r + 0.03) * cos(t0))
		var b := Vector3(s * (hw + 0.015), yc + (r + 0.03) * sin(t1), zc + (r + 0.03) * cos(t1))
		_beam(a, b, 0.07, mat)

## Extrude a side-profile polygon (z, y) across the car. half_width(y) gives
## tumblehome. edge_mats overrides the material of individual perimeter faces.
func _extrude(poly: PackedVector2Array, half_width: Callable, cap_mat: Material, edge_mats: Dictionary) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	var area := 0.0
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		area += a.x * b.y - b.x * a.y
	var ccw := area > 0.0
	var by_mat := {}
	var idx := Geometry2D.triangulate_polygon(poly)
	# side caps
	for s in [-1.0, 1.0]:
		var st := _st_for(by_mat, cap_mat)
		for k in range(0, idx.size(), 3):
			for q in 3:
				var p := poly[idx[k + q]]
				st.set_normal(Vector3(s, 0, 0))
				st.add_vertex(Vector3(s * half_width.call(p.y), p.y, p.x))
	# perimeter strips
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		var d := b - a
		var n2 := Vector2(d.y, -d.x).normalized()
		if ccw:
			n2 = -n2
		var n := Vector3(0, n2.y, n2.x)
		var mat: Material = edge_mats.get(i, cap_mat)
		var st := _st_for(by_mat, mat)
		var al := Vector3(-half_width.call(a.y), a.y, a.x)
		var ar := Vector3(half_width.call(a.y), a.y, a.x)
		var bl := Vector3(-half_width.call(b.y), b.y, b.x)
		var br := Vector3(half_width.call(b.y), b.y, b.x)
		for v in [al, bl, br, al, br, ar]:
			st.set_normal(n)
			st.add_vertex(v)
	for mat in by_mat:
		var st: SurfaceTool = by_mat[mat]
		st.set_material(mat)
		st.commit(mesh)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi

func _st_for(by_mat: Dictionary, mat: Material) -> SurfaceTool:
	if not by_mat.has(mat):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		by_mat[mat] = st
	return by_mat[mat]
