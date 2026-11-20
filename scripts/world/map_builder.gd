class_name MapBuilder
extends Node3D
## Builds a drivable map from a JSON description (data/maps/*.json).
##
## The format is deliberately generic so it can be produced by a converter
## from real map data (OpenStreetMap roads/buildings + elevation) for town
## maps, as well as written by hand for test facilities.
##
##   roads:     polylines [[x, y, z], ...] with width, surface, shoulder,
##              markings, bump sections and painted cross lines
##   pads:      flat paved areas (rect / disk) with optional paint (rings)
##   buildings: footprint boxes (rect) with height and colour
##   props:     cones (physics), signs (board + text)
##   spawn:     start position + heading
## Coordinates: metres, x = east, z = south, y = up.

const SURFACES := {
	"asphalt": {"name": "asphalt", "mu": 1.0, "crr": 0.0},
	"concrete": {"name": "concrete", "mu": 0.98, "crr": 0.0},
	"curb": {"name": "curb", "mu": 0.92, "crr": 0.002},
	"grass": {"name": "grass", "mu": 0.55, "crr": 0.06},
	"gravel": {"name": "gravel", "mu": 0.62, "crr": 0.20},
	"dirt": {"name": "dirt", "mu": 0.68, "crr": 0.035},
}
const LAYER_WORLD := 1
const LAYER_PROPS := 2

var data: Dictionary = {}
var map_name := ""
var _tools := {}                     # surface name -> SurfaceTool
var _paint: SurfaceTool
var _samples: Array = []             # [x, z, y, flat_radius] for terrain blending
var _hash := {}                      # Vector2i cell -> Array of sample indices
const CELL := 50.0
var road_lines: Array = []           # Array[PackedVector3Array] for minimap/reset
var road_tangents: Array = []
var _bounds := Rect2()
var _noise := FastNoiseLite.new()
var terrain_base := 0.0
var hill_amp := 12.0

func build_from_file(path: String) -> void:
	data = JSON.parse_string(FileAccess.get_file_as_string(path))
	map_name = data.get("name", "Map")
	_noise.seed = int(data.get("seed", 7))
	_noise.frequency = 0.0035
	var tcfg: Dictionary = data.get("terrain", {})
	terrain_base = tcfg.get("base", 0.0)
	hill_amp = tcfg.get("hill_amplitude", 12.0)
	for s in SURFACES:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_tools[s] = st
	_paint = SurfaceTool.new()
	_paint.begin(Mesh.PRIMITIVE_TRIANGLES)
	for r in data.get("roads", []):
		_build_road(r)
	for p in data.get("pads", []):
		_build_pad(p)
	_commit_surfaces()
	_build_hash()
	_build_terrain(tcfg)
	for b in data.get("buildings", []):
		_build_building(b)
	for p in data.get("props", []):
		_build_prop(p)
	_build_trees(tcfg)

# =====================================================================
# Roads
# =====================================================================
func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)

func _resample(ctrl: Array, closed: bool, step: float) -> PackedVector3Array:
	var c: Array[Vector3] = []
	for p in ctrl:
		c.append(Vector3(p[0], p[1], p[2]))
	var n := c.size()
	var dense: Array[Vector3] = []
	var segs := n if closed else n - 1
	for i in segs:
		var p1 := c[i]
		var p2 := c[(i + 1) % n]
		var p0: Vector3 = c[(i - 1 + n) % n] if (closed or i > 0) else p1 * 2.0 - p2
		var p3: Vector3 = c[(i + 2) % n] if (closed or i + 2 < n) else p2 * 2.0 - p1
		var k := maxi(4, int(p1.distance_to(p2) / 0.5))
		for s in k:
			var tt := float(s) / k
			var q := _catmull(p0, p1, p2, p3, tt)
			# elevation: straight grade between control points (no spline
			# overshoot dipping the road into the ground); smoothed below
			q.y = lerpf(p1.y, p2.y, tt)
			dense.append(q)
	if not closed:
		dense.append(c[n - 1])
	var out := PackedVector3Array()
	out.append(dense[0])
	var acc := 0.0
	for i in range(1, dense.size()):
		var a := dense[i - 1]
		var b := dense[i]
		var d := a.distance_to(b)
		acc += d
		while acc >= step:
			acc -= step
			out.append(a.lerp(b, 1.0 - acc / d))
	if closed and out[out.size() - 1].distance_to(out[0]) < step * 0.5:
		out.remove_at(out.size() - 1)
	elif not closed and out[out.size() - 1].distance_to(dense[dense.size() - 1]) > 0.1:
		out.append(dense[dense.size() - 1])
	_smooth_elevation(out, closed, step, 12.0)
	return out

## Round off grade changes (vertical curves) with a moving average ~window m wide.
func _smooth_elevation(pts: PackedVector3Array, closed: bool, step: float, window: float) -> void:
	var n := pts.size()
	var half := maxi(1, int(window * 0.5 / step))
	for _pass in 2:
		var ys := PackedFloat32Array()
		ys.resize(n)
		for i in n:
			var s := 0.0
			var c := 0
			for k in range(-half, half + 1):
				var j := i + k
				if closed:
					j = (j + n) % n
				elif j < 0 or j >= n:
					continue
				s += pts[j].y
				c += 1
			ys[i] = s / c
		for i in n:
			pts[i].y = ys[i]

func _build_road(r: Dictionary) -> void:
	var closed: bool = r.get("closed", false)
	var bumps: Array = r.get("bumps", [])
	var step := 2.0
	for b in bumps:
		step = minf(step, clampf(float(b["wavelength"]) / 4.0, 0.25, 2.0))
	var pts := _resample(r["points"], closed, step)
	var m := pts.size()
	var w: float = r.get("width", 8.0)
	var surf: String = r.get("surface", "asphalt")
	var sh: Dictionary = r.get("shoulder", {"width": 2.0, "surface": "grass"})
	var shw: float = sh.get("width", 2.0)
	var shs: String = sh.get("surface", "grass")
	# per-sample frame and distance
	var tang := PackedVector3Array()
	var right := PackedVector3Array()
	var dist := PackedFloat32Array()
	tang.resize(m); right.resize(m); dist.resize(m)
	var acc := 0.0
	for i in m:
		var prev: Vector3 = pts[(i - 1 + m) % m] if (closed or i > 0) else pts[i]
		var nxt: Vector3 = pts[(i + 1) % m] if (closed or i < m - 1) else pts[i]
		var t := (nxt - prev).normalized()
		tang[i] = t
		right[i] = Vector3(t.x, 0, t.z).normalized().cross(Vector3.UP).normalized()
		dist[i] = acc
		if i < m - 1 or closed:
			acc += pts[i].distance_to(pts[(i + 1) % m])
	# bump profile (whoops / washboard)
	for i in m:
		var off := 0.0
		for b in bumps:
			if dist[i] >= b["from"] and dist[i] <= b["to"]:
				var lam: float = b["wavelength"]
				off += b["amp"] * 0.5 * (1.0 - cos(TAU * (dist[i] - b["from"]) / lam))
		pts[i].y += off
	road_lines.append(pts)
	road_tangents.append(tang)
	var hw := w * 0.5
	var segs := m if closed else m - 1
	for i in segs:
		var j := (i + 1) % m
		_ribbon(_tools[surf], pts, right, dist, i, j, -hw, hw, 0.0, 0.0)
		_ribbon(_tools[shs], pts, right, dist, i, j, -hw - shw, -hw, -0.06, 0.0)
		_ribbon(_tools[shs], pts, right, dist, i, j, hw, hw + shw, 0.0, -0.06)
		# skirts hide the gap down to the terrain
		_skirt(_tools[shs], pts, right, i, j, -hw - shw, -0.06)
		_skirt(_tools[shs], pts, right, i, j, hw + shw, -0.06)
	# markings
	var mk: Dictionary = r.get("markings", {})
	if mk.get("edge", false):
		for i in segs:
			var j := (i + 1) % m
			_ribbon(_paint, pts, right, dist, i, j, -hw + 0.15, -hw + 0.32, 0.012, 0.012, Color(0.93, 0.93, 0.9))
			_ribbon(_paint, pts, right, dist, i, j, hw - 0.32, hw - 0.15, 0.012, 0.012, Color(0.93, 0.93, 0.9))
	var center: String = mk.get("center", "")
	if center != "":
		var col := Color(0.95, 0.75, 0.1) if mk.get("center_color", "yellow") == "yellow" else Color(0.93, 0.93, 0.9)
		for i in segs:
			var j := (i + 1) % m
			if center == "dashed" and int(dist[i] / 4.5) % 2 == 1:
				continue
			_ribbon(_paint, pts, right, dist, i, j, -0.08, 0.08, 0.012, 0.012, col)
	for cl in r.get("cross_lines", []):
		_cross_line(pts, right, dist, cl, w)
	# terrain samples every ~8 m
	var every := maxi(1, int(8.0 / step))
	for i in range(0, m, every):
		_add_sample(pts[i], hw + shw)
	_grow_bounds(pts)

func _ribbon(st: SurfaceTool, pts: PackedVector3Array, right: PackedVector3Array, dist: PackedFloat32Array,
		i: int, j: int, o0: float, o1: float, y0: float, y1: float, col: Color = Color.WHITE) -> void:
	var a0 := pts[i] + right[i] * o0 + Vector3.UP * y0
	var a1 := pts[i] + right[i] * o1 + Vector3.UP * y1
	var b0 := pts[j] + right[j] * o0 + Vector3.UP * y0
	var b1 := pts[j] + right[j] * o1 + Vector3.UP * y1
	var u0 := dist[i] / 6.0
	var u1 := u0 + pts[i].distance_to(pts[j]) / 6.0
	var n := (b0 - a0).cross(a1 - a0).normalized()
	if n.y < 0.0:
		n = -n
	st.set_color(col)
	for v in [[a0, Vector2(o0 / 6.0, u0)], [b0, Vector2(o0 / 6.0, u1)], [b1, Vector2(o1 / 6.0, u1)],
			[a0, Vector2(o0 / 6.0, u0)], [b1, Vector2(o1 / 6.0, u1)], [a1, Vector2(o1 / 6.0, u0)]]:
		st.set_normal(n)
		st.set_uv(v[1])
		st.add_vertex(v[0])

func _skirt(st: SurfaceTool, pts: PackedVector3Array, right: PackedVector3Array, i: int, j: int, o: float, y: float) -> void:
	var a := pts[i] + right[i] * o + Vector3.UP * y
	var b := pts[j] + right[j] * o + Vector3.UP * y
	var a2 := a + Vector3.DOWN * 1.2
	var b2 := b + Vector3.DOWN * 1.2
	var n := right[i] * signf(o)
	for v in [a, b, b2, a, b2, a2]:
		st.set_normal(n)
		st.set_uv(Vector2(v.x, v.y) / 6.0)
		st.add_vertex(v)

func _cross_line(pts: PackedVector3Array, right: PackedVector3Array, dist: PackedFloat32Array, cl: Dictionary, w: float) -> void:
	var at: float = cl["at"]
	var i := 0
	while i < pts.size() - 1 and dist[i + 1] < at:
		i += 1
	var t := clampf((at - dist[i]) / maxf(dist[mini(i + 1, pts.size() - 1)] - dist[i], 0.01), 0.0, 1.0)
	var p := pts[i].lerp(pts[mini(i + 1, pts.size() - 1)], t)
	var fwd := (pts[mini(i + 1, pts.size() - 1)] - pts[i]).normalized()
	var r := right[i]
	var thick: float = cl.get("thickness", 0.5)
	var c: Array = cl.get("color", [0.95, 0.95, 0.95])
	var col := Color(c[0], c[1], c[2])
	var hw := w * 0.5 - 0.1
	var q := [p - r * hw - fwd * thick * 0.5, p + r * hw - fwd * thick * 0.5, p + r * hw + fwd * thick * 0.5, p - r * hw + fwd * thick * 0.5]
	_paint.set_color(col)
	for v in [q[0], q[3], q[2], q[0], q[2], q[1]]:
		_paint.set_normal(Vector3.UP)
		_paint.add_vertex(v + Vector3.UP * 0.014)
	if cl.has("label"):
		var side: float = cl.get("label_side", 1.0)
		var sp := p + r * side * (w * 0.5 + 3.5)
		_add_sign(sp, atan2(-fwd.x, -fwd.z), str(cl["label"]), Vector2(3.2, 1.0))

# =====================================================================
# Pads
# =====================================================================
func _build_pad(p: Dictionary) -> void:
	var c: Array = p["center"]
	var center := Vector3(c[0], c[1], c[2])
	var surf: String = p.get("surface", "asphalt")
	var st: SurfaceTool = _tools[surf]
	var shape: String = p.get("shape", "rect")
	var y: float = center.y + p.get("lift", 0.0)
	if shape == "disk":
		var r: float = p["radius"]
		var segs := 48
		for k in segs:
			var a0 := TAU * k / segs
			var a1 := TAU * (k + 1) / segs
			var v0 := Vector3(center.x, y, center.z)
			var v1 := Vector3(center.x + cos(a0) * r, y, center.z + sin(a0) * r)
			var v2 := Vector3(center.x + cos(a1) * r, y, center.z + sin(a1) * r)
			for v in [v0, v2, v1]:
				st.set_color(Color.WHITE)
				st.set_normal(Vector3.UP)
				st.set_uv(Vector2(v.x, v.z) / 6.0)
				st.add_vertex(v)
			var d1 := v1 + Vector3.DOWN * 1.2
			var d2 := v2 + Vector3.DOWN * 1.2
			for v in [v1, v2, d2, v1, d2, d1]:
				st.set_normal((v1 - v0).normalized())
				st.set_uv(Vector2(v.x, v.y) / 6.0)
				st.add_vertex(v)
		for a in range(0, 360, 20):
			_add_sample(center + Vector3(cos(deg_to_rad(a)) * r * 0.6, 0, sin(deg_to_rad(a)) * r * 0.6), r * 0.45)
		_add_sample(center, r)
		_grow_bounds(PackedVector3Array([center + Vector3(-r, 0, -r), center + Vector3(r, 0, r)]))
	else:
		var sz: Array = p["size"]
		var hx: float = sz[0] * 0.5
		var hz: float = sz[1] * 0.5
		var b := Basis(Vector3.UP, deg_to_rad(p.get("rotation", 0.0)))
		var cs := [Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz)]
		var w := []
		for v in cs:
			w.append(Vector3(center.x, y, center.z) + b * v)
		for v in [w[0], w[1], w[2], w[0], w[2], w[3]]:
			st.set_color(Color.WHITE)
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(v.x, v.z) / 6.0)
			st.add_vertex(v)
		for k in 4:
			var a: Vector3 = w[k]
			var bb: Vector3 = w[(k + 1) % 4]
			var n := (bb - a).cross(Vector3.UP).normalized()
			for v in [a, bb, bb + Vector3.DOWN * 1.2, a, bb + Vector3.DOWN * 1.2, a + Vector3.DOWN * 1.2]:
				st.set_normal(n)
				st.set_uv(Vector2(v.x + v.z, v.y) / 6.0)
				st.add_vertex(v)
		var step := 15.0
		var x := -hx
		while x <= hx:
			var z := -hz
			while z <= hz:
				_add_sample(Vector3(center.x, y, center.z) + b * Vector3(x, 0, z), step)
				z += step
			x += step
		_grow_bounds(PackedVector3Array(w))
	for paint in p.get("paint", []):
		if paint["type"] == "ring":
			_paint_ring(Vector3(center.x, y, center.z), paint["radius"], paint.get("width", 0.3), paint.get("color", [0.95, 0.95, 0.95]))

func _paint_ring(c: Vector3, r: float, w: float, col: Array) -> void:
	var segs := 96
	_paint.set_color(Color(col[0], col[1], col[2]))
	for k in segs:
		var a0 := TAU * k / segs
		var a1 := TAU * (k + 1) / segs
		var i0 := c + Vector3(cos(a0), 0, sin(a0)) * (r - w * 0.5) + Vector3.UP * 0.014
		var o0 := c + Vector3(cos(a0), 0, sin(a0)) * (r + w * 0.5) + Vector3.UP * 0.014
		var i1 := c + Vector3(cos(a1), 0, sin(a1)) * (r - w * 0.5) + Vector3.UP * 0.014
		var o1 := c + Vector3(cos(a1), 0, sin(a1)) * (r + w * 0.5) + Vector3.UP * 0.014
		for v in [i0, i1, o1, i0, o1, o0]:
			_paint.set_normal(Vector3.UP)
			_paint.add_vertex(v)

# =====================================================================
# Surfaces → meshes + collision
# =====================================================================
func _noise_tex(freq: float, c0: Color, c1: Color) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.frequency = freq
	n.fractal_octaves = 4
	var t := NoiseTexture2D.new()
	t.noise = n
	t.width = 512; t.height = 512
	t.seamless = true
	var g := Gradient.new()
	g.set_color(0, c0)
	g.set_color(1, c1)
	t.color_ramp = g
	t.generate_mipmaps = true
	return t

func surface_material(name: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	match name:
		"asphalt":
			m.albedo_texture = _noise_tex(0.09, Color(0.17, 0.17, 0.18), Color(0.30, 0.30, 0.31))
			m.roughness = 0.82
		"concrete":
			m.albedo_texture = _noise_tex(0.06, Color(0.52, 0.52, 0.50), Color(0.66, 0.66, 0.63))
			m.roughness = 0.9
		"curb":
			m.vertex_color_use_as_albedo = true
			m.roughness = 0.5
		"grass":
			m.albedo_texture = _noise_tex(0.05, Color(0.20, 0.33, 0.12), Color(0.33, 0.45, 0.18))
			m.roughness = 0.95
		"gravel":
			m.albedo_texture = _noise_tex(0.4, Color(0.55, 0.50, 0.42), Color(0.75, 0.70, 0.60))
			m.roughness = 1.0
		"dirt":
			m.albedo_texture = _noise_tex(0.12, Color(0.36, 0.27, 0.18), Color(0.52, 0.41, 0.28))
			m.roughness = 1.0
	return m

func _commit_surfaces() -> void:
	for name in _tools:
		var st: SurfaceTool = _tools[name]
		var mesh := st.commit()
		if mesh.get_surface_count() == 0:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = surface_material(name)
		add_child(mi)
		var body := StaticBody3D.new()
		body.collision_layer = LAYER_WORLD
		body.set_meta("surface", SURFACES[name])
		var shape := mesh.create_trimesh_shape()
		shape.backface_collision = true
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		add_child(body)
	var pm := _paint.commit()
	if pm.get_surface_count() > 0:
		var mi := MeshInstance3D.new()
		mi.mesh = pm
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.7
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)

# =====================================================================
# Terrain
# =====================================================================
func _add_sample(p: Vector3, flat_r: float) -> void:
	_samples.append([p.x, p.z, p.y, flat_r])

func _grow_bounds(pts: PackedVector3Array) -> void:
	for p in pts:
		var v := Vector2(p.x, p.z)
		if _bounds.size == Vector2.ZERO and _bounds.position == Vector2.ZERO:
			_bounds = Rect2(v, Vector2(0.01, 0.01))
		else:
			_bounds = _bounds.expand(v)

func _build_hash() -> void:
	_hash.clear()
	for i in _samples.size():
		var s: Array = _samples[i]
		var k := Vector2i(floori(s[0] / CELL), floori(s[1] / CELL))
		if not _hash.has(k):
			_hash[k] = []
		_hash[k].append(i)

## Nearest paved sample: returns [distance beyond flat radius, height] or [] if none nearby.
func _nearest_sample(x: float, z: float, rings: int = 3) -> Array:
	var cx := floori(x / CELL)
	var cz := floori(z / CELL)
	var best := 1e12
	var bh := 0.0
	var found := false
	for dx in range(-rings, rings + 1):
		for dz in range(-rings, rings + 1):
			var k := Vector2i(cx + dx, cz + dz)
			if not _hash.has(k):
				continue
			for i in _hash[k]:
				var s: Array = _samples[i]
				var d: float = sqrt((s[0] - x) * (s[0] - x) + (s[1] - z) * (s[1] - z)) - s[3]
				if d < best:
					best = d; bh = s[2]; found = true
	return [best, bh] if found else []

func hills(x: float, z: float) -> float:
	return terrain_base + (_noise.get_noise_2d(x, z) * 0.5 + 0.5) * hill_amp

func ground_height(x: float, z: float) -> float:
	var ns := _nearest_sample(x, z)
	if ns.is_empty():
		return hills(x, z)
	var t := smoothstep(6.0, 140.0, ns[0])
	return lerpf(ns[1] - 0.7, hills(x, z), t)

func _build_terrain(cfg: Dictionary) -> void:
	var margin: float = cfg.get("margin", 350.0)
	var res: float = cfg.get("resolution", 10.0)
	var r := _bounds.grow(margin)
	var nx := int(r.size.x / res) + 1
	var nz := int(r.size.y / res) + 1
	var h := PackedFloat32Array()
	h.resize(nx * nz)
	for zi in nz:
		for xi in nx:
			h[zi * nx + xi] = ground_height(r.position.x + xi * res, r.position.y + zi * res)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for zi in nz - 1:
		for xi in nx - 1:
			var v: Array[Vector3] = []
			for o in [Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, 0)]:
				var x: int = xi + o.x
				var z: int = zi + o.y
				v.append(Vector3(r.position.x + x * res, h[z * nx + x], r.position.y + z * res))
			for q in [v[0], v[1], v[2], v[0], v[2], v[3]]:
				st.set_uv(Vector2(q.x, q.z) / 20.0)
				st.add_vertex(q)
	st.generate_normals()
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := surface_material("grass")
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_WORLD
	body.set_meta("surface", SURFACES["grass"])
	var shape := mesh.create_trimesh_shape()
	shape.backface_collision = true
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body)
	# invisible boundary walls around the terrain edge
	for side in 4:
		var wall := StaticBody3D.new()
		wall.collision_layer = LAYER_WORLD
		var wcs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		var horiz := side < 2
		box.size = Vector3(r.size.x if horiz else 2.0, 200.0, 2.0 if horiz else r.size.y)
		wcs.shape = box
		var c := r.get_center()
		match side:
			0: wcs.position = Vector3(c.x, 50, r.position.y + 20)
			1: wcs.position = Vector3(c.x, 50, r.end.y - 20)
			2: wcs.position = Vector3(r.position.x + 20, 50, c.y)
			3: wcs.position = Vector3(r.end.x - 20, 50, c.y)
		wall.add_child(wcs)
		add_child(wall)

func _build_trees(cfg: Dictionary) -> void:
	var count: int = cfg.get("trees", 600)
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.25; trunk.bottom_radius = 0.35; trunk.height = 3.0; trunk.radial_segments = 6
	var crown := CylinderMesh.new()
	crown.top_radius = 0.0; crown.bottom_radius = 3.2; crown.height = 9.0; crown.radial_segments = 8
	var tm := StandardMaterial3D.new()
	tm.albedo_color = Color(0.32, 0.22, 0.14)
	var cm := StandardMaterial3D.new()
	cm.albedo_color = Color(0.12, 0.26, 0.11)
	cm.roughness = 1.0
	trunk.material = tm
	crown.material = cm
	var rng := RandomNumberGenerator.new()
	rng.seed = int(data.get("seed", 7)) + 11
	var r := _bounds.grow(cfg.get("margin", 350.0) - 40.0)
	var pos := []
	var tries := 0
	while pos.size() < count and tries < count * 6:
		tries += 1
		var x := rng.randf_range(r.position.x, r.end.x)
		var z := rng.randf_range(r.position.y, r.end.y)
		var ns := _nearest_sample(x, z, 2)
		if not ns.is_empty() and ns[0] < 14.0:
			continue
		pos.append([Vector3(x, ground_height(x, z), z), rng.randf_range(0.7, 1.4), rng.randf() * TAU])
	for pair in [[trunk, 1.5], [crown, 7.5]]:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = pair[0]
		mm.instance_count = pos.size()
		for k in pos.size():
			var e: Array = pos[k]
			var s: float = e[1]
			mm.set_instance_transform(k, Transform3D(Basis(Vector3.UP, e[2]).scaled(Vector3(s, s, s)), e[0] + Vector3.UP * pair[1] * s))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		add_child(mmi)

# =====================================================================
# Buildings & props
# =====================================================================
func _box(size: Vector3, xf: Transform3D, col: Color, collide: bool) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.75
	bm.material = mat
	mi.mesh = bm
	mi.transform = xf
	add_child(mi)
	if collide:
		var body := StaticBody3D.new()
		body.collision_layer = LAYER_WORLD
		body.transform = xf
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = size
		cs.shape = sh
		body.add_child(cs)
		add_child(body)

func _build_building(b: Dictionary) -> void:
	var c: Array = b["center"]
	var sz: Array = b["size"]
	var hgt: float = b.get("height", 6.0)
	var y: float = c[1] if c.size() > 2 else ground_height(c[0], c[c.size() - 1])
	var pos := Vector3(c[0], y, c[2])
	var basis := Basis(Vector3.UP, deg_to_rad(b.get("rotation", 0.0)))
	var col: Array = b.get("color", [0.85, 0.85, 0.82])
	_box(Vector3(sz[0], hgt, sz[1]), Transform3D(basis, pos + Vector3.UP * hgt * 0.5), Color(col[0], col[1], col[2]), true)
	var roof: Array = b.get("roof_color", [0.35, 0.36, 0.40])
	_box(Vector3(sz[0] + 0.6, 0.4, sz[1] + 0.6), Transform3D(basis, pos + Vector3.UP * (hgt + 0.2)), Color(roof[0], roof[1], roof[2]), false)
	var doors: int = b.get("doors", 0)
	for k in doors:
		var dx: float = -sz[0] * 0.5 + sz[0] * (k + 0.5) / doors
		_box(Vector3(sz[0] / doors * 0.7, hgt * 0.65, 0.1), Transform3D(basis, pos + basis * Vector3(dx, hgt * 0.325, sz[1] * 0.5 + 0.05)), Color(0.25, 0.27, 0.3), false)
	if b.has("label"):
		var l := Label3D.new()
		l.text = b["label"]
		l.font_size = 160
		l.pixel_size = 0.01
		l.modulate = Color(0.1, 0.15, 0.3)
		l.transform = Transform3D(basis, pos + basis * Vector3(0, hgt * 0.82, sz[1] * 0.5 + 0.12))
		add_child(l)

func _build_prop(p: Dictionary) -> void:
	match p["type"]:
		"cone":
			_add_cone(Vector3(p["pos"][0], p["pos"][1], p["pos"][2]))
		"cone_row":
			var a := Vector3(p["from"][0], p["from"][1], p["from"][2])
			var b := Vector3(p["to"][0], p["to"][1], p["to"][2])
			var n: int = p["count"]
			for k in n:
				_add_cone(a.lerp(b, float(k) / maxf(n - 1, 1)))
		"sign":
			_add_sign(Vector3(p["pos"][0], p["pos"][1], p["pos"][2]), deg_to_rad(p.get("heading", 0.0)), p["text"], Vector2(p.get("w", 4.0), p.get("h", 1.4)))

var _cone_mesh: Mesh
var _cone_shape: Shape3D
func _add_cone(pos: Vector3) -> void:
	if _cone_mesh == null:
		var cm := CylinderMesh.new()
		cm.top_radius = 0.03; cm.bottom_radius = 0.16; cm.height = 0.7; cm.radial_segments = 10
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.38, 0.05)
		mat.roughness = 0.6
		cm.material = mat
		_cone_mesh = cm
		var sh := CylinderShape3D.new()
		sh.radius = 0.14; sh.height = 0.7
		_cone_shape = sh
	var body := RigidBody3D.new()
	body.mass = 2.5
	body.collision_layer = LAYER_PROPS
	body.collision_mask = LAYER_WORLD | LAYER_PROPS
	body.can_sleep = true
	body.sleeping = true
	var mi := MeshInstance3D.new()
	mi.mesh = _cone_mesh
	body.add_child(mi)
	var base := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.4, 0.04, 0.4)
	base.mesh = bm
	base.position = Vector3(0, -0.33, 0)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.1, 0.1, 0.1)
	bm.material = bmat
	body.add_child(base)
	var cs := CollisionShape3D.new()
	cs.shape = _cone_shape
	body.add_child(cs)
	body.position = pos + Vector3.UP * 0.37
	add_child(body)

func _add_sign(pos: Vector3, heading: float, text: String, size: Vector2) -> void:
	var y := ground_height(pos.x, pos.z) if pos.y == 0.0 and not _hash.is_empty() else pos.y
	var base := Vector3(pos.x, y, pos.z)
	var b := Basis(Vector3.UP, heading)
	_box(Vector3(size.x, size.y, 0.12), Transform3D(b, base + Vector3.UP * (1.4 + size.y * 0.5)), Color(0.95, 0.95, 0.95), false)
	for s in [-1.0, 1.0]:
		_box(Vector3(0.1, 1.4 + size.y * 0.5, 0.1), Transform3D(b, base + b * Vector3(s * size.x * 0.35, (1.4 + size.y * 0.5) * 0.5, -0.08)), Color(0.3, 0.3, 0.32), false)
	for flip in [0.0, PI]:
		var l := Label3D.new()
		l.text = text
		l.font_size = 96
		l.pixel_size = 0.0075 * size.y / 1.0
		l.modulate = Color(0.08, 0.1, 0.18)
		l.outline_size = 0
		l.double_sided = false
		l.transform = Transform3D(b * Basis(Vector3.UP, flip), base + Vector3.UP * (1.4 + size.y * 0.5) + b * Basis(Vector3.UP, flip) * Vector3(0, 0, 0.07))
		add_child(l)

# =====================================================================
# Queries used by the game
# =====================================================================
func spawn_transform() -> Transform3D:
	var s: Dictionary = data.get("spawn", {"pos": [0, 0, 0], "heading": 0})
	var p := Vector3(s["pos"][0], s["pos"][1] + 0.1, s["pos"][2])
	return Transform3D(Basis(Vector3.UP, deg_to_rad(s.get("heading", 0.0))), p)

## Nearest point on any road: [position, tangent].
func nearest_road_point(pos: Vector3) -> Array:
	var best := 1e12
	var bp := Vector3.ZERO
	var bt := Vector3.FORWARD
	for k in road_lines.size():
		var line: PackedVector3Array = road_lines[k]
		var tl: PackedVector3Array = road_tangents[k]
		for i in range(0, line.size(), 2):
			var d := pos.distance_squared_to(line[i])
			if d < best:
				best = d; bp = line[i]; bt = tl[i]
	return [bp, bt]

func minimap_lines() -> Array:
	var out := []
	for line in road_lines:
		var l := PackedVector3Array()
		var step := maxi(1, line.size() / 120)
		for i in range(0, line.size(), step):
			l.append(line[i])
		out.append(l)
	return out

func zone(name: String) -> Dictionary:
	return data.get("zones", {}).get(name, {})
