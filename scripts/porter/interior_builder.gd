class_name InteriorBuilder
extends RefCounted
## Interior parts for the first-person view: the dashboard (a mirrored
## HalfMesh, so every Shape tool works on it), the steering wheel (a disc
## with the photo on it and the gaps between the spokes cut out) and the live
## gauges placed on the dash.

# ---------------------------------------------------------------- dashboard

## Dash templates as side profiles from the windshield base, over the top, down
## the face toward the driver and under to the knee. Points are (toward the
## driver, up) offsets in metres from the top-rear edge of the dash, so
## negative = further forward; the face rows
## (photo) are the ones the driver looks at. Each profile is extruded across
## the cab at three columns (center, middle, door) so it can be reshaped.
const DASH_TEMPLATES := {
	"truck": {"label": "90s truck (flat, square)", "profile": [
		[-0.46, -0.03, "trim"],
		[-0.06, 0.00, "trim"],
		[0.00, -0.05, "photo"],
		[0.00, -0.30, "photo"],
		[-0.16, -0.52, "trim"]]},
	"curved": {"label": "Curved (90s/00s sedan)", "profile": [
		[-0.50, -0.06, "trim"],
		[-0.22, 0.00, "trim"],
		[-0.04, -0.03, "photo"],
		[0.02, -0.14, "photo"],
		[0.00, -0.28, "photo"],
		[-0.12, -0.42, "trim"],
		[-0.20, -0.52, "trim"]]},
	"cockpit": {"label": "Sports cockpit (low, wrap)", "profile": [
		[-0.40, -0.10, "trim"],
		[-0.10, 0.00, "trim"],
		[0.00, -0.06, "photo"],
		[-0.02, -0.22, "photo"],
		[-0.14, -0.36, "trim"],
		[-0.24, -0.44, "trim"]]},
}

## The dash rows of a template: top-rear edge at (z_face, y_top), across to
## half-width hw.
static func dash_frame(project: PorterProject) -> Dictionary:
	var e := project.driver_eye()
	return {"z_face": e.z - 0.62, "y_top": e.y - 0.20, "hw": project.dims["width_m"] * 0.5 - 0.08}

static func dash_from_template(key: String, project: PorterProject) -> HalfMesh:
	var m := HalfMesh.new()
	m.template = "dash_" + key
	var fr := dash_frame(project)
	var z0: float = fr["z_face"]
	var y0: float = fr["y_top"]
	var hw: float = fr["hw"]
	var prof: Array = DASH_TEMPLATES[key]["profile"]
	var cols := [0.0, -hw * 0.5, -hw]
	var grid := []                      # grid[col][row] -> vertex id
	for x in cols:
		var col := PackedInt32Array()
		for p in prof:
			col.append(m.verts.size())
			m.verts.append(Vector3(x, y0 + float(p[1]), z0 + float(p[0])))
		grid.append(col)
	# skin: quads between rows and columns, turned toward the driver / up
	var inside_z := z0 - 0.35
	var inside_y := y0 - 0.30
	for c in cols.size() - 1:
		for r in prof.size() - 1:
			var f := PackedInt32Array([grid[c][r], grid[c][r + 1], grid[c + 1][r + 1], grid[c + 1][r]])
			var ctr := m.face_center(f)
			var out := Vector3(0.0, ctr.y - inside_y, ctr.z - inside_z)
			if m.face_normal(f).dot(out) < 0.0:
				f.reverse()
			m.faces.append(f)
			var a: String = prof[r][2]
			var b: String = prof[r + 1][2]
			m.regions.append("photo:dash" if a == "photo" and b == "photo" else "trim")
	# end cap against the door
	var cap := PackedInt32Array(grid[cols.size() - 1])
	if m.face_normal(cap).x > 0.0:
		cap.reverse()
	m.faces.append(cap)
	m.regions.append("trim")
	return m

## Height of the dash face at (x, y), looking forward from the driver: the
## nearest face toward the driver whose outline contains the point. Returns
## the z on that face, or NAN.
static func dash_z_at(dash: HalfMesh, x: float, y: float) -> float:
	if dash == null:
		return NAN
	var q := Vector2(-absf(x), y)
	var best := NAN
	for f in dash.faces:
		var n := dash.face_normal(f)
		if n.z < 0.15:
			continue
		var poly := PackedVector2Array()
		for i in f:
			poly.append(Vector2(dash.verts[i].x, dash.verts[i].y))
		if not Geometry2D.is_point_in_polygon(q, poly):
			continue
		var c := dash.face_center(f)
		# plane: n . (p - c) = 0  ->  z = c.z - (n.x (x - c.x) + n.y (y - c.y)) / n.z
		var z := c.z - (n.x * (q.x - c.x) + n.y * (q.y - c.y)) / n.z
		if is_nan(best) or z > best:
			best = z
	return best

## Dash outline edges seen from the driver (both halves), as (x, y) pairs.
static func dash_outline(dash: HalfMesh) -> Array:
	var out := []
	if dash == null:
		return out
	for f in dash.faces:
		if dash.face_normal(f).z < 0.05:
			continue
		for k in f.size():
			var a := dash.verts[f[k]]
			var b := dash.verts[f[(k + 1) % f.size()]]
			out.append([Vector2(a.x, a.y), Vector2(b.x, b.y)])
			out.append([Vector2(-a.x, a.y), Vector2(-b.x, b.y)])
	return out

# ---------------------------------------------------------------- gauges

const GAUGE_TYPES := {
	"speedo": {"label": "Speedo", "r": 0.045, "max": 100.0},
	"tach":   {"label": "Tach",   "r": 0.045, "max": 6000.0},
	"fuel":   {"label": "Fuel",   "r": 0.022, "max": 1.0},
	"temp":   {"label": "Temp",   "r": 0.022, "max": 1.0},
	"oil":    {"label": "Oil",    "r": 0.022, "max": 1.0},
	"volts":  {"label": "Volts",  "r": 0.022, "max": 1.0},
}
const NEEDLE_SWEEP := deg_to_rad(240.0)   # full scale, centered on straight up

## A gauge at frame point (x, y) of the dash photo; z is found on the dash.
static func make_gauge(type: String, x: float, y: float, dash: HalfMesh) -> Dictionary:
	var z := dash_z_at(dash, x, y)
	var t: Dictionary = GAUGE_TYPES[type]
	return {"type": type, "x": snappedf(x, 0.001), "y": snappedf(y, 0.001),
		"z": snappedf(z, 0.001) if not is_nan(z) else 0.0, "on_dash": not is_nan(z),
		"r": t["r"], "max": t["max"]}

## Needle angle (radians, 0 = straight up, + = clockwise) for a reading 0..1.
static func needle_angle(fraction: float) -> float:
	return -NEEDLE_SWEEP * 0.5 + NEEDLE_SWEEP * clampf(fraction, 0.0, 1.0)

# ---------------------------------------------------------------- steering wheel

## Steering wheel: a disc of `diameter` and `thickness` with the photo on both
## faces and the drawn holes (unit-circle polygons, u right, v down) cut
## through. Built facing +Z (toward the driver), hub at the origin. One
## surface, UV = photo position, so the rim's edge takes the photo's colour.
static func steering_mesh(diameter: float, thickness: float, holes: Array, sides: int = 24) -> ArrayMesh:
	var pieces := steering_pieces(holes, sides)
	var R := diameter * 0.5
	var hz := thickness * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cut_xs: Array = pieces[1]
	for poly in pieces[0]:
		var tris := Geometry2D.triangulate_polygon(poly)
		for t in range(0, tris.size(), 3):
			var a: Vector2 = poly[tris[t]]
			var b: Vector2 = poly[tris[t + 1]]
			var c: Vector2 = poly[tris[t + 2]]
			for side in [1.0, -1.0]:
				_tri(st, _w(a, R, hz * side), _w(b, R, hz * side), _w(c, R, hz * side), Vector3(0, 0, side), [_uv(a), _uv(b), _uv(c)])
		# walls along the outer rim and the hole edges (not along the split lines)
		var ccw := _signed(poly) > 0.0
		for k in poly.size():
			var p0: Vector2 = poly[k]
			var p1: Vector2 = poly[(k + 1) % poly.size()]
			var on_cut := false
			for cx in cut_xs:
				if absf(p0.x - cx) < 1e-5 and absf(p1.x - cx) < 1e-5:
					on_cut = true
			if on_cut or p0.distance_to(p1) < 1e-6:
				continue
			var d := (p1 - p0).normalized()
			var n2 := Vector2(d.y, -d.x) if ccw else Vector2(-d.y, d.x)     # outward of this piece
			var n := Vector3(n2.x, -n2.y, 0.0)                               # v points down
			var q := [_w(p0, R, hz), _w(p1, R, hz), _w(p1, R, -hz), _w(p0, R, -hz)]
			var uv := [_uv(p0), _uv(p1), _uv(p1), _uv(p0)]
			_tri(st, q[0], q[1], q[2], n, [uv[0], uv[1], uv[2]])
			_tri(st, q[0], q[2], q[3], n, [uv[0], uv[2], uv[3]])
	return st.commit()

## The face of the wheel as simple polygons (unit circle minus the holes),
## plus the x positions of the split lines used to open holes that sat
## inside one piece. Returns [Array[PackedVector2Array], Array[float]].
static func steering_pieces(holes: Array, sides: int = 24) -> Array:
	var disc := PackedVector2Array()
	for i in sides:
		var a := TAU * i / sides
		disc.append(Vector2(cos(a), sin(a)))
	var pieces: Array = [disc]
	var cuts: Array = []
	for h in holes:
		var hole := PackedVector2Array()
		for p in h:
			hole.append(Vector2(p[0], p[1]) if p is Array else p)
		if hole.size() < 3:
			continue
		var next: Array = []
		for poly in pieces:
			if Geometry2D.intersect_polygons(poly, hole).is_empty():
				next.append(poly)
				continue
			var res := Geometry2D.clip_polygons(poly, hole)
			if not _has_hole(res, poly):
				next.append_array(res)
				continue
			# the hole is inside this piece: split it through the hole first
			var cx := 0.0
			for p in hole:
				cx += p.x
			cx /= hole.size()
			cuts.append(cx)
			for half in [PackedVector2Array([Vector2(-9, -9), Vector2(cx, -9), Vector2(cx, 9), Vector2(-9, 9)]),
					PackedVector2Array([Vector2(cx, -9), Vector2(9, -9), Vector2(9, 9), Vector2(cx, 9)])]:
				for part in Geometry2D.intersect_polygons(poly, half):
					next.append_array(Geometry2D.clip_polygons(part, hole))
		pieces = next
	return [pieces, cuts]

static func _has_hole(res: Array, src: PackedVector2Array) -> bool:
	var cw := Geometry2D.is_polygon_clockwise(src)
	for r in res:
		if Geometry2D.is_polygon_clockwise(r) != cw:
			return true
	return false

static func _signed(poly: PackedVector2Array) -> float:
	var s := 0.0
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		s += a.x * b.y - b.x * a.y
	return s * 0.5

## Unit-circle point (u right, v down) -> wheel space (x right, y up).
static func _w(p: Vector2, R: float, z: float) -> Vector3:
	return Vector3(p.x * R, -p.y * R, z)

static func _uv(p: Vector2) -> Vector2:
	return (p + Vector2.ONE) * 0.5

## Emit a triangle as a Godot front face for normal n.
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3, uv: Array) -> void:
	var pts := [a, b, c]
	var order := [0, 1, 2]
	if (b - a).cross(c - a).dot(n) > 0.0:
		order = [0, 2, 1]
	for k in order:
		st.set_normal(n)
		st.set_uv(uv[k])
		st.add_vertex(pts[k])

## Area of the wheel face left after the holes (unit circle = PI).
static func face_area(holes: Array, sides: int = 24) -> float:
	var a := 0.0
	for poly in steering_pieces(holes, sides)[0]:
		a += absf(_signed(poly))
	return a

## Placement of the wheel: hub at `center`, face turned toward the driver and
## tilted back by tilt_deg (top leaning toward the windshield).
static func steering_transform(center: Vector3, tilt_deg: float, steer_angle: float = 0.0) -> Transform3D:
	var b := Basis(Vector3.RIGHT, deg_to_rad(-tilt_deg)) * Basis(Vector3.BACK, -steer_angle)
	return Transform3D(b, center)

# ---------------------------------------------------------------- inside panels

## Body faces an interior photo suits (used for the outline before anything
## is painted, and by Auto): door = side panels, ceiling = roof, pillar =
## panels next to the windshield that aren't roof.
static func suits_inner_photo(m: HalfMesh, view: String) -> Array:
	var out := []
	var glass_front := {}
	if view == "pillar":
		for fi in m.faces.size():
			if HalfMesh.region_base(m.regions[fi]) == "glass" and m.face_normal(m.faces[fi]).z < -0.4:
				var f: PackedInt32Array = m.faces[fi]
				for k in f.size():
					glass_front[HalfMesh.edge_key(f[k], f[(k + 1) % f.size()])] = true
	for fi in m.faces.size():
		if HalfMesh.region_base(m.regions[fi]) == "glass":
			continue
		var f: PackedInt32Array = m.faces[fi]
		var n := m.face_normal(f)
		match view:
			"door":
				if n.x < -0.6:
					out.append(fi)
			"ceiling":
				if n.y > 0.6:
					out.append(fi)
			"pillar":
				if n.y > 0.8:
					continue
				for k in f.size():
					if glass_front.has(HalfMesh.edge_key(f[k], f[(k + 1) % f.size()])):
						out.append(fi)
						break
	return out

## One-tap inside paint: ceiling / doors / pillars take their photos where
## loaded (else grey cloth / dark plastic), the floor is carpet. Returns the
## number of faces painted.
static func auto_inside(m: HalfMesh, has_photo: Dictionary) -> int:
	var n_done := 0
	var assign := {}
	for fi in m.faces.size():
		if HalfMesh.region_base(m.regions[fi]) == "glass":
			continue
		var n := m.face_normal(m.faces[fi])
		if n.y < -0.6:
			assign[fi] = "carpet"
		elif n.y > 0.6:
			assign[fi] = "photo:ceiling" if has_photo.get("ceiling", false) else "lining"
	for fi in suits_inner_photo(m, "door"):
		assign[fi] = "photo:door" if has_photo.get("door", false) else "dark"
	for fi in suits_inner_photo(m, "pillar"):
		assign[fi] = "photo:pillar" if has_photo.get("pillar", false) else "lining"
	for fi in assign:
		m.set_inner_region([fi], assign[fi])
		n_done += 1
	return n_done
