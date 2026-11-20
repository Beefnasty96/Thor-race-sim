class_name Track
extends Node3D
## Procedurally built circuit from a closed spline of control points.
## Generates road, curbs, grass shoulders, gravel traps, barriers, terrain
## and scenery, each with collision tagged by surface type so the tire model
## knows what it's driving on.

const SURF_ASPHALT := {"name": "asphalt", "mu": 1.0, "crr": 0.0}
const SURF_CURB := {"name": "curb", "mu": 0.92, "crr": 0.002}
const SURF_GRASS := {"name": "grass", "mu": 0.55, "crr": 0.06}
const SURF_GRAVEL := {"name": "gravel", "mu": 0.62, "crr": 0.20}

@export var track_name := "Ridgeview Circuit"
var road_width := 12.0
var curb_width := 1.4
var shoulder_width := 13.0
var sample_step := 2.5

# control points: x, elevation, z  (metres)
var control := [
	Vector3(0, 0, 200), Vector3(0, 0, -200), Vector3(12, 0, -300), Vector3(62, 0, -342),
	Vector3(112, 0.5, -312), Vector3(122, 1.5, -250), Vector3(150, 3, -182), Vector3(210, 5, -160),
	Vector3(262, 7, -202), Vector3(322, 9, -192), Vector3(368, 12, -130), Vector3(382, 15, -40),
	Vector3(362, 16, 40), Vector3(392, 14, 118), Vector3(462, 10, 148), Vector3(502, 8, 220),
	Vector3(470, 6, 290), Vector3(400, 4, 302), Vector3(300, 2, 302), Vector3(160, 0.5, 308),
	Vector3(118, 0, 336), Vector3(86, 0, 314), Vector3(56, 0, 328), Vector3(28, 0, 334),
	Vector3(4, 0, 292),
]

# sampled centreline
var pts: PackedVector3Array = []
var tangents: PackedVector3Array = []
var rights: PackedVector3Array = []
var curvature: PackedFloat32Array = []
var dist: PackedFloat32Array = []
var length := 0.0
var start_index := 0

func build() -> void:
	_sample()
	_build_surfaces()
	_build_barriers()
	_build_terrain()
	_build_scenery()

# ------------------------------------------------------------------
func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)

func _sample() -> void:
	var raw: PackedVector3Array = []
	var n := control.size()
	for i in n:
		var p0: Vector3 = control[(i - 1 + n) % n]
		var p1: Vector3 = control[i]
		var p2: Vector3 = control[(i + 1) % n]
		var p3: Vector3 = control[(i + 2) % n]
		var seg := p1.distance_to(p2)
		var steps := maxi(4, int(seg / 0.5))
		for s in steps:
			raw.append(_catmull(p0, p1, p2, p3, float(s) / steps))
	# resample at even spacing
	pts.clear()
	var acc := 0.0
	pts.append(raw[0])
	for i in range(1, raw.size() + 1):
		var a := raw[i - 1]
		var b := raw[i % raw.size()]
		var d := a.distance_to(b)
		acc += d
		while acc >= sample_step:
			acc -= sample_step
			var t := 1.0 - acc / d
			pts.append(a.lerp(b, t))
	if pts[pts.size() - 1].distance_to(pts[0]) < sample_step * 0.5:
		pts.remove_at(pts.size() - 1)
	var m := pts.size()
	tangents.resize(m); rights.resize(m); curvature.resize(m); dist.resize(m)
	length = 0.0
	for i in m:
		var prev := pts[(i - 1 + m) % m]
		var next := pts[(i + 1) % m]
		var t := (next - prev).normalized()
		tangents[i] = t
		var flat := Vector3(t.x, 0, t.z).normalized()
		rights[i] = flat.cross(Vector3.UP).normalized()
		dist[i] = length
		length += pts[i].distance_to(next)
	for i in m:
		var a := tangents[(i - 3 + m) % m]
		var b := tangents[(i + 3) % m]
		var ang := atan2(a.cross(b).y, a.dot(b))
		curvature[i] = ang / (6.0 * sample_step)    # signed: + = left turn
	# start/finish line ~ 150 m before the end of the front straight
	start_index = 0
	var best := 1e9
	for i in m:
		var d := pts[i].distance_to(Vector3(0, 0, 0))
		if d < best:
			best = d
			start_index = i

func start_transform(grid_slot: int = 0) -> Transform3D:
	var i := (start_index - 6 - grid_slot * 4 + pts.size()) % pts.size()
	var p := pts[i] + Vector3(0, 0.05, 0)
	var fwd := tangents[i]
	var b := Basis.looking_at(fwd, Vector3.UP)
	return Transform3D(b, p)

## Nearest sample index, searching around a hint for speed.
func nearest_index(pos: Vector3, hint: int = -1, window: int = 40) -> int:
	var m := pts.size()
	var best := -1
	var bd := 1e12
	if hint < 0:
		for i in m:
			var d := pos.distance_squared_to(pts[i])
			if d < bd:
				bd = d; best = i
		return best
	for k in range(-window, window + 1):
		var i := (hint + k + m) % m
		var d := pos.distance_squared_to(pts[i])
		if d < bd:
			bd = d; best = i
	return best

# ------------------------------------------------------------------
## cross-section offset list (left→right) with surface for each band
func _bands(i: int) -> Array:
	var hw := road_width * 0.5
	var c := curvature[i]
	var corner := absf(c) > 0.006
	var cw := curb_width if corner else 0.0
	# gravel trap on the outside of tight corners
	var gravel_out := absf(c) > 0.012
	var out_left := c < 0.0     # right turn -> outside is left
	var bands := []
	var edge := hw + cw
	var lw := shoulder_width
	var rw := shoulder_width
	bands.append([-(edge + lw), -edge, (SURF_GRAVEL if gravel_out and out_left else SURF_GRASS)])
	if cw > 0.0:
		bands.append([-edge, -hw, SURF_CURB])
	bands.append([-hw, hw, SURF_ASPHALT])
	if cw > 0.0:
		bands.append([hw, edge, SURF_CURB])
	bands.append([edge, edge + rw, (SURF_GRAVEL if gravel_out and not out_left else SURF_GRASS)])
	return bands

func _point(i: int, off: float) -> Vector3:
	return pts[i] + rights[i] * off

func _build_surfaces() -> void:
	var tools := {}
	for s in [SURF_ASPHALT, SURF_CURB, SURF_GRASS, SURF_GRAVEL]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		tools[s["name"]] = st
	var m := pts.size()
	# Build each band as quads. Shoulder bands are matched by index position
	# rather than offset so neighbouring samples with/without curbs stitch.
	for i in m:
		var j := (i + 1) % m
		var bi := _bands(i)
		var bj := _bands(j)
		var road_i := _find_band(bi, "asphalt")
		var road_j := _find_band(bj, "asphalt")
		_quad(tools["asphalt"], i, j, bi[road_i][0], bi[road_i][1], bj[road_j][0], bj[road_j][1], 0.0, Color(1, 1, 1))
		# left side: curb (optional) then shoulder
		_side(tools, i, j, bi, bj, road_i, road_j, -1)
		_side(tools, i, j, bi, bj, road_i, road_j, 1)
	var mats := _materials()
	for name in tools:
		var st: SurfaceTool = tools[name]
		var mesh := st.commit()
		if mesh.get_surface_count() == 0:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mats[name]
		mi.name = "Surface_" + name
		add_child(mi)
		var body := StaticBody3D.new()
		body.name = "Body_" + name
		var surf: Dictionary = {"asphalt": SURF_ASPHALT, "curb": SURF_CURB, "grass": SURF_GRASS, "gravel": SURF_GRAVEL}[name]
		body.set_meta("surface", surf)
		var shape := mesh.create_trimesh_shape()
		shape.backface_collision = true
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		add_child(body)
	_build_markings()

func _find_band(bands: Array, n: String) -> int:
	for k in bands.size():
		if bands[k][2]["name"] == n:
			return k
	return 0

func _side(tools: Dictionary, i: int, j: int, bi: Array, bj: Array, ri: int, rj: int, dir: int) -> void:
	# inner edge = road edge; walk outward through bands
	var ei: float = bi[ri][1] if dir > 0 else bi[ri][0]
	var ej: float = bj[rj][1] if dir > 0 else bj[rj][0]
	var ci := _curb_w(bi, ri, dir)
	var cj := _curb_w(bj, rj, dir)
	if ci > 0.0 or cj > 0.0:
		var oi := ei + ci * dir
		var oj := ej + cj * dir
		var col := Color(0.85, 0.08, 0.06) if int(dist[i] / 4.0) % 2 == 0 else Color(0.95, 0.95, 0.95)
		if dir > 0:
			_quad(tools["curb"], i, j, ei, oi, ej, oj, 0.04, col)
		else:
			_quad(tools["curb"], i, j, oi, ei, oj, ej, 0.04, col)
		ei = oi; ej = oj
	var sbi: Array = bi[0] if dir < 0 else bi[bi.size() - 1]
	var sbj: Array = bj[0] if dir < 0 else bj[bj.size() - 1]
	var surf_name: String = sbi[2]["name"]
	var wi := absf(sbi[1] - sbi[0])
	var wj := absf(sbj[1] - sbj[0])
	var oi2 := ei + wi * dir
	var oj2 := ej + wj * dir
	if dir > 0:
		_quad(tools[surf_name], i, j, ei, oi2, ej, oj2, -0.02, Color(1, 1, 1), 0.6)
	else:
		_quad(tools[surf_name], i, j, oi2, ei, oj2, ej, -0.02, Color(1, 1, 1), 0.6)

func _curb_w(bands: Array, ri: int, dir: int) -> float:
	var k := ri + dir
	if k >= 0 and k < bands.size() and bands[k][2]["name"] == "curb":
		return absf(bands[k][1] - bands[k][0])
	return 0.0

## Quad between two cross-sections. a0..a1 offsets at sample i, b0..b1 at j.
## drop: outer edge lowered (m) so shoulders fall away slightly.
func _quad(st: SurfaceTool, i: int, j: int, a0: float, a1: float, b0: float, b1: float,
		lift: float, col: Color, drop: float = 0.0) -> void:
	var up := Vector3.UP
	var pa0 := _point(i, a0) + up * lift
	var pa1 := _point(i, a1) + up * lift
	var pb0 := _point(j, b0) + up * lift
	var pb1 := _point(j, b1) + up * lift
	if drop != 0.0:
		# lower whichever edge is further from the centreline
		if absf(a0) > absf(a1):
			pa0.y -= drop; pb0.y -= drop
		else:
			pa1.y -= drop; pb1.y -= drop
	var u0 := dist[i] / 6.0
	var u1 := u0 + sample_step / 6.0
	var n := (pb0 - pa0).cross(pa1 - pa0).normalized()
	if n.y < 0.0:
		n = -n
	st.set_color(col)
	for v in [[pa0, Vector2(a0 / 6.0, u0)], [pb0, Vector2(b0 / 6.0, u1)], [pb1, Vector2(b1 / 6.0, u1)],
			[pa0, Vector2(a0 / 6.0, u0)], [pb1, Vector2(b1 / 6.0, u1)], [pa1, Vector2(a1 / 6.0, u0)]]:
		st.set_normal(n)
		st.set_uv(v[1])
		st.add_vertex(v[0])

func _build_markings() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var m := pts.size()
	var hw := road_width * 0.5
	for i in m:
		var j := (i + 1) % m
		for side in [-1.0, 1.0]:
			var o0: float = side * (hw - 0.35)
			var o1: float = side * (hw - 0.15)
			_quad(st, i, j, minf(o0, o1), maxf(o0, o1), minf(o0, o1), maxf(o0, o1), 0.012, Color(0.92, 0.92, 0.9))
	# start/finish checkered band
	var s := start_index
	for k in 2:
		var i := (s + k) % m
		var j := (i + 1) % m
		var cells := 12
		for c in cells:
			var o0 := -hw + road_width * c / cells
			var o1 := o0 + road_width / cells
			var col := Color(0.95, 0.95, 0.95) if (c + k) % 2 == 0 else Color(0.05, 0.05, 0.05)
			_quad(st, i, j, o0, o1, o0, o1, 0.014, col)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.7
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

func _noise_tex(freq: float, c0: Color, c1: Color, size: int = 512) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.frequency = freq
	n.fractal_octaves = 4
	var t := NoiseTexture2D.new()
	t.noise = n
	t.width = size; t.height = size
	t.seamless = true
	var g := Gradient.new()
	g.set_color(0, c0)
	g.set_color(1, c1)
	t.color_ramp = g
	t.generate_mipmaps = true
	return t

func _materials() -> Dictionary:
	var asphalt := StandardMaterial3D.new()
	asphalt.albedo_texture = _noise_tex(0.09, Color(0.17, 0.17, 0.18), Color(0.30, 0.30, 0.31))
	asphalt.roughness = 0.82
	asphalt.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var curb := StandardMaterial3D.new()
	curb.vertex_color_use_as_albedo = true
	curb.roughness = 0.5
	var grass := StandardMaterial3D.new()
	grass.albedo_texture = _noise_tex(0.05, Color(0.20, 0.33, 0.12), Color(0.33, 0.45, 0.18))
	grass.roughness = 0.95
	grass.uv1_scale = Vector3(0.5, 0.5, 1)
	var gravel := StandardMaterial3D.new()
	gravel.albedo_texture = _noise_tex(0.4, Color(0.55, 0.50, 0.42), Color(0.75, 0.70, 0.60))
	gravel.roughness = 1.0
	return {"asphalt": asphalt, "curb": curb, "grass": grass, "gravel": gravel}

# ------------------------------------------------------------------
func _build_barriers() -> void:
	# tyre-wall/armco barrier at the outer edge of each shoulder
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var m := pts.size()
	var h := 1.1
	for side in [-1.0, 1.0]:
		for i in m:
			var j := (i + 1) % m
			var oi: float = side * _outer_edge(i, side)
			var oj: float = side * _outer_edge(j, side)
			var a := _point(i, oi) + Vector3.DOWN * 0.7
			var b := _point(j, oj) + Vector3.DOWN * 0.7
			var at := a + Vector3.UP * (h + 0.7)
			var bt := b + Vector3.UP * (h + 0.7)
			var col := Color(0.82, 0.82, 0.85) if int(dist[i] / 10.0) % 2 == 0 else Color(0.2, 0.35, 0.75)
			st.set_color(col)
			var n: Vector3 = rights[i] * -side
			for v in [a, b, bt, a, bt, at]:
				st.set_normal(n)
				st.add_vertex(v)
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.4
	mat.metallic = 0.3
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	add_child(mi)
	var body := StaticBody3D.new()
	body.set_meta("surface", SURF_GRASS)
	var shape := mesh.create_trimesh_shape()
	shape.backface_collision = true
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	var pm := PhysicsMaterial.new()
	pm.friction = 0.3
	pm.bounce = 0.1
	body.physics_material_override = pm
	add_child(body)

func _outer_edge(i: int, side: float) -> float:
	var b := _bands(i)
	return absf(b[0][0]) if side < 0.0 else absf(b[b.size() - 1][1])

# ------------------------------------------------------------------
func _build_terrain() -> void:
	var size := 1600.0
	var res := 10.0
	var center := Vector3(250, 0, 0)
	var n := int(size / res) + 1
	var coarse: Array[Vector3] = []
	for i in range(0, pts.size(), 4):
		coarse.append(pts[i])
	var heights := PackedFloat32Array()
	heights.resize(n * n)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.004
	for zi in n:
		for xi in n:
			var p := center + Vector3(-size * 0.5 + xi * res, 0, -size * 0.5 + zi * res)
			var bd := 1e12
			var bh := 0.0
			for c in coarse:
				var d := (c.x - p.x) * (c.x - p.x) + (c.z - p.z) * (c.z - p.z)
				if d < bd:
					bd = d; bh = c.y
			var dd := sqrt(bd)
			var hills := (noise.get_noise_2d(p.x, p.z) * 0.5 + 0.5) * 28.0 + 2.0
			var t := smoothstep(28.0, 150.0, dd)
			heights[zi * n + xi] = lerpf(bh - 1.2, hills, t)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for zi in n - 1:
		for xi in n - 1:
			var v := []
			for o in [Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, 0)]:
				var x: int = xi + o.x
				var z: int = zi + o.y
				v.append(center + Vector3(-size * 0.5 + x * res, heights[z * n + x], -size * 0.5 + z * res))
			for q in [v[0], v[1], v[2], v[0], v[2], v[3]]:
				st.set_uv(Vector2(q.x, q.z) / 20.0)
				st.add_vertex(q)
	st.generate_normals()
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _noise_tex(0.03, Color(0.22, 0.34, 0.14), Color(0.38, 0.46, 0.22))
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	var body := StaticBody3D.new()
	body.set_meta("surface", SURF_GRASS)
	var shape := mesh.create_trimesh_shape()
	shape.backface_collision = true
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body)
	_terrain_h = heights
	_terrain_n = n
	_terrain_res = res
	_terrain_origin = center - Vector3(size * 0.5, 0, size * 0.5)

var _terrain_h: PackedFloat32Array
var _terrain_n := 0
var _terrain_res := 10.0
var _terrain_origin := Vector3.ZERO

func terrain_height(x: float, z: float) -> float:
	var fx := (x - _terrain_origin.x) / _terrain_res
	var fz := (z - _terrain_origin.z) / _terrain_res
	var xi := clampi(int(fx), 0, _terrain_n - 2)
	var zi := clampi(int(fz), 0, _terrain_n - 2)
	var tx := clampf(fx - xi, 0, 1)
	var tz := clampf(fz - zi, 0, 1)
	var h00 := _terrain_h[zi * _terrain_n + xi]
	var h10 := _terrain_h[zi * _terrain_n + xi + 1]
	var h01 := _terrain_h[(zi + 1) * _terrain_n + xi]
	var h11 := _terrain_h[(zi + 1) * _terrain_n + xi + 1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)

# ------------------------------------------------------------------
func _build_scenery() -> void:
	_build_trees()
	_build_grandstand()
	_build_gantry()

func _build_trees() -> void:
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.25; trunk.bottom_radius = 0.35; trunk.height = 3.0
	trunk.radial_segments = 6
	var crown := CylinderMesh.new()
	crown.top_radius = 0.0; crown.bottom_radius = 3.2; crown.height = 9.0
	crown.radial_segments = 8
	var tm := StandardMaterial3D.new()
	tm.albedo_color = Color(0.32, 0.22, 0.14)
	var cm := StandardMaterial3D.new()
	cm.albedo_color = Color(0.12, 0.26, 0.11)
	cm.roughness = 1.0
	trunk.material = tm
	crown.material = cm
	var rng := RandomNumberGenerator.new()
	rng.seed = 1996
	var positions := []
	var m := pts.size()
	for i in range(0, m, 3):
		for side in [-1.0, 1.0]:
			if rng.randf() < 0.55:
				continue
			var off: float = side * (_outer_edge(i, side) + rng.randf_range(8.0, 70.0))
			var p := _point(i, off)
			# keep clear of every part of the track
			var ni := nearest_index(p)
			if p.distance_to(pts[ni]) < _outer_edge(ni, side) + 6.0:
				continue
			p.y = terrain_height(p.x, p.z)
			positions.append([p, rng.randf_range(0.7, 1.4), rng.randf() * TAU])
	for pair in [[trunk, 1.5], [crown, 7.5]]:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = pair[0]
		mm.instance_count = positions.size()
		for k in positions.size():
			var e: Array = positions[k]
			var s: float = e[1]
			var b := Basis(Vector3.UP, e[2]).scaled(Vector3(s, s, s))
			mm.set_instance_transform(k, Transform3D(b, e[0] + Vector3.UP * pair[1] * s))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		add_child(mmi)

func _box(size: Vector3, pos: Vector3, col: Color, basis := Basis(), collide := false) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.7
	bm.material = mat
	mi.mesh = bm
	mi.transform = Transform3D(basis, pos)
	add_child(mi)
	if collide:
		var body := StaticBody3D.new()
		body.transform = mi.transform
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = size
		cs.shape = sh
		body.add_child(cs)
		add_child(body)

func _build_grandstand() -> void:
	var i := start_index
	var side := -1.0
	var base := _point(i, side * (_outer_edge(i, side) + 9.0))
	var b := Basis.looking_at(tangents[i], Vector3.UP)
	var r := rights[i] * side
	for row in 8:
		var p := base + r * (row * 1.6) + Vector3.UP * (row * 0.9 + 0.5)
		_box(Vector3(1.6, 1.0, 70.0), p, Color(0.55, 0.56, 0.6), b.rotated(Vector3.UP, 0.0).orthonormalized())
	_box(Vector3(14.0, 0.4, 72.0), base + r * 6.0 + Vector3.UP * 10.5, Color(0.85, 0.85, 0.88), b)
	# pit building on the other side
	var pb := _point(i, (_outer_edge(i, 1.0) + 10.0))
	_box(Vector3(10.0, 7.0, 90.0), pb + Vector3.UP * 3.5, Color(0.9, 0.9, 0.92), b)

func _build_gantry() -> void:
	var i := start_index
	var b := Basis.looking_at(tangents[i], Vector3.UP)
	var w := road_width * 0.5 + 2.5
	for side in [-1.0, 1.0]:
		_box(Vector3(0.6, 7.0, 0.6), _point(i, side * w) + Vector3.UP * 3.5, Color(0.25, 0.25, 0.28), b)
	_box(Vector3(w * 2.0 + 0.6, 1.4, 0.8), pts[i] + Vector3.UP * 6.8, Color(0.12, 0.12, 0.14), b)
