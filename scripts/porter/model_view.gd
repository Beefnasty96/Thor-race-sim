class_name ModelView
extends Control
## The modeling viewport: the mirrored body over the aligned reference photos.
##   side / front / top : orthographic, photo as backdrop, body see-through
##   3d                 : orbit camera
## Touch: tap selects, drag on the selection moves it (in the screen plane),
## drag elsewhere pans (orbits in 3D), pinch zooms. Mouse acts as a finger;
## wheel zooms.

signal selection_changed
signal mesh_edited(final: bool)      # final = edit finished (save / undo point)
signal edge_tapped(a: int, b: int)
signal face_tapped(fi: int)
signal add_point_tap(s: Vector2)
signal arch_point_added

enum Pick { POINTS, FACES }

var project: PorterProject
var mesh: HalfMesh
var view := "side"
var pick := Pick.POINTS
var multi := false
var xray := true
var lock_axis := 0                    # 0 free, 1 horizontal only, 2 vertical only
var tool := ""                        # "" | "loop_cut" | "paint" | "add_point" | "draw_arch" | "wheels"
var arch_pts: Array = []              # side-view points (z, y) of an arch being drawn
var window_pts: Array = []            # 2D points (view axes) of a window outline being drawn
signal window_point_added
var show_interior := true             # hollow shell inside (paint/wheels modes)
var driver_view := false              # 3D camera in the driver's seat
var driver_fov := 75.0                # pinch zooms the driver's-seat view
var glass_mi: MeshInstance3D
var interior_mi: MeshInstance3D
var dash: HalfMesh                    # interior dashboard (shown inside the body)
var ghost: HalfMesh                   # body shown see-through while the dash is edited
var ghost_mi: MeshInstance3D
var cabin: Node3D                     # dash + steering wheel + gauges
var show_cabin := true
var show_steering := true             # hide the wheel to see / place gauges behind it
var demo_reading := 0.35              # needle position for the gauge preview (0..1)
var paint_colors := {}                # region -> Color used for display (body paint etc.)
var show_paint := false               # colour faces by region (Paint mode)
var sel_verts := {}                   # id -> true
var sel_faces := {}

var svc: SubViewportContainer
var vp: SubViewport
var cam: Camera3D
var body: MeshInstance3D
var body_mat: StandardMaterial3D
var deco: Node3D                      # wheels + photo backdrop
var overlay: Control

# camera state
var ortho_size := 3.0
var pan := Vector2.ZERO               # world metres along the view's right/up
var yaw := deg_to_rad(-140.0)
var pitch := deg_to_rad(20.0)
var dist := 9.0

var _touches := {}
var _g := {}                          # gesture start state
var _drag := ""                       # "", "move", "pan"
var _moved := false
var _start_pos := {}                  # vert id -> position at drag start
var _last_tap := Vector2(-999, -999)
var _cycle := 0
var _user_zoomed := false

## Frame the whole car in the current view (ortho views).
func _fit() -> void:
	if project == null:
		return
	var d := project.dims
	var w: float = d["length_m"] if view in ["side", "top"] else d["width_m"]
	var h: float = d["height_m"] if view != "top" else d["width_m"]
	var aspect := size.x / maxf(size.y, 1.0) if size.y > 0 else 1.6
	ortho_size = maxf(h * 1.5, w * 1.2 / aspect)
	dist = maxf(d["length_m"], 3.0) * 1.9

const C_EDGE := Color(0.35, 0.78, 1.0, 0.95)
const C_EDGE_MIRROR := Color(0.35, 0.78, 1.0, 0.28)
const C_VERT := Color(0.92, 0.96, 1.0)
const C_SEL := Color(1.0, 0.65, 0.15)

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	svc = SubViewportContainer.new()
	svc.stretch = true
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(svc)
	vp = SubViewport.new()
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	svc.add_child(vp)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.03, 0.05, 0.09)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.6, 0.7)
	e.ambient_light_energy = 0.9
	env.environment = e
	vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50), deg_to_rad(-35), 0)
	sun.light_energy = 1.1
	vp.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation = Vector3(deg_to_rad(-20), deg_to_rad(145), 0)
	fill.light_energy = 0.45
	vp.add_child(fill)
	cam = Camera3D.new()
	vp.add_child(cam)
	deco = Node3D.new()
	vp.add_child(deco)
	body = MeshInstance3D.new()
	body_mat = StandardMaterial3D.new()
	body_mat.vertex_color_use_as_albedo = true
	body_mat.roughness = 0.55
	body_mat.metallic = 0.2
	body.material_override = body_mat
	vp.add_child(body)
	glass_mi = MeshInstance3D.new()
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.05, 0.08, 0.11, 0.35)
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gm.cull_mode = BaseMaterial3D.CULL_DISABLED
	gm.roughness = 0.05
	gm.metallic = 0.4
	glass_mi.material_override = gm
	vp.add_child(glass_mi)
	interior_mi = MeshInstance3D.new()
	var im := StandardMaterial3D.new()
	im.vertex_color_use_as_albedo = true
	im.roughness = 0.9
	interior_mi.material_override = im
	vp.add_child(interior_mi)
	ghost_mi = MeshInstance3D.new()
	var ghm := StandardMaterial3D.new()
	ghm.albedo_color = Color(0.55, 0.7, 0.9, 0.16)
	ghm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghm.cull_mode = BaseMaterial3D.CULL_DISABLED
	ghm.no_depth_test = false
	ghost_mi.material_override = ghm
	vp.add_child(ghost_mi)
	cabin = Node3D.new()
	vp.add_child(cabin)
	overlay = Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.draw.connect(_draw_overlay)
	add_child(overlay)
	resized.connect(func():
		if not _user_zoomed:
			_fit()
		_update_cam()
		overlay.queue_redraw())

func setup(p: PorterProject, m: HalfMesh) -> void:
	project = p
	mesh = m
	rebuild_body()
	set_view(view)

func set_view(v: String) -> void:
	view = v
	pan = Vector2.ZERO
	_user_zoomed = false
	_fit()
	_rebuild_deco()
	_apply_material()
	_update_cam()
	overlay.queue_redraw()

func set_xray(on: bool) -> void:
	xray = on
	_apply_material()

func _apply_material() -> void:
	var see_through := xray and view != "3d"
	var mats: Array = [body_mat]
	for v in _photos:
		if _photos[v]["mat"]:
			mats.append(_photos[v]["mat"])
	for m in mats:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if see_through else BaseMaterial3D.TRANSPARENCY_DISABLED
		m.albedo_color = Color(1, 1, 1, 0.45 if see_through else 1.0)

var _photos := {}                     # view -> {"img": Image, "mat": StandardMaterial3D}

func _photo(view_name: String) -> Dictionary:
	if not _photos.has(view_name):
		var img := project.load_photo(view_name)
		var entry := {"img": img, "mat": null}
		if img:
			var m := StandardMaterial3D.new()
			var tex_img := img.duplicate() as Image
			tex_img.generate_mipmaps()      # faces seen at an angle sample smaller levels
			m.albedo_texture = ImageTexture.create_from_image(tex_img)
			m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			m.roughness = 0.6
			entry["mat"] = m
		_photos[view_name] = entry
	return _photos[view_name]

func rebuild_body() -> void:
	if _deco_paint != show_paint:
		_deco_paint = show_paint
		_rebuild_deco()                 # wheels switch between plain and textured
	ghost_mi.mesh = ghost.build_mesh({}, true) if ghost else null
	refresh_cabin()
	glass_mi.mesh = mesh.build_glass() if show_paint else null
	interior_mi.mesh = mesh.build_interior() if (show_paint and show_interior) else null
	if not show_paint:
		body.material_override = body_mat
		body.mesh = mesh.build_mesh(paint_colors, true)
		overlay.queue_redraw()
		return
	var images := {}
	for v in PorterProject.VIEWS:
		images[v] = _photo(v)["img"]
	var built := PhotoTexturer.build(mesh, project, paint_colors, images)
	var am: ArrayMesh = built[0]
	body.material_override = null
	am.surface_set_material(0, body_mat)
	var order: Array = built[1]
	for i in order.size():
		am.surface_set_material(i + 1, _photo(order[i])["mat"])
	body.mesh = am
	_apply_material()
	overlay.queue_redraw()
	overlay.queue_redraw()

# ---------------------------------------------------------------- cabin

var _steer_tex_cache: Texture2D
var _steer_tex_dirty := true

## Mark the steering picture as changed (re-read on the next refresh).
func steering_picture_changed() -> void:
	_steer_tex_dirty = true

## Dashboard (photo on its face), steering wheel and gauges inside the body.
## Hidden while the dash itself is the mesh being edited (it is drawn as the
## body then).
func refresh_cabin() -> void:
	for c in cabin.get_children():
		c.queue_free()
	if project == null or not show_cabin:
		return
	var editing_dash := ghost != null
	if dash and not editing_dash:
		var img := project.load_photo("dash")
		var images := {"dash": img}
		var built := PhotoTexturer.build(dash, project, paint_colors, images)
		var am: ArrayMesh = built[0]
		var dm := StandardMaterial3D.new()
		dm.vertex_color_use_as_albedo = true
		dm.roughness = 0.8
		am.surface_set_material(0, dm)
		if (built[1] as Array).size() > 0:
			var tm := StandardMaterial3D.new()
			var ti := img.duplicate() as Image
			ti.generate_mipmaps()
			tm.albedo_texture = ImageTexture.create_from_image(ti)
			tm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			tm.roughness = 0.8
			am.surface_set_material(1, tm)
		var mi := MeshInstance3D.new()
		mi.mesh = am
		cabin.add_child(mi)
	# gauges: dark face, white ring, orange needle
	for g in project.interior.get("gauges", []):
		cabin.add_child(_gauge_node(g))
	# steering wheel + column
	if not show_steering:
		return
	var s := project.steering()
	if _steer_tex_dirty:
		_steer_tex_dirty = false
		var simg := project.load_steering_texture()
		_steer_tex_cache = ImageTexture.create_from_image(simg) if simg else null
	var wheel := MeshInstance3D.new()
	wheel.name = "SteeringWheel"
	wheel.mesh = InteriorBuilder.steering_mesh(s["diameter_m"], s["thickness_m"], s["holes"])
	var wm := StandardMaterial3D.new()
	wm.roughness = 0.6
	if _steer_tex_cache:
		wm.albedo_texture = _steer_tex_cache
	else:
		wm.albedo_color = Color(0.12, 0.12, 0.13)
	if editing_dash:
		wm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA     # see the dash through it
		wm.albedo_color.a = 0.3
	wheel.material_override = wm
	var c := project.steering_center()
	wheel.transform = InteriorBuilder.steering_transform(c, s["tilt_deg"])
	cabin.add_child(wheel)
	var col := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.03
	cm.bottom_radius = 0.035
	cm.height = 0.45
	cm.radial_segments = 8
	col.mesh = cm
	var colm := StandardMaterial3D.new()
	colm.albedo_color = Color(0.1, 0.1, 0.11)
	col.material_override = colm
	# the column runs from behind the hub forward-down, along the wheel's axis
	var axis := wheel.transform.basis.z.normalized()
	col.transform = Transform3D(Basis(Quaternion(Vector3.UP, -axis)), c - axis * (0.45 * 0.5 + s["thickness_m"]))
	cabin.add_child(col)

func _gauge_node(g: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.position = Vector3(g["x"], g["y"], float(g["z"]) + 0.004)
	var r: float = g["r"]
	var face := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = r
	cyl.bottom_radius = r
	cyl.height = 0.004
	cyl.radial_segments = 20
	face.mesh = cyl
	face.rotation = Vector3(PI * 0.5, 0, 0)
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.04, 0.04, 0.05, 0.55)
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	face.material_override = fm
	root.add_child(face)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = r * 0.92
	tm.outer_radius = r
	tm.rings = 20
	ring.mesh = tm
	ring.rotation = Vector3(PI * 0.5, 0, 0)
	var rm := StandardMaterial3D.new()
	rm.albedo_color = Color(0.85, 0.88, 0.92)
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = rm
	root.add_child(ring)
	var pivot := Node3D.new()
	pivot.position.z = 0.004
	pivot.rotation.z = -InteriorBuilder.needle_angle(demo_reading)
	var nd := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(maxf(r * 0.07, 0.002), r * 0.85, 0.002)
	nd.mesh = bm
	nd.position.y = r * 0.42
	var nm := StandardMaterial3D.new()
	nm.albedo_color = Color(1.0, 0.45, 0.1)
	nm.emission_enabled = true
	nm.emission = Color(1.0, 0.45, 0.1)
	nm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	nd.material_override = nm
	pivot.add_child(nd)
	root.add_child(pivot)
	return root

# ---------------------------------------------------------------- scene dressing

func _rebuild_deco() -> void:
	for c in deco.get_children():
		c.queue_free()
	var d := project.dims
	# wheels (reference only; the game builds real wheels from the tire size)
	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color(0.1, 0.1, 0.11, 0.55 if view != "3d" else 1.0)
	wm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if view != "3d" else BaseMaterial3D.TRANSPARENCY_DISABLED
	for ax in [[-d["wheelbase_m"] * 0.5, d["track_front_m"], false], [d["wheelbase_m"] * 0.5, d["track_rear_m"], true]]:
		var r: float = project.tire_radius(ax[2])
		var tw: float = project.tires.get("rear_width_m" if ax[2] else "front_width_m", 0.22)
		var tex := _wheel_tex(ax[2])
		for sx in [-0.5, 0.5]:
			var w := MeshInstance3D.new()
			if tex and show_paint:
				# textured wheel model (axle along X, picture facing outward)
				w.mesh = WheelBuilder.build(r, tw, project.rim_radius(ax[2]))
				var mats := WheelBuilder.materials(tex)
				w.mesh.surface_set_material(0, mats[0])
				w.mesh.surface_set_material(1, mats[1])
				if sx < 0.0:
					w.rotation = Vector3(0, PI, 0)
			else:
				var cyl := CylinderMesh.new()
				cyl.top_radius = r
				cyl.bottom_radius = r
				cyl.height = tw
				cyl.radial_segments = 16
				w.mesh = cyl
				w.material_override = wm
				w.rotation = Vector3(0, 0, PI * 0.5)
			w.position = Vector3(ax[1] * sx, r, ax[0])
			deco.add_child(w)
	# ground line in 3D
	if view == "3d":
		var g := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(14, 14)
		g.mesh = pm
		var gm := StandardMaterial3D.new()
		gm.albedo_color = Color(0.07, 0.1, 0.15)
		g.material_override = gm
		g.position.y = -0.002
		deco.add_child(g)
		return
	var pv: String = view
	var img := project.load_photo(pv)
	if img:
		deco.add_child(_photo_quad(pv, img))

var _wheel_cache := {}
var _deco_paint := false

func _wheel_tex(rear: bool) -> Texture2D:
	var key := "rear" if rear else "front"
	if not _wheel_cache.has(key):
		var img := project.load_wheel_texture(rear)
		_wheel_cache[key] = ImageTexture.create_from_image(img) if img else null
	return _wheel_cache[key]

## Reload the wheel pictures and rebuild the wheels.
func refresh_wheels() -> void:
	_wheel_cache.clear()
	_rebuild_deco()

## A 2D point in a drawing view's axes placed in the scene (in front of the body).
func view2d_to_world(v: String, q: Vector2) -> Vector3:
	var big := 5.0
	match v:
		"side":
			return Vector3(-big, q.y, q.x)
		"front":
			return Vector3(q.x, q.y, -big)
		"rear":
			return Vector3(q.x, q.y, big)
		_:
			return Vector3(q.y, big, q.x)

func _photo_world(pv: String, p: Vector2) -> Vector3:
	var d := project.dims
	var mid: float = project.front_axle_x() + d["wheelbase_m"] * 0.5
	match pv:
		"side":
			return Vector3(d["width_m"] + 1.0, p.y, p.x - mid)         # behind the body, seen from the left
		"front":
			return Vector3(-p.x, p.y, d["length_m"] - mid + 1.0)       # behind the body, seen from the front
		"rear":
			return Vector3(p.x, p.y, -mid - 1.0)                       # behind the body, seen from the rear
		_:
			return Vector3(p.y, -0.05, p.x - mid)                      # under the body, seen from above

func _photo_quad(pv: String, img: Image) -> MeshInstance3D:
	var sz := Vector2(img.get_width(), img.get_height())
	var corners := [Vector2(0, 0), Vector2(sz.x, 0), sz, Vector2(0, sz.y)]
	var uv := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for tri in [[0, 1, 2], [0, 2, 3]]:
		for i in tri:
			st.set_uv(uv[i])
			st.add_vertex(_photo_world(pv, project.image_to_frame(pv, corners[i], sz)))
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_texture = ImageTexture.create_from_image(img)
	m.albedo_color = Color(1, 1, 1, float(project.views[pv]["opacity"]))
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = m
	return mi

# ---------------------------------------------------------------- camera

func _target() -> Vector3:
	return Vector3(0, project.dims["height_m"] * 0.5, 0) if project else Vector3(0, 0.7, 0)

func _update_cam() -> void:
	if project == null:
		return
	if view == "3d" and driver_view:
		# left-hand drive: driver's eye behind the windshield, left of center
		cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		cam.fov = driver_fov
		cam.near = 0.02
		cam.position = project.driver_eye()
		ghost_mi.visible = false          # the body ghost would wash over the cabin
		cam.basis = Basis.from_euler(Vector3(pitch * 0.5 - deg_to_rad(5.0), yaw + deg_to_rad(140.0), 0))
		return
	ghost_mi.visible = true
	if view == "3d":
		cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		cam.fov = 40.0
		cam.near = 0.05
		var off := Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) * dist
		cam.position = _target() + off
		cam.look_at(_target(), Vector3.UP)
		return
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = ortho_size
	cam.near = 0.05
	cam.far = 100.0
	var b: Basis
	match view:
		"side":    # from the car's left: screen right = rear
			b = Basis(Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3(-1, 0, 0))
		"front":   # from ahead: screen right = car's left
			b = Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1))
		"rear":    # from behind: screen right = car's right
			b = Basis(Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
		_:         # from above, front on the left: screen up = car's right
			b = Basis(Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0))
	cam.basis = b
	cam.position = _target() + b.x * pan.x + b.y * pan.y + b.z * 20.0

## World metres per screen pixel in the view plane.
func _m_per_px() -> float:
	if view == "3d" and driver_view:
		# at the depth of what's being moved (the selection), else ~80 cm away
		var depth := 0.8
		var ids := selected_vert_ids()
		if not ids.is_empty():
			var c := Vector3.ZERO
			for i in ids:
				c += mesh.verts[i]
			depth = maxf(_depth(c / ids.size()), 0.1)
		return 2.0 * depth * tan(deg_to_rad(cam.fov) * 0.5) / maxf(size.y, 1.0)
	if view == "3d":
		var dd := cam.position.distance_to(_target())
		return 2.0 * dd * tan(deg_to_rad(cam.fov) * 0.5) / maxf(size.y, 1.0)
	return ortho_size / maxf(size.y, 1.0)

func screen_delta_to_world(d: Vector2) -> Vector3:
	var b := cam.global_transform.basis
	var k := _m_per_px()
	var dx := d.x
	var dy := d.y
	if lock_axis == 1:
		dy = 0.0
	elif lock_axis == 2:
		dx = 0.0
	return (b.x * dx - b.y * dy) * k

func project_point(p: Vector3) -> Vector2:
	return cam.unproject_position(p)

func _depth(p: Vector3) -> float:
	# distance along the view direction (smaller = nearer the camera)
	return (p - cam.global_position).dot(-cam.global_transform.basis.z)

# ---------------------------------------------------------------- selection

func selected_vert_ids() -> Array:
	if pick == Pick.FACES:
		return mesh.verts_of_faces(sel_faces.keys())
	return sel_verts.keys()

func clear_selection() -> void:
	sel_verts.clear()
	sel_faces.clear()
	selection_changed.emit()
	overlay.queue_redraw()

func select_all() -> void:
	if pick == Pick.FACES:
		for i in mesh.faces.size():
			sel_faces[i] = true
	else:
		for i in mesh.verts.size():
			sel_verts[i] = true
	selection_changed.emit()
	overlay.queue_redraw()

func _candidates_verts(s: Vector2) -> Array:
	var out := []
	for i in mesh.verts.size():
		var p := mesh.verts[i]
		if cam.is_position_behind(p):
			continue
		var d := project_point(p).distance_to(s)
		if d < 44.0:
			out.append([i, d, _depth(p)])
	# nearest on screen first; among near-equal, nearest to the camera
	out.sort_custom(func(a, b): return a[1] + a[2] * 4.0 < b[1] + b[2] * 4.0)
	return out

func _candidates_faces(s: Vector2) -> Array:
	var out := []
	for fi in mesh.faces.size():
		var poly := PackedVector2Array()
		var f: PackedInt32Array = mesh.faces[fi]
		var behind := false
		for i in f:
			if cam.is_position_behind(mesh.verts[i]):
				behind = true
			poly.append(project_point(mesh.verts[i]))
		if behind:
			continue
		if Geometry2D.is_point_in_polygon(s, poly):
			out.append([fi, 0.0, _depth(mesh.face_center(f))])
	out.sort_custom(func(a, b): return a[2] < b[2])
	return out

func _tap_select(s: Vector2) -> void:
	var cands := _candidates_verts(s) if pick == Pick.POINTS else _candidates_faces(s)
	var same_spot := s.distance_to(_last_tap) < 16.0
	_last_tap = s
	_cycle = (_cycle + 1) if same_spot else 0
	var target := sel_verts if pick == Pick.POINTS else sel_faces
	if cands.is_empty():
		if not multi:
			target.clear()
	else:
		var id: int = cands[_cycle % cands.size()][0]
		if multi:
			if target.has(id) and not same_spot:
				target.erase(id)
			else:
				target[id] = true
		else:
			target.clear()
			target[id] = true
	selection_changed.emit()
	overlay.queue_redraw()

func _near_selection(s: Vector2) -> bool:
	for i in selected_vert_ids():
		if project_point(mesh.verts[i]).distance_to(s) < 56.0:
			return true
	if pick == Pick.FACES:
		for c in _candidates_faces(s):
			if sel_faces.has(c[0]):
				return true
	return false

## Nearest edge to a screen point within `radius` px: [a, b, t] (t along a->b),
## or [] if none.
func pick_edge_t(s: Vector2, radius: float = 34.0) -> Array:
	var best := []
	var best_d := radius
	for e in mesh.edges():
		var pa := mesh.verts[e.x]
		var pb := mesh.verts[e.y]
		if cam.is_position_behind(pa) or cam.is_position_behind(pb):
			continue
		var a := project_point(pa)
		var b := project_point(pb)
		var ab := b - a
		var t := clampf((s - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
		var d := (a + ab * t).distance_to(s)
		if d < best_d:
			best_d = d
			best = [e.x, e.y, t]
	return best

## World point under a screen position, at the depth of the nearest point of
## the model (so a new point lands in the body's plane for this view).
func screen_to_world_near(s: Vector2) -> Vector3:
	var best := -1
	var best_d := INF
	for i in mesh.verts.size():
		if cam.is_position_behind(mesh.verts[i]):
			continue
		var d := project_point(mesh.verts[i]).distance_to(s)
		if d < best_d:
			best_d = d
			best = i
	var depth := 10.0
	if best >= 0:
		depth = _depth(mesh.verts[best])
	return cam.project_position(s, depth)

func _pick_edge(s: Vector2) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_d := 48.0
	for e in mesh.edges():
		var a := project_point(mesh.verts[e.x])
		var b := project_point(mesh.verts[e.y])
		var q := Geometry2D.get_closest_point_to_segment(s, a, b)
		var d := q.distance_to(s)
		if d < best_d:
			best_d = d
			best = e
	return best

# ---------------------------------------------------------------- input

func _gui_input(e: InputEvent) -> void:
	if mesh == null:
		return
	if e is InputEventScreenTouch:
		if e.pressed:
			_touches[e.index] = e.position
			if _touches.size() == 1:
				_moved = false
				_drag = "move" if (tool == "" and _near_selection(e.position)) else "pan"
				_start_pos.clear()
				if _drag == "move":
					for i in selected_vert_ids():
						_start_pos[i] = mesh.verts[i]
			else:
				_end_move()
				_drag = ""
			_begin()
		else:
			if _touches.size() == 1 and not _moved:
				_on_tap(e.position)
			_touches.erase(e.index)
			if _touches.is_empty():
				_end_move()
				_drag = ""
			_begin()
		accept_event()
	elif e is InputEventScreenDrag:
		_touches[e.index] = e.position
		_on_drag()
		accept_event()
	elif e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom(1.0 / 1.12)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom(1.12)

func _begin() -> void:
	_g = {"t": _touches.duplicate(), "pan": pan, "yaw": yaw, "pitch": pitch, "fov": driver_fov,
		"size": ortho_size, "dist": dist}

func _on_tap(s: Vector2) -> void:
	if tool == "wheels" or tool == "interior":
		return
	if tool == "draw_window":
		if view == "3d":
			return
		window_pts.append(HalfMesh.view_to2d(view, cam.project_position(s, 10.0)))
		window_point_added.emit()
		overlay.queue_redraw()
		return
	if tool == "draw_arch":
		if view != "side":
			return
		var w := cam.project_position(s, 10.0)      # side view: screen gives depth (z) and height (y)
		arch_pts.append(Vector2(w.z, maxf(w.y, 0.0)))
		arch_point_added.emit()
		overlay.queue_redraw()
		return
	if tool == "add_point":
		add_point_tap.emit(s)
		return
	if tool == "paint":
		var c := _candidates_faces(s)
		if not c.is_empty():
			face_tapped.emit(c[0][0])
		return
	if tool == "loop_cut":
		var edge := _pick_edge(s)
		if edge.x >= 0:
			edge_tapped.emit(edge.x, edge.y)
		return
	_tap_select(s)

func _on_drag() -> void:
	var st: Dictionary = _g.get("t", {})
	var keys := _touches.keys()
	if keys.size() == 1 and st.has(keys[0]):
		var d: Vector2 = _touches[keys[0]] - st[keys[0]]
		if not _moved and d.length() < 14.0:
			return
		if not _moved and _drag == "move":
			mesh.push_undo()
		_moved = true
		if _drag == "move":
			var w := screen_delta_to_world(d)
			for i in _start_pos:
				mesh.set_vert(i, _start_pos[i] + w)
			rebuild_body()
			mesh_edited.emit(false)
		elif view == "3d":
			yaw = _g["yaw"] - d.x * 0.008
			pitch = clampf(_g["pitch"] + d.y * 0.008, deg_to_rad(-15), deg_to_rad(85))
			_update_cam()
		else:
			var k := _m_per_px()
			pan = _g["pan"] + Vector2(-d.x, d.y) * k
			_user_zoomed = true
			_update_cam()
	elif keys.size() >= 2 and st.has(keys[0]) and st.has(keys[1]):
		_moved = true
		var k2: float = (st[keys[1]] - st[keys[0]]).length() / maxf((_touches[keys[1]] - _touches[keys[0]]).length(), 1.0)
		_user_zoomed = true
		if view == "3d" and driver_view:
			if not _g.has("fov"):
				_g["fov"] = driver_fov
			driver_fov = clampf(float(_g["fov"]) * k2, 30.0, 100.0)
		elif view == "3d":
			dist = clampf(_g["dist"] * k2, 1.5, 40.0)
		else:
			ortho_size = clampf(_g["size"] * k2, 0.3, 30.0)
		_update_cam()
	overlay.queue_redraw()

func _end_move() -> void:
	if _drag == "move" and _moved:
		mesh_edited.emit(true)
	_start_pos.clear()

func zoom(k: float) -> void:
	_user_zoomed = true
	if view == "3d" and driver_view:
		driver_fov = clampf(driver_fov * k, 30.0, 100.0)
	elif view == "3d":
		dist = clampf(dist * k, 1.5, 40.0)
	else:
		ortho_size = clampf(ortho_size * k, 0.3, 30.0)
	_update_cam()
	overlay.queue_redraw()

## Move the selection by a screen-direction step in metres (fine adjust).
func nudge(dir: Vector2, metres: float) -> void:
	var ids := selected_vert_ids()
	if ids.is_empty():
		return
	mesh.push_undo()
	var b := cam.global_transform.basis
	mesh.move_verts(ids, (b.x * dir.x - b.y * dir.y) * metres)
	rebuild_body()
	mesh_edited.emit(true)

## Move the selection toward (+) or away from (-) the camera, in metres.
func nudge_depth(metres: float) -> void:
	var ids := selected_vert_ids()
	if ids.is_empty():
		return
	mesh.push_undo()
	mesh.move_verts(ids, cam.global_transform.basis.z * metres)
	rebuild_body()
	mesh_edited.emit(true)

# ---------------------------------------------------------------- overlay

## Editing the dash from the driver's seat: points and faces are shown and
## can be picked and dragged in the first-person camera.
func cabin_editing() -> bool:
	return driver_view and view == "3d" and ghost != null

func _draw_overlay() -> void:
	if mesh == null or (driver_view and view == "3d" and ghost == null):
		return
	var o := overlay
	# selected faces
	for fi in sel_faces:
		if fi >= mesh.faces.size():
			continue
		var poly := PackedVector2Array()
		for i in mesh.faces[fi]:
			poly.append(project_point(mesh.verts[i]))
		if poly.size() >= 3:
			o.draw_colored_polygon(poly, Color(C_SEL, 0.35))
	# mirrored half (dim), then the editable half
	for e in mesh.edges():
		var a := mesh.verts[e.x]
		var b := mesh.verts[e.y]
		var am := Vector3(-a.x, a.y, a.z)
		var bm := Vector3(-b.x, b.y, b.z)
		if not (cam.is_position_behind(am) or cam.is_position_behind(bm)):
			o.draw_line(project_point(am), project_point(bm), C_EDGE_MIRROR, 1.5, true)
	for e in mesh.edges():
		var a2 := mesh.verts[e.x]
		var b2 := mesh.verts[e.y]
		if cam.is_position_behind(a2) or cam.is_position_behind(b2):
			continue
		var sel := sel_verts.has(e.x) and sel_verts.has(e.y)
		var col := C_SEL if sel else C_EDGE
		if tool in ["paint", "wheels"]:
			col = Color(0.85, 0.92, 1.0, 0.45)
		o.draw_line(project_point(a2), project_point(b2), col, 2.5 if sel else (1.2 if tool in ["paint", "wheels"] else 2.0), true)
	if pick == Pick.POINTS and tool not in ["paint", "wheels", "draw_arch", "draw_window"]:
		for i in mesh.verts.size():
			var p := mesh.verts[i]
			if cam.is_position_behind(p):
				continue
			var s := project_point(p)
			if sel_verts.has(i):
				o.draw_circle(s, 11.0, C_SEL)
			else:
				o.draw_circle(s, 6.5, C_VERT if not mesh.is_center(i) else Color(0.6, 1.0, 0.7))
	if tool == "draw_window" and view != "3d":
		var wl := PackedVector2Array()
		for q in window_pts:
			wl.append(project_point(view2d_to_world(view, q)))
		if wl.size() >= 2:
			var closed := wl.duplicate()
			closed.append(wl[0])
			o.draw_polyline(closed, C_SEL, 3.0, true)
		for q in wl:
			o.draw_circle(q, 8.0, C_SEL)
		o.draw_string(get_theme_default_font(), Vector2(20, size.y - 24), "CUT WINDOW: tap around the window's outline (%d corners)" % window_pts.size(), HORIZONTAL_ALIGNMENT_LEFT, -1, 26, C_SEL)
	if tool == "draw_arch" and view == "side":
		var line := PackedVector2Array()
		var x_side: float = -project.dims["width_m"] * 0.5
		for p in arch_pts:
			line.append(project_point(Vector3(x_side, p.y, p.x)))
		if line.size() >= 2:
			o.draw_polyline(line, C_SEL, 3.0, true)
		for i in line.size():
			o.draw_circle(line[i], 10.0 if (i == 0 or i == line.size() - 1) else 7.0, C_SEL)
		o.draw_string(get_theme_default_font(), Vector2(20, size.y - 24), "DRAW ARCH: tap along the wheel well, end to end (%d points)" % arch_pts.size(), HORIZONTAL_ALIGNMENT_LEFT, -1, 26, C_SEL)
	if tool == "paint":
		pass
	elif tool == "add_point":
		o.draw_string(get_theme_default_font(), Vector2(20, size.y - 24), "ADD POINT: tap an edge, or empty space for a free point", HORIZONTAL_ALIGNMENT_LEFT, -1, 26, C_SEL)
	elif tool == "loop_cut":
		o.draw_string(get_theme_default_font(), Vector2(20, size.y - 24), "LOOP CUT: tap an edge to cut across", HORIZONTAL_ALIGNMENT_LEFT, -1, 26, C_SEL)
