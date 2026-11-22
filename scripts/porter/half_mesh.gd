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
var template := ""

var _undo: Array = []
var _redo: Array = []

# ---------------------------------------------------------------- basics

func is_center(i: int) -> bool:
	return absf(verts[i].x) <= CENTER_EPS

func snapshot() -> Dictionary:
	var f := []
	for face in faces:
		f.append(PackedInt32Array(face))
	return {"v": PackedVector3Array(verts), "f": f}

func restore(s: Dictionary) -> void:
	verts = PackedVector3Array(s["v"])
	faces = []
	for face in s["f"]:
		faces.append(PackedInt32Array(face))

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
func build_mesh(color: Color = Color(0.72, 0.74, 0.78)) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(color)
	var mirrored := PackedVector3Array()
	for p in verts:
		mirrored.append(Vector3(-p.x, p.y, p.z))
	for f in faces:
		_emit_face(st, f, verts)
		var r := PackedInt32Array()
		for k in range(f.size() - 1, -1, -1):
			r.append(f[k])
		_emit_face(st, r, mirrored)
	return st.commit()

func _emit_face(st: SurfaceTool, f: PackedInt32Array, vs: PackedVector3Array) -> void:
	var n := face_normal(f, vs)
	for k in range(1, f.size() - 1):
		for idx in [f[0], f[k + 1], f[k]]:      # reversed: CCW-outward -> Godot front face
			st.set_normal(n)
			st.add_vertex(vs[idx])

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
	var walls := []
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
	for fi in face_ids:
		var f: PackedInt32Array = faces[fi]
		for k in f.size():
			f[k] = remap[f[k]]
		faces[fi] = f
	faces.append_array(walls)
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
	return mids.values()

func delete_faces(face_ids: Array) -> void:
	var drop := {}
	for fi in face_ids:
		drop[fi] = true
	var keep := []
	for fi in faces.size():
		if not drop.has(fi):
			keep.append(faces[fi])
	faces = keep
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
	return {"format": 1, "template": template, "verts": v, "faces": f}

static func from_dict(d: Dictionary) -> HalfMesh:
	var m := HalfMesh.new()
	m.template = d.get("template", "")
	for p in d.get("verts", []):
		m.verts.append(Vector3(p[0], p[1], p[2]))
	for f in d.get("faces", []):
		m.faces.append(PackedInt32Array(f))
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
		for j in 4:
			m._add_outward(PackedInt32Array([A[j], A[j + 1], B[j + 1], B[j]]), axis_y)
	# front and rear caps (a centerline point at belt height splits each into quads)
	for cap in [rings[0], rings[rings.size() - 1]]:
		var c_mid := m.verts.size()
		m.verts.append(Vector3(0, m.verts[cap[2]].y, m.verts[cap[0]].z))
		m._add_outward(PackedInt32Array([cap[0], cap[1], cap[2], c_mid]), 0.0)
		m._add_outward(PackedInt32Array([c_mid, cap[2], cap[3], cap[4]]), 0.0)
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
