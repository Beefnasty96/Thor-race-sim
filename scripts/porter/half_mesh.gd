class_name HalfMesh
extends RefCounted
## Low-poly car body stored as its LEFT half (x <= 0); the right half is always
## the mirror image, so every edit is symmetric. Faces are triangles or quads,
## wound counter-clockwise seen from outside (normal points out). Vertices with
## x == 0 lie on the centerline and stay there. The half is open along the
## centerline (no faces in the x = 0 plane).
##
## Coordinates are the game's: metres, +X right, +Y up, -Z forward, origin on
## the ground midway between the axles.

const CENTER_EPS := 0.0005

var verts := PackedVector3Array()
var faces: Array = []               # Array[PackedInt32Array]
var regions: Array = []             # paint region per face (keys of REGIONS), parallel to faces
var template := ""

## Paint regions. "material" is the glTF material name the game looks for
## (Paint / Lower / Glass / Taillight get special handling in CarModel).
const REGIONS := {
	"paint":     {"label": "Body paint",   "color": Color(0.2, 0.25, 0.45), "material": "Paint"},
	"second":    {"label": "Second color", "color": Color(0.62, 0.53, 0.43), "material": "Lower"},
	"glass":     {"label": "Glass",        "color": Color(0.07, 0.09, 0.12), "material": "Glass"},
	"headlight": {"label": "Headlight",    "color": Color(0.9, 0.92, 0.95), "material": "Headlight"},
	"taillight": {"label": "Taillight",    "color": Color(0.62, 0.04, 0.04), "material": "Taillight"},
	"chrome":    {"label": "Chrome",       "color": Color(0.82, 0.83, 0.85), "material": "Chrome"},
	"trim":      {"label": "Black trim",   "color": Color(0.07, 0.07, 0.075), "material": "Trim"},
	"grille":    {"label": "Grille",       "color": Color(0.03, 0.03, 0.035), "material": "Grille"},
	"photo":     {"label": "Photo texture", "color": Color(0.5, 0.5, 0.5), "material": "Photo"},
}

## Paint for the inside of the hollow shell (door cards, pillars, headliner,
## floor). "photo:door" / "photo:pillar" / "photo:ceiling" use the interior
## photos of those names.
const INNER_REGIONS := {
	"dark":   {"label": "Dark plastic", "color": Color(0.16, 0.16, 0.17)},
	"lining": {"label": "Grey cloth",   "color": Color(0.52, 0.52, 0.5)},
	"tan":    {"label": "Tan",          "color": Color(0.62, 0.52, 0.4)},
	"carpet": {"label": "Carpet",       "color": Color(0.1, 0.1, 0.11)},
	"photo":  {"label": "Photo",        "color": Color(0.4, 0.4, 0.42)},
}
const INNER_PHOTOS := ["door", "pillar", "ceiling"]
const INNER_DEFAULT := "dark"

## A face's region string is "outer" or "outer|inner": the paint on the
## outside and, after "|", on the inside of the shell (default dark plastic).
## The outer part may carry a photo source: "photo" (auto) or "photo:side",
## "photo:front", "photo:rear", "photo:top" (or "photo:dash" on the dash).
static func region_outer(r: String) -> String:
	return r.get_slice("|", 0)

static func region_inner(r: String) -> String:
	return r.get_slice("|", 1) if r.contains("|") else INNER_DEFAULT

static func region_join(outer: String, inner: String) -> String:
	return outer if inner == INNER_DEFAULT else outer + "|" + inner

static func region_base(r: String) -> String:
	return region_outer(r).get_slice(":", 0)

static func inner_base(r: String) -> String:
	return region_inner(r).get_slice(":", 0)

static func region_valid(r: String) -> bool:
	var o := region_outer(r)
	var b := o.get_slice(":", 0)
	if not REGIONS.has(b):
		return false
	if b == "photo" and o.contains(":"):
		if not (o.get_slice(":", 1) in ["side", "front", "rear", "top", "dash"]):
			return false
	elif o.contains(":"):
		return false
	if r.contains("|"):
		var i := region_inner(r)
		var ib := i.get_slice(":", 0)
		if not INNER_REGIONS.has(ib):
			return false
		if i.contains(":") and (ib != "photo" or not (i.get_slice(":", 1) in INNER_PHOTOS)):
			return false
	return true

var _undo: Array = []
var _redo: Array = []

# ---------------------------------------------------------------- basics

func is_center(i: int) -> bool:
	return absf(verts[i].x) <= CENTER_EPS

func snapshot() -> Dictionary:
	var f := []
	for face in faces:
		f.append(PackedInt32Array(face))
	return {"v": PackedVector3Array(verts), "f": f, "r": regions.duplicate()}

func restore(s: Dictionary) -> void:
	verts = PackedVector3Array(s["v"])
	faces = []
	for face in s["f"]:
		faces.append(PackedInt32Array(face))
	regions = s.get("r", []).duplicate()
	_fix_regions()

## Keep one region per face (older saves / new faces default to body paint).
func _fix_regions() -> void:
	while regions.size() < faces.size():
		regions.append("paint")
	if regions.size() > faces.size():
		regions.resize(faces.size())

func region_of(fi: int) -> String:
	return region_outer(regions[fi]) if fi < regions.size() else "paint"

func inner_region_of(fi: int) -> String:
	return region_inner(regions[fi]) if fi < regions.size() else INNER_DEFAULT

## Paint the outside of faces (the inside paint is kept).
func set_region(face_ids: Array, region: String) -> void:
	_fix_regions()
	for fi in face_ids:
		regions[fi] = region_join(region_outer(region), region_inner(regions[fi]))

## Paint the inside of faces (the outside paint is kept).
func set_inner_region(face_ids: Array, inner: String) -> void:
	_fix_regions()
	for fi in face_ids:
		regions[fi] = region_join(region_outer(regions[fi]), inner)

## Faces connected to `start` (sharing an edge) that have the same region
## (outside paint, or inside paint when inside is true).
func connected_same_region(start: int, inside: bool = false) -> Array:
	_fix_regions()
	var key := func(r: String) -> String: return region_inner(r) if inside else region_outer(r)
	var want: String = key.call(regions[start])
	var by_edge := {}
	for fi in faces.size():
		var f: PackedInt32Array = faces[fi]
		for k in f.size():
			var e := edge_key(f[k], f[(k + 1) % f.size()])
			if not by_edge.has(e):
				by_edge[e] = []
			by_edge[e].append(fi)
	var seen := {start: true}
	var stack := [start]
	while not stack.is_empty():
		var fi: int = stack.pop_back()
		var f: PackedInt32Array = faces[fi]
		for k in f.size():
			for g in by_edge[edge_key(f[k], f[(k + 1) % f.size()])]:
				if not seen.has(g) and key.call(regions[g]) == want:
					seen[g] = true
					stack.append(g)
	return seen.keys()

## Call before an edit so it can be undone.
func push_undo() -> void:
	_undo.append(snapshot())
	if _undo.size() > 60:
		_undo.pop_front()
	_redo.clear()

func undo() -> bool:
	if _undo.is_empty():
		return false
	_redo.append(snapshot())
	restore(_undo.pop_back())
	return true

func redo() -> bool:
	if _redo.is_empty():
		return false
	_undo.append(snapshot())
	restore(_redo.pop_back())
	return true

## Move vertices, keeping centerline vertices on the centerline and the rest
## on the left side.
func move_verts(ids: Array, delta: Vector3) -> void:
	for i in ids:
		var p := verts[i] + delta
		if is_center(i):
			p.x = 0.0
		else:
			p.x = minf(p.x, -CENTER_EPS * 2.0)
		verts[i] = p

func set_vert(i: int, p: Vector3) -> void:
	if is_center(i):
		p.x = 0.0
	else:
		p.x = minf(p.x, -CENTER_EPS * 2.0)
	verts[i] = p

func face_normal(face: PackedInt32Array, vs: PackedVector3Array = verts) -> Vector3:
	# Newell's method: robust for slightly non-planar quads
	var n := Vector3.ZERO
	for k in face.size():
		var a := vs[face[k]]
		var b := vs[face[(k + 1) % face.size()]]
		n.x += (a.y - b.y) * (a.z + b.z)
		n.y += (a.z - b.z) * (a.x + b.x)
		n.z += (a.x - b.x) * (a.y + b.y)
	return n.normalized()

func face_center(face: PackedInt32Array) -> Vector3:
	var c := Vector3.ZERO
	for i in face:
		c += verts[i]
	return c / face.size()

## Triangles in the full (mirrored) body.
func triangle_count() -> int:
	var n := 0
	for f in faces:
		n += f.size() - 2
	return n * 2

static func edge_key(a: int, b: int) -> Vector2i:
	return Vector2i(mini(a, b), maxi(a, b))

## Edge -> number of faces using it.
func edge_use() -> Dictionary:
	var use := {}
	for f in faces:
		for k in f.size():
			var e := edge_key(f[k], f[(k + 1) % f.size()])
			use[e] = use.get(e, 0) + 1
	return use

func edges() -> Array:
	return edge_use().keys()

# ---------------------------------------------------------------- full body

## Full mirrored body as a flat-shaded ArrayMesh (one normal per face, the
## Gran Turismo look). Godot treats clockwise triangles as front-facing.
## colors: region -> Color overrides (e.g. the chosen body paint); with
## plain = true every face is drawn in one neutral grey (shape mode).
func build_mesh(colors: Dictionary = {}, plain: bool = false, skip_glass: bool = false) -> ArrayMesh:
	_fix_regions()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mirrored := PackedVector3Array()
	for p in verts:
		mirrored.append(Vector3(-p.x, p.y, p.z))
	for fi in faces.size():
		var f: PackedInt32Array = faces[fi]
		var reg: String = regions[fi]
		if skip_glass and region_base(reg) == "glass":
			continue
		var base := region_base(reg)
		var col: Color = Color(0.72, 0.74, 0.78) if plain else colors.get(base, REGIONS[base]["color"])
		st.set_color(col)
		_emit_face(st, f, verts)
		var r := PackedInt32Array()
		for k in range(f.size() - 1, -1, -1):
			r.append(f[k])
		_emit_face(st, r, mirrored)
	return st.commit()

func _mirrored_verts() -> PackedVector3Array:
	var m := PackedVector3Array()
	for p in verts:
		m.append(Vector3(-p.x, p.y, p.z))
	return m

static func _reversed(f: PackedInt32Array) -> PackedInt32Array:
	var r := PackedInt32Array()
	for k in range(f.size() - 1, -1, -1):
		r.append(f[k])
	return r

## Glass faces only (both halves), for a see-through material.
func build_glass() -> ArrayMesh:
	_fix_regions()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mirrored := _mirrored_verts()
	var any := false
	for fi in faces.size():
		if region_base(regions[fi]) != "glass":
			continue
		any = true
		_emit_face(st, faces[fi], verts)
		_emit_face(st, _reversed(faces[fi]), mirrored)
	return st.commit() if any else null

## The hollow shell's inside: every non-glass panel copied `thickness`
## inward and turned to face the cabin, plus rims around window openings
## (glass or deleted faces) so the panels have visible thickness from the
## driver's seat. Generated from the body, so it follows every edit.
## The inside surface's points: [inner, inner mirrored, outer mirrored],
## `thickness` inside the panels along the vertex normals.
func inner_points(thickness: float = 0.02) -> Array:
	_fix_regions()
	# vertex normals from the panels around each point
	var vn := []
	vn.resize(verts.size())
	for i in verts.size():
		vn[i] = Vector3.ZERO
	for fi in faces.size():
		if region_base(regions[fi]) == "glass":
			continue
		var n := face_normal(faces[fi])
		for i in faces[fi]:
			vn[i] += n
	var inner := PackedVector3Array()
	for i in verts.size():
		var n: Vector3 = vn[i]
		if is_center(i):
			n.x = 0.0
		n = n.normalized() if n.length() > 1e-6 else Vector3.ZERO
		var q := verts[i] - n * thickness
		if is_center(i):
			q.x = 0.0
		inner.append(q)
	var inner_m := PackedVector3Array()
	for q in inner:
		inner_m.append(Vector3(-q.x, q.y, q.z))
	return [inner, inner_m, _mirrored_verts()]

## Edges along an opening (a glass face or no face), per solid face:
## fi -> [[a, b], ...] needing a rim joining the outside to the inside
## (centerline seams excluded).
func opening_edges() -> Dictionary:
	var out := {}
	var solid_use := _solid_edge_use()
	var all_use := edge_use()
	for fi in faces.size():
		if region_base(regions[fi]) == "glass":
			continue
		var f: PackedInt32Array = faces[fi]
		var list := []
		for k in f.size():
			var a := f[k]
			var b := f[(k + 1) % f.size()]
			var e := edge_key(a, b)
			if solid_use.get(e, 0) != 1:
				continue
			if is_center(a) and is_center(b) and all_use.get(e, 0) == 1:
				continue
			list.append([a, b])
		out[fi] = list
	return out

func _solid_edge_use() -> Dictionary:
	var solid_use := {}
	for fi in faces.size():
		if region_base(regions[fi]) == "glass":
			continue
		var f: PackedInt32Array = faces[fi]
		for k in f.size():
			var e := edge_key(f[k], f[(k + 1) % f.size()])
			solid_use[e] = solid_use.get(e, 0) + 1
	return solid_use

## Plain-coloured inside of the shell (one colour per face from its inside
## paint; photo faces show grey here, PhotoTexturer.build_inside textures them).
func build_interior(thickness: float = 0.02, colors: Dictionary = {}) -> ArrayMesh:
	var pts := inner_points(thickness)
	var inner: PackedVector3Array = pts[0]
	var inner_m: PackedVector3Array = pts[1]
	var outer_m: PackedVector3Array = pts[2]
	# which edges border an opening (a glass face or no face at all)
	var solid_use := {}
	var all_use := edge_use()
	for fi in faces.size():
		if region_base(regions[fi]) == "glass":
			continue
		var f: PackedInt32Array = faces[fi]
		for k in f.size():
			var e := edge_key(f[k], f[(k + 1) % f.size()])
			solid_use[e] = solid_use.get(e, 0) + 1
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for fi in faces.size():
		if region_base(regions[fi]) == "glass":
			continue
		var f: PackedInt32Array = faces[fi]
		var ib := inner_base(regions[fi])
		st.set_color(colors.get(ib, INNER_REGIONS[ib]["color"]))
		# inside panel faces the cabin: reversed winding
		_emit_face(st, _reversed(f), inner)
		_emit_face(st, f, inner_m)
		for k in f.size():
			var a := f[k]
			var b := f[(k + 1) % f.size()]
			var e := edge_key(a, b)
			var open: bool = solid_use.get(e, 0) == 1
			if not open:
				continue
			if is_center(a) and is_center(b) and all_use.get(e, 0) == 1:
				continue          # the centerline seam: the mirror half continues the panel
			var rim := PackedVector3Array([verts[b], verts[a], inner[a], inner[b]])
			_emit_face(st, PackedInt32Array([0, 1, 2, 3]), rim)
			var rim_m := PackedVector3Array([outer_m[a], outer_m[b], inner_m[b], inner_m[a]])
			_emit_face(st, PackedInt32Array([0, 1, 2, 3]), rim_m)
	return st.commit()

func _emit_face(st: SurfaceTool, f: PackedInt32Array, vs: PackedVector3Array) -> void:
	var n := face_normal(f, vs)
	for tri in triangulate(f, vs):
		for idx in [tri[0], tri[2], tri[1]]:    # reversed: CCW-outward -> Godot front face
			st.set_normal(n)
			st.add_vertex(vs[idx])

## Split a face into triangles (vertex ids, CCW seen from outside). Faces
## with more than 4 sides, or concave ones (like a side panel with a wheel
## arch cut into it), are ear-clipped in the face's own plane.
func triangulate(f: PackedInt32Array, vs: PackedVector3Array = verts) -> Array:
	var out := []
	if f.size() == 3:
		return [[f[0], f[1], f[2]]]
	var n := face_normal(f, vs)
	var u := (vs[f[1]] - vs[f[0]])
	u = (u - n * u.dot(n)).normalized()
	if u.length() < 0.5:
		u = n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var w := n.cross(u)
	var poly := PackedVector2Array()
	for i in f:
		poly.append(Vector2(vs[i].dot(u), vs[i].dot(w)))
	var idx := Geometry2D.triangulate_polygon(poly)
	if idx.is_empty():
		for k in range(1, f.size() - 1):       # degenerate: fall back to a fan
			out.append([f[0], f[k], f[k + 1]])
		return out
	for t in range(0, idx.size(), 3):
		var a := f[idx[t]]
		var b := f[idx[t + 1]]
		var c := f[idx[t + 2]]
		if (vs[b] - vs[a]).cross(vs[c] - vs[a]).dot(n) < 0.0:
			out.append([a, c, b])
		else:
			out.append([a, b, c])
	return out

# ---------------------------------------------------------------- wheel arches

## Cut a wheel arch into the body side at an axle: points are added along
## the side's bottom edge and lifted onto a circle around the wheel, so the
## side panel's lower edge follows the arch. `axle_z` / `center_y` place the
## wheel; `radius` is the arch radius (tire radius plus clearance).
## Returns "" or a message.
func cut_wheel_arch(axle_z: float, center_y: float, radius: float, segments: int = 8) -> String:
	# the side's bottom edge: the lowest side edge running past the axle
	var low := _bottom_edge_height(axle_z)
	if low == INF:
		return "No body side found at this axle."
	if low >= center_y + radius - 0.02:
		return "This wheel already has an arch (or the body sits above it)."
	var half := sqrt(maxf(radius * radius - pow(low - center_y, 2.0), 0.0))
	var profile := []
	for k in segments + 1:
		var z := axle_z - half + 2.0 * half * k / segments
		var dz := z - axle_z
		profile.append(Vector2(z, center_y + sqrt(maxf(radius * radius - dz * dz, 0.0))))
	return cut_arch_profile(profile)

## Cut an arch of any shape: `profile` is a list of side-view points
## (Vector2(z, y)), in either direction. The two ends drop onto the body
## side's bottom edge; the points between become the arch outline.
func cut_arch_profile(profile: Array) -> String:
	if profile.size() < 3:
		return "Tap at least 3 points: both ends of the arch and at least one over the wheel."
	var pts := profile.duplicate()
	pts.sort_custom(func(a, b): return a.x < b.x)
	var z0: float = pts[0].x
	var z1: float = pts[pts.size() - 1].x
	if z1 - z0 < 0.1:
		return "The arch is too narrow. Start and finish on either side of the wheel."
	var mid := (z0 + z1) * 0.5
	var low := _bottom_edge_height(mid)
	if low == INF:
		return "No body side found under that arch."
	for i in range(1, pts.size()):
		if pts[i].x - pts[i - 1].x < 0.005:
			return "Two points are almost on top of each other. Undo one and tap again."
	var ids := []
	for p in pts:
		var id := _point_on_bottom_edge(p.x, low)
		if id < 0:
			return "The body's bottom edge doesn't run all the way under that arch (has it been reshaped, or does the arch go past the bumper?)."
		ids.append(id)
	for k in range(1, pts.size() - 1):
		var v := verts[ids[k]]
		verts[ids[k]] = Vector3(v.x, maxf(pts[k].y, low), v.z)
	return ""

## Height of the side's bottom edge at depth z (lowest side edge there).
func _bottom_edge_height(z: float) -> float:
	var low := INF
	for e in edges():
		if is_center(e.x) or is_center(e.y):
			continue
		var a := verts[e.x]
		var b := verts[e.y]
		if (a.z - z) * (b.z - z) <= 0.0 and absf(a.z - b.z) > 0.01:
			low = minf(low, lerpf(a.y, b.y, (z - a.z) / (b.z - a.z)))
	return low

## Point on the side's bottom edge at depth z (reuses a point within 1 cm,
## otherwise splits the edge there).
func _point_on_bottom_edge(z: float, low: float) -> int:
	for i in verts.size():
		if not is_center(i) and absf(verts[i].y - low) < 0.03 and absf(verts[i].z - z) < 0.01:
			return i
	for e in edges():
		if is_center(e.x) or is_center(e.y):
			continue
		var a := verts[e.x]
		var b := verts[e.y]
		var z0 := minf(a.z, b.z)
		var z1 := maxf(a.z, b.z)
		if z > z0 + 0.005 and z < z1 - 0.005:
			var t := (z - a.z) / (b.z - a.z)
			var p := a.lerp(b, t)
			if absf(p.y - low) > 0.03 or absf(a.y - low) > 0.1 or absf(b.y - low) > 0.1:
				continue                    # not the bottom edge (or too sloped)
			var id := verts.size()
			verts.append(p)
			for fi in faces.size():
				var f: PackedInt32Array = faces[fi]
				for k in f.size():
					var u := f[k]
					var v := f[(k + 1) % f.size()]
					if (u == e.x and v == e.y) or (u == e.y and v == e.x):
						f.insert(k + 1, id)
						faces[fi] = f
						break
			return id
	return -1

# ---------------------------------------------------------------- operations

## Extrude the selected faces as one region: the region is lifted along its
## average normal by `dist` and joined to the rest with side quads.
## Returns the ids of the new (moved) vertices.
func extrude_faces(face_ids: Array, dist: float = 0.05) -> Array:
	if face_ids.is_empty():
		return []
	var sel := {}
	for fi in face_ids:
		sel[fi] = true
	var use_all := edge_use()
	var use_sel := {}
	for fi in face_ids:
		var f: PackedInt32Array = faces[fi]
		for k in f.size():
			var e := edge_key(f[k], f[(k + 1) % f.size()])
			use_sel[e] = use_sel.get(e, 0) + 1
	var n := Vector3.ZERO
	for fi in face_ids:
		n += face_normal(faces[fi])
	n = n.normalized()
	# duplicate the region's vertices
	var remap := {}
	for fi in face_ids:
		for i in faces[fi]:
			if not remap.has(i):
				remap[i] = verts.size()
				verts.append(verts[i])
	# side walls along the region boundary (in each face's winding order)
	_fix_regions()
	var walls := []
	var wall_regions := []
	for fi in face_ids:
		var f: PackedInt32Array = faces[fi]
		for k in f.size():
			var a := f[k]
			var b := f[(k + 1) % f.size()]
			var e := edge_key(a, b)
			if use_sel[e] != 1:
				continue                   # interior edge of the region
			if is_center(a) and is_center(b) and use_all[e] == 1:
				continue                   # open centerline edge: the mirror half closes it
			walls.append(PackedInt32Array([a, b, remap[b], remap[a]]))
			wall_regions.append(regions[fi])
	for fi in face_ids:
		var f: PackedInt32Array = faces[fi]
		for k in f.size():
			f[k] = remap[f[k]]
		faces[fi] = f
	faces.append_array(walls)
	regions.append_array(wall_regions)
	var moved: Array = remap.values()
	move_verts(moved, n * dist)
	return moved

## Loop cut through the quad ring that crosses edge (a, b). Returns the new
## vertex ids (one per crossed edge).
func loop_cut(a: int, b: int, t: float = 0.5) -> Array:
	var start := edge_key(a, b)
	# faces per edge
	var edge_faces := {}
	for fi in faces.size():
		var f: PackedInt32Array = faces[fi]
		for k in f.size():
			var e := edge_key(f[k], f[(k + 1) % f.size()])
			if not edge_faces.has(e):
				edge_faces[e] = []
			edge_faces[e].append(fi)
	if not edge_faces.has(start):
		return []
	# walk the ring both ways from the start edge: list of [face, entry edge]
	var cut_faces := {}                 # face -> [edge_in, edge_out]
	var cut_edges := {start: true}
	for dir in 2:
		var e := start
		var prev_face := -1
		if dir == 1 and edge_faces[start].size() < 2:
			break
		var fi: int = edge_faces[start][dir] if edge_faces[start].size() > dir else -1
		while fi != -1 and not cut_faces.has(fi):
			var f: PackedInt32Array = faces[fi]
			if f.size() != 4:
				break                       # rings stop at triangles
			var k := 0
			while k < 4 and edge_key(f[k], f[(k + 1) % 4]) != e:
				k += 1
			if k == 4:
				break
			var opp := edge_key(f[(k + 2) % 4], f[(k + 3) % 4])
			cut_faces[fi] = [e, opp]
			cut_edges[opp] = true
			prev_face = fi
			fi = -1
			for g in edge_faces.get(opp, []):
				if g != prev_face:
					fi = g
			e = opp
	if cut_faces.is_empty():
		return []
	_fix_regions()
	# new vertex on every cut edge (always measured from the lower vertex id)
	var mids := {}
	for e in cut_edges:
		var p := verts[e.x].lerp(verts[e.y], t)
		if is_center(e.x) and is_center(e.y):
			p.x = 0.0
		mids[e] = verts.size()
		verts.append(p)
	for fi in cut_faces:
		var f: PackedInt32Array = faces[fi]
		var e_in: Vector2i = cut_faces[fi][0]
		var k := 0
		while edge_key(f[k], f[(k + 1) % 4]) != e_in:
			k += 1
		var v0 := f[k]; var v1 := f[(k + 1) % 4]; var v2 := f[(k + 2) % 4]; var v3 := f[(k + 3) % 4]
		var m01: int = mids[edge_key(v0, v1)]
		var m23: int = mids[edge_key(v2, v3)]
		faces[fi] = PackedInt32Array([v0, m01, m23, v3])
		faces.append(PackedInt32Array([m01, v1, v2, m23]))
		regions.append(regions[fi])
	return mids.values()

## Add a point on edge (a, b) at fraction t from a. Every face using the
## edge gets the new point in its outline, so the body stays connected.
func insert_point_on_edge(a: int, b: int, t: float) -> int:
	_fix_regions()
	var p := verts[a].lerp(verts[b], clampf(t, 0.05, 0.95))
	if is_center(a) and is_center(b):
		p.x = 0.0
	var id := verts.size()
	verts.append(p)
	for fi in faces.size():
		var f: PackedInt32Array = faces[fi]
		for k in f.size():
			var u := f[k]
			var v := f[(k + 1) % f.size()]
			if (u == a and v == b) or (u == b and v == a):
				f.insert(k + 1, id)
				faces[fi] = f
				break
	return id

## Add a free point (snapped to the left half; near the middle it snaps onto
## the centerline).
func add_point(p: Vector3) -> int:
	p.x = -absf(p.x)
	if p.x > -0.01:
		p.x = 0.0
	verts.append(p)
	return verts.size() - 1

## Connect the selected points.
##   2 points on one face -> split that face with a new edge
##   3+ points            -> a new face through them, facing `toward`
## Returns "" on success or a message for the user.
func connect_points(ids: Array, toward: Vector3) -> String:
	_fix_regions()
	if ids.size() < 2:
		return "Select 2 points on the same face to split it, or 3 or more points to make a new face."
	if ids.size() == 2:
		var a: int = ids[0]
		var b: int = ids[1]
		for fi in faces.size():
			var f: PackedInt32Array = faces[fi]
			var i := f.find(a)
			var j := f.find(b)
			if i < 0 or j < 0:
				continue
			if absi(i - j) == 1 or absi(i - j) == f.size() - 1:
				return "Those points are already connected by an edge."
			var lo := mini(i, j)
			var hi := maxi(i, j)
			var f1 := PackedInt32Array()
			for k in range(lo, hi + 1):
				f1.append(f[k])
			var f2 := PackedInt32Array()
			for k in range(hi, f.size()):
				f2.append(f[k])
			for k in range(0, lo + 1):
				f2.append(f[k])
			faces[fi] = f1
			faces.append(f2)
			regions.append(regions[fi])
			return ""
		return "Those 2 points aren't on the same face. Select 3 or more points to make a new face instead."
	# new face: order the points around their center in their best-fit plane
	var c := Vector3.ZERO
	for i in ids:
		c += verts[i]
	c /= ids.size()
	var n := Vector3.ZERO
	for k in ids.size():
		var p0 := verts[ids[k]] - c
		var p1 := verts[ids[(k + 1) % ids.size()]] - c
		n += p0.cross(p1)
	if n.length() < 1e-9:
		n = (toward - c)
	n = n.normalized()
	var u := (verts[ids[0]] - c)
	u = (u - n * u.dot(n)).normalized()
	if u.length() < 0.5:
		u = n.cross(Vector3.UP).normalized()
	var w := n.cross(u)
	var ordered := ids.duplicate()
	ordered.sort_custom(func(i1, i2):
		var d1 := verts[i1] - c
		var d2 := verts[i2] - c
		return atan2(d1.dot(w), d1.dot(u)) < atan2(d2.dot(w), d2.dot(u)))
	var face := PackedInt32Array(ordered)
	if face_normal(face).dot(toward - c) < 0.0:
		face.reverse()
	for f in faces:
		var same: bool = f.size() == face.size()
		if same:
			for i in face:
				if not f.has(i):
					same = false
					break
		if same:
			return "There's already a face through those points."
	faces.append(face)
	regions.append("paint")
	return ""

## Weld the points into one at their average position (on the centerline if
## any of them is). Faces that collapse are removed.
func merge_points(ids: Array) -> int:
	if ids.size() < 2:
		return -1
	_fix_regions()
	var keep: int = ids[0]
	var c := Vector3.ZERO
	var center := false
	for i in ids:
		c += verts[i]
		if is_center(i):
			center = true
	c /= ids.size()
	if center:
		c.x = 0.0
	verts[keep] = c
	var gone := {}
	for i in ids:
		if i != keep:
			gone[i] = true
	var nf := []
	var nr := []
	for fi in faces.size():
		var f: PackedInt32Array = faces[fi]
		var out := PackedInt32Array()
		for i in f:
			var j: int = keep if gone.has(i) else i
			if out.is_empty() or out[out.size() - 1] != j:
				out.append(j)
		if out.size() > 1 and out[0] == out[out.size() - 1]:
			out.remove_at(out.size() - 1)
		if out.size() >= 3:
			nf.append(out)
			nr.append(regions[fi])
	faces = nf
	regions = nr
	# drop the welded-away points (and any now unused), keep ids stable otherwise
	remove_unused_verts()
	return -1

# ---------------------------------------------------------------- windows

## How each drawing view flattens the body: 2D axes and the side the camera
## looks from (faces must face it to be cut).
static func view_to2d(view: String, p: Vector3) -> Vector2:
	match view:
		"side":
			return Vector2(p.z, p.y)
		"front", "rear":
			return Vector2(p.x, p.y)
		_:
			return Vector2(p.z, p.x)

static func view_toward_camera(view: String) -> Vector3:
	match view:
		"side":
			return Vector3(-1, 0, 0)
		"front":
			return Vector3(0, 0, -1)
		"rear":
			return Vector3(0, 0, 1)
		_:
			return Vector3(0, 1, 0)

static func _signed_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		a += p.x * q.y - q.x * p.y
	return a * 0.5

## Cut a window: every face facing `view` under the outline (2D, in that
## view's axes) is split exactly along it; the pieces inside become glass
## faces, the rest keep their part. The body stays closed (neighbouring
## faces pick up the new points). Returns "" or a message.
func cut_window(view: String, window: PackedVector2Array) -> String:
	_fix_regions()
	if window.size() < 3 or absf(_signed_area(window)) < 0.002:
		return "Tap at least 3 corners around the window."
	var toward := view_toward_camera(view)
	var targets := []
	var on_glass := false
	for fi in faces.size():
		var f: PackedInt32Array = faces[fi]
		if face_normal(f).dot(toward) < 0.15:
			continue
		var poly := PackedVector2Array()
		for i in f:
			poly.append(view_to2d(view, verts[i]))
		if Geometry2D.intersect_polygons(poly, window).is_empty():
			continue
		if region_base(regions[fi]) == "glass":
			on_glass = true
		else:
			targets.append(fi)
	if targets.is_empty():
		if on_glass:
			return "That area is already glass. Paint it with Photo texture (or another part) first, then cut the window you want."
		return "No body panels face this view under that outline. Draw on the photo where the body is."
	var before := verts.size()
	var cache := {}
	var cut_any := false
	for fi in targets:
		var f: PackedInt32Array = faces[fi]
		var poly := PackedVector2Array()
		for i in f:
			poly.append(view_to2d(view, verts[i]))
		var orient := signf(_signed_area(poly))
		var inside: Array = Geometry2D.intersect_polygons(poly, window)
		var outside: Array = Geometry2D.clip_polygons(poly, window)
		var has_hole := false
		for piece in outside:
			if signf(_signed_area(piece)) != orient:
				has_hole = true
		if has_hole:
			# window inside one panel: split the panel through the window first
			var cx := 0.0
			for q in window:
				cx += q.x
			cx /= window.size()
			var r := Rect2(poly[0], Vector2.ZERO)
			for q in poly:
				r = r.expand(q)
			r = r.grow(1.0)
			var lhs := PackedVector2Array([r.position, Vector2(cx, r.position.y), Vector2(cx, r.end.y), Vector2(r.position.x, r.end.y)])
			var rhs := PackedVector2Array([Vector2(cx, r.position.y), Vector2(r.end.x, r.position.y), r.end, Vector2(cx, r.end.y)])
			outside = []
			for half in [lhs, rhs]:
				for part in Geometry2D.intersect_polygons(poly, half):
					outside.append_array(Geometry2D.clip_polygons(part, window))
		var new_faces := []
		for piece in outside:
			var ids := _lift_piece(piece, f, view, orient, cache)
			if ids.size() >= 3:
				new_faces.append([ids, regions[fi]])
		for piece in inside:
			var ids2 := _lift_piece(piece, f, view, orient, cache)
			if ids2.size() >= 3:
				new_faces.append([ids2, "glass"])
		if new_faces.is_empty():
			continue
		cut_any = true
		faces[fi] = new_faces[0][0]
		regions[fi] = new_faces[0][1]
		for k in range(1, new_faces.size()):
			faces.append(new_faces[k][0])
			regions.append(new_faces[k][1])
	if not cut_any:
		return "That outline didn't cut anything."
	# new points that land on other faces' edges join those faces (no cracks)
	for v in range(before, verts.size()):
		_join_edges(v)
	return ""

## 2D piece of face f -> vertex ids (reusing the face's corners, splitting
## its edges exactly, or lifting new points onto the face's plane).
func _lift_piece(piece: PackedVector2Array, f: PackedInt32Array, view: String, orient: float, cache: Dictionary) -> PackedInt32Array:
	var pts := piece
	if signf(_signed_area(pts)) != orient:
		pts = pts.duplicate()
		pts.reverse()
	var n := face_normal(f)
	var c := face_center(f)
	var out := PackedInt32Array()
	for q in pts:
		var id := -1
		for i in f:
			if view_to2d(view, verts[i]).distance_to(q) < 2e-4:
				id = i
				break
		if id < 0:
			var p3 := Vector3.INF
			for k in f.size():
				var a := verts[f[k]]
				var b := verts[f[(k + 1) % f.size()]]
				var a2 := view_to2d(view, a)
				var b2 := view_to2d(view, b)
				var ab := b2 - a2
				if ab.length_squared() < 1e-10:
					continue
				var t := (q - a2).dot(ab) / ab.length_squared()
				if t > 0.0 and t < 1.0 and (a2 + ab * t).distance_to(q) < 2e-4:
					p3 = a.lerp(b, t)
					if is_center(f[k]) and is_center(f[(k + 1) % f.size()]):
						p3.x = 0.0
					break
			if p3 == Vector3.INF:
				p3 = _on_plane(view, q, n, c)
			var key := "%d,%d,%d" % [roundi(p3.x * 2000), roundi(p3.y * 2000), roundi(p3.z * 2000)]
			if cache.has(key):
				id = cache[key]
			else:
				if absf(p3.x) < 0.002:
					p3.x = 0.0
				p3.x = minf(p3.x, 0.0)
				id = verts.size()
				verts.append(p3)
				cache[key] = id
		if out.is_empty() or out[out.size() - 1] != id:
			out.append(id)
	if out.size() > 1 and out[0] == out[out.size() - 1]:
		out.remove_at(out.size() - 1)
	return out

## Point on the face plane under a 2D view point.
static func _on_plane(view: String, q: Vector2, n: Vector3, c: Vector3) -> Vector3:
	match view:
		"side":    # (z, y) known, solve x
			return Vector3(c.x - (n.y * (q.y - c.y) + n.z * (q.x - c.z)) / n.x, q.y, q.x)
		"front", "rear":   # (x, y) known, solve z
			return Vector3(q.x, q.y, c.z - (n.x * (q.x - c.x) + n.y * (q.y - c.y)) / n.z)
		_:         # (z, x) known, solve y
			return Vector3(q.y, c.y - (n.x * (q.y - c.x) + n.z * (q.x - c.z)) / n.y, q.x)

## Insert vertex v into any face edge it lies on (fixes T-junctions).
func _join_edges(v: int) -> void:
	var p := verts[v]
	for fi in faces.size():
		var f: PackedInt32Array = faces[fi]
		if f.has(v):
			continue
		for k in f.size():
			var a := verts[f[k]]
			var b := verts[f[(k + 1) % f.size()]]
			var ab := b - a
			if ab.length_squared() < 1e-10:
				continue
			var t := (p - a).dot(ab) / ab.length_squared()
			if t > 0.001 and t < 0.999 and (a + ab * t).distance_to(p) < 0.001:
				f.insert(k + 1, v)
				faces[fi] = f
				break

func delete_faces(face_ids: Array) -> void:
	var drop := {}
	for fi in face_ids:
		drop[fi] = true
	_fix_regions()
	var keep := []
	var keep_r := []
	for fi in faces.size():
		if not drop.has(fi):
			keep.append(faces[fi])
			keep_r.append(regions[fi])
	faces = keep
	regions = keep_r
	remove_unused_verts()

func remove_unused_verts() -> void:
	var used := {}
	for f in faces:
		for i in f:
			used[i] = true
	var remap := {}
	var nv := PackedVector3Array()
	for i in verts.size():
		if used.has(i):
			remap[i] = nv.size()
			nv.append(verts[i])
	for fi in faces.size():
		var f: PackedInt32Array = faces[fi]
		for k in f.size():
			f[k] = remap[f[k]]
		faces[fi] = f
	verts = nv

## Faces whose vertices are all in `ids`.
func faces_of_verts(ids: Array) -> Array:
	var s := {}
	for i in ids:
		s[i] = true
	var out := []
	for fi in faces.size():
		var all := true
		for i in faces[fi]:
			if not s.has(i):
				all = false
				break
		if all:
			out.append(fi)
	return out

func verts_of_faces(face_ids: Array) -> Array:
	var s := {}
	for fi in face_ids:
		for i in faces[fi]:
			s[i] = true
	return s.keys()

# ---------------------------------------------------------------- storage

func to_dict() -> Dictionary:
	var v := []
	for p in verts:
		v.append([snappedf(p.x, 0.0001), snappedf(p.y, 0.0001), snappedf(p.z, 0.0001)])
	var f := []
	for face in faces:
		f.append(Array(face))
	_fix_regions()
	return {"format": 1, "template": template, "verts": v, "faces": f, "regions": regions.duplicate()}

static func from_dict(d: Dictionary) -> HalfMesh:
	var m := HalfMesh.new()
	m.template = d.get("template", "")
	for p in d.get("verts", []):
		m.verts.append(Vector3(p[0], p[1], p[2]))
	for f in d.get("faces", []):
		m.faces.append(PackedInt32Array(f))
	for r in d.get("regions", []):
		m.regions.append(r if HalfMesh.region_valid(r) else "paint")
	m._fix_regions()
	return m

# ---------------------------------------------------------------- templates

## Body templates as cross-sections from front bumper (z 0) to rear (z 1).
## Each: [z, bottom, belt, top, belt half-width, top half-width], heights as
## fractions of overall height, widths as fractions of half the width.
const TEMPLATES := {
	"suv": {"label": "SUV", "sections": [
		[0.00, 0.24, 0.48, 0.53, 0.90, 0.84],
		[0.03, 0.17, 0.52, 0.60, 0.97, 0.90],
		[0.30, 0.17, 0.56, 0.65, 1.00, 0.93],
		[0.40, 0.17, 0.57, 0.97, 1.00, 0.84],
		[0.97, 0.17, 0.57, 1.00, 1.00, 0.84],
		[1.00, 0.21, 0.55, 0.97, 0.98, 0.82]]},
	"pickup": {"label": "Pickup", "sections": [
		[0.00, 0.24, 0.50, 0.55, 0.90, 0.84],
		[0.03, 0.18, 0.54, 0.62, 0.97, 0.90],
		[0.30, 0.18, 0.58, 0.67, 1.00, 0.93],
		[0.39, 0.18, 0.59, 0.97, 1.00, 0.84],
		[0.58, 0.18, 0.59, 1.00, 1.00, 0.84],
		[0.60, 0.18, 0.60, 0.62, 1.00, 0.98],
		[1.00, 0.20, 0.60, 0.62, 1.00, 0.98]]},
	"sedan": {"label": "Sedan", "sections": [
		[0.00, 0.20, 0.42, 0.47, 0.90, 0.84],
		[0.04, 0.12, 0.50, 0.57, 0.97, 0.92],
		[0.32, 0.12, 0.56, 0.62, 1.00, 0.95],
		[0.46, 0.12, 0.58, 1.00, 0.99, 0.80],
		[0.68, 0.12, 0.58, 0.98, 0.99, 0.80],
		[0.82, 0.12, 0.58, 0.66, 0.99, 0.95],
		[1.00, 0.20, 0.55, 0.62, 0.94, 0.88]]},
	"coupe": {"label": "Coupe", "sections": [
		[0.00, 0.17, 0.38, 0.42, 0.88, 0.82],
		[0.05, 0.10, 0.47, 0.54, 0.97, 0.92],
		[0.38, 0.10, 0.55, 0.62, 1.00, 0.95],
		[0.52, 0.10, 0.57, 1.00, 0.99, 0.76],
		[0.66, 0.10, 0.58, 0.95, 0.99, 0.76],
		[0.90, 0.10, 0.58, 0.68, 0.99, 0.92],
		[1.00, 0.17, 0.55, 0.62, 0.94, 0.88]]},
	"hatch": {"label": "Hatchback", "sections": [
		[0.00, 0.20, 0.44, 0.50, 0.90, 0.84],
		[0.04, 0.13, 0.52, 0.59, 0.97, 0.92],
		[0.26, 0.13, 0.57, 0.66, 1.00, 0.94],
		[0.40, 0.13, 0.58, 1.00, 0.99, 0.82],
		[0.88, 0.13, 0.58, 0.96, 0.99, 0.80],
		[1.00, 0.18, 0.56, 0.86, 0.96, 0.80]]},
	"box": {"label": "Plain box", "sections": [
		[0.00, 0.15, 0.55, 1.00, 1.00, 1.00],
		[1.00, 0.15, 0.55, 1.00, 1.00, 1.00]]},
}

## Build a template fitted to the project's real dimensions.
static func from_template(key: String, dims: Dictionary) -> HalfMesh:
	var m := HalfMesh.new()
	m.template = key
	var L: float = dims["length_m"]
	var H: float = dims["height_m"]
	var hw: float = dims["width_m"] * 0.5
	var mid: float = dims["front_overhang_m"] + dims["wheelbase_m"] * 0.5
	var secs: Array = TEMPLATES[key]["sections"]
	var rings := []
	for s in secs:
		var z: float = s[0] * L - mid
		var yb: float = s[1] * H
		var ybelt: float = s[2] * H
		var yt: float = s[3] * H
		var ring := PackedInt32Array()
		for p in [Vector3(0, yb, z), Vector3(-s[4] * hw * 0.97, yb, z), Vector3(-s[4] * hw, ybelt, z),
				Vector3(-s[5] * hw, yt, z), Vector3(0, yt, z)]:
			ring.append(m.verts.size())
			m.verts.append(p)
		rings.append(ring)
	# skin between consecutive rings
	for r in rings.size() - 1:
		var A: PackedInt32Array = rings[r]
		var B: PackedInt32Array = rings[r + 1]
		var axis_y := (m.verts[A[0]].y + m.verts[A[4]].y + m.verts[B[0]].y + m.verts[B[4]].y) * 0.25
		var tall_a: bool = secs[r][3] >= 0.85
		var tall_b: bool = secs[r + 1][3] >= 0.85
		for j in 4:
			m._add_outward(PackedInt32Array([A[j], A[j + 1], B[j + 1], B[j]]), axis_y)
			var reg := "paint"
			if j == 0:
				reg = "trim"                              # underbody
			elif j == 2 and tall_a and tall_b and key != "box":
				reg = "glass"                             # side windows
			elif j == 3 and tall_a != tall_b and key != "box":
				reg = "glass"                             # windshield / rear window
			m.regions.append(reg)
	# front and rear caps (a centerline point at belt height splits each into quads)
	for ci in 2:
		var cap: PackedInt32Array = rings[0] if ci == 0 else rings[rings.size() - 1]
		var sec: Array = secs[0] if ci == 0 else secs[secs.size() - 1]
		var c_mid := m.verts.size()
		m.verts.append(Vector3(0, m.verts[cap[2]].y, m.verts[cap[0]].z))
		m._add_outward(PackedInt32Array([cap[0], cap[1], cap[2], c_mid]), 0.0)
		m.regions.append("grille" if ci == 0 and key != "box" else "paint")
		m._add_outward(PackedInt32Array([c_mid, cap[2], cap[3], cap[4]]), 0.0)
		m.regions.append("glass" if ci == 1 and sec[3] >= 0.85 and key != "box" else "paint")
	return m

## Add a face, flipping it if its normal points toward the body's axis at
## height axis_y (fine for the near-convex templates).
func _add_outward(f: PackedInt32Array, axis_y: float) -> void:
	var c := face_center(f)
	var axis := Vector3(0.0, axis_y, c.z)
	var lo := 1e9
	var hi := -1e9
	for p in verts:
		lo = minf(lo, p.z)
		hi = maxf(hi, p.z)
	var n := face_normal(f)
	var out := c - axis
	if out.length() < 0.01 or absf(n.z) > 0.9:
		out = Vector3(0, 0, -1) if c.z < (lo + hi) * 0.5 else Vector3(0, 0, 1)
	if n.dot(out) < 0.0:
		f.reverse()
	faces.append(f)
