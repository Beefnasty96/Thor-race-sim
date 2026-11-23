class_name PhotoTexturer
extends RefCounted
## Projects the aligned reference photos onto the body. Because each photo is
## lined up with the car's true-size outline, a point on the body maps to a
## pixel of a photo by dropping the axis that photo looks along:
##   side  : (distance from front bumper, height)    [looks along X]
##   front : (-x, height)                           [looks along Z from ahead]
##   rear  : (x, height)                            [looks along Z from behind]
##   top   : (distance from front bumper, x)         [looks down]
## Faces marked "photo" take the photo that faces them most squarely
## ("photo:<view>" forces one). The mirrored half samples its own side of
## the front/rear/top photos and a mirror of the side photo.

const VIEW_DIRS := {
	"side": Vector3(-1, 0, 0),      # left-half faces looking toward -X face the side camera
	"front": Vector3(0, 0, -1),
	"rear": Vector3(0, 0, 1),
	"top": Vector3(0, 1, 0),
	"dash": Vector3(0, 0, 1),       # dash photo: taken from the driver's seat, faces toward the driver
}

static func world_to_frame(project: PorterProject, view: String, p: Vector3) -> Vector2:
	var mid: float = project.front_axle_x() + project.dims["wheelbase_m"] * 0.5
	match view:
		"side":
			return Vector2(p.z + mid, p.y)
		"front":
			return Vector2(-p.x, p.y)
		"rear", "dash":
			return Vector2(p.x, p.y)
		"door":        # inside, looking at the left door: forward is to the right
			return Vector2(-p.z, p.y)
		"pillar":      # from the driver's seat looking forward; both pillars use the left one's photo
			return Vector2(-absf(p.x), p.y)
		"ceiling":     # phone overhead, top toward the windshield: car's left is on the right
			return Vector2(-p.x, -p.z)
		"bedfloor":    # looking down into the bed, top of the photo toward the cab
			return Vector2(p.x, -p.z)
		"bedside":     # facing a bed wall from across the bed: forward to the right; both walls use it
			return Vector2(-p.z, p.y)
		"bedfront":    # from the tailgate looking at the cab
			return Vector2(p.x, p.y)
		"bedgate":     # from the cab end looking back at the tailgate
			return Vector2(-p.x, p.y)
		_:
			return Vector2(p.z + mid, p.x)

static func uv_for(project: PorterProject, view: String, p: Vector3, img_size: Vector2) -> Vector2:
	var px := project.frame_to_image(view, world_to_frame(project, view, p), img_size)
	return px / img_size

## Which photo a face should use. `available`: view -> true for loaded photos.
static func choose_view(region: String, normal: Vector3, available: Dictionary) -> String:
	if region.contains(":"):
		var forced := region.get_slice(":", 1)
		if available.has(forced):
			return forced
	var best := ""
	var best_d := -INF
	for v in VIEW_DIRS:
		if not available.has(v):
			continue
		var d := normal.dot(VIEW_DIRS[v])
		if d > best_d:
			best_d = d
			best = v
	return best

## Full mirrored body: colored faces in surface 0 (vertex colors), then one
## textured surface per photo used. Returns [ArrayMesh, Array of view names
## for surfaces 1..n].
static func build(mesh: HalfMesh, project: PorterProject, colors: Dictionary, images: Dictionary, skip_glass: bool = true) -> Array:
	mesh._fix_regions()
	var available := {}
	for v in images:
		if images[v] != null:
			available[v] = true
	var plain := SurfaceTool.new()
	plain.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tex := {}                    # view -> SurfaceTool
	var mirrored := PackedVector3Array()
	for p in mesh.verts:
		mirrored.append(Vector3(-p.x, p.y, p.z))
	var any_plain := false
	for fi in mesh.faces.size():
		var f: PackedInt32Array = mesh.faces[fi]
		var reg: String = HalfMesh.region_outer(mesh.regions[fi])
		var base := HalfMesh.region_base(reg)
		if skip_glass and base == "glass":
			continue                    # drawn separately, see-through
		var rf := PackedInt32Array()
		for k in range(f.size() - 1, -1, -1):
			rf.append(f[k])
		var view := ""
		if base == "photo":
			view = choose_view(reg, mesh.face_normal(f), available)
		if view == "":
			var col: Color = colors.get(base, HalfMesh.REGIONS[base]["color"])
			plain.set_color(col)
			mesh._emit_face(plain, f, mesh.verts)
			mesh._emit_face(plain, rf, mirrored)
			any_plain = true
			continue
		if not tex.has(view):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			tex[view] = st
		var img: Image = images[view]
		var sz := Vector2(img.get_width(), img.get_height())
		_emit_textured(tex[view], mesh, f, mesh.verts, project, view, sz)
		_emit_textured(tex[view], mesh, rf, mirrored, project, view, sz)
	var am := ArrayMesh.new()
	if any_plain:
		plain.commit(am)
	else:
		# keep surface 0 as the plain surface even when empty: a degenerate triangle
		plain.set_color(Color.BLACK)
		for i in 3:
			plain.set_normal(Vector3.UP)
			plain.add_vertex(Vector3.ZERO)
		plain.commit(am)
	var order := []
	for v in tex:
		tex[v].commit(am)
		order.append(v)
	return [am, order]

## Inside of the hollow shell: faces painted with a colour go in surface 0
## (vertex colours, rims too), faces painted "photo:door" / "photo:pillar" /
## "photo:ceiling" take that interior photo. Returns [ArrayMesh, view names
## for surfaces 1..n].
static func build_inside(mesh: HalfMesh, project: PorterProject, colors: Dictionary, images: Dictionary, thickness: float = 0.02) -> Array:
	var pts := mesh.inner_points(thickness)
	var inner: PackedVector3Array = pts[0]
	var inner_m: PackedVector3Array = pts[1]
	var outer_m: PackedVector3Array = pts[2]
	var rims := mesh.opening_edges()
	var plain := SurfaceTool.new()
	plain.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tex := {}
	for fi in rims:
		var f: PackedInt32Array = mesh.faces[fi]
		var reg := HalfMesh.region_inner(mesh.regions[fi])
		var ib := reg.get_slice(":", 0)
		var view := reg.get_slice(":", 1) if reg.contains(":") else ""
		var col: Color = colors.get(ib, HalfMesh.INNER_REGIONS[ib]["color"])
		var rf := HalfMesh._reversed(f)
		if view != "" and images.get(view) != null:
			if not tex.has(view):
				var s2 := SurfaceTool.new()
				s2.begin(Mesh.PRIMITIVE_TRIANGLES)
				tex[view] = s2
			var img: Image = images[view]
			var sz := Vector2(img.get_width(), img.get_height())
			_emit_textured(tex[view], mesh, rf, inner, project, view, sz)
			_emit_textured(tex[view], mesh, f, inner_m, project, view, sz)
			col = HalfMesh.INNER_REGIONS["dark"]["color"]
		else:
			plain.set_color(col)
			mesh._emit_face(plain, rf, inner)
			mesh._emit_face(plain, f, inner_m)
		plain.set_color(col)
		for e in rims[fi]:
			var a: int = e[0]
			var b: int = e[1]
			mesh._emit_face(plain, PackedInt32Array([0, 1, 2, 3]), PackedVector3Array([mesh.verts[b], mesh.verts[a], inner[a], inner[b]]))
			mesh._emit_face(plain, PackedInt32Array([0, 1, 2, 3]), PackedVector3Array([outer_m[a], outer_m[b], inner_m[b], inner_m[a]]))
	# keep surface 0 even if empty
	plain.set_color(Color.BLACK)
	for i in 3:
		plain.set_normal(Vector3.UP)
		plain.add_vertex(Vector3.ZERO)
	var am := ArrayMesh.new()
	plain.commit(am)
	var order := []
	for v in tex:
		tex[v].commit(am)
		order.append(v)
	return [am, order]

static func _emit_textured(st: SurfaceTool, mesh: HalfMesh, f: PackedInt32Array, vs: PackedVector3Array,
		project: PorterProject, view: String, sz: Vector2) -> void:
	var n := mesh.face_normal(f, vs)
	for tri in mesh.triangulate(f, vs):
		for idx in [tri[0], tri[2], tri[1]]:    # Godot front faces are clockwise
			st.set_normal(n)
			st.set_uv(uv_for(project, view, vs[idx], sz))
			st.set_color(Color.WHITE)
			st.add_vertex(vs[idx])
