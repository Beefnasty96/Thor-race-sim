class_name BlueprintPreview
extends SubViewportContainer
## 3D check of the reference setup: each aligned photo is placed on its plane
## around a true-scale box with wheels, in game coordinates (+X right, +Y up,
## -Z forward, origin on the ground midway between the axles). Drag to orbit,
## pinch / wheel to zoom.

var project: PorterProject
var vp: SubViewport
var cam: Camera3D
var root3d: Node3D
var yaw := deg_to_rad(-35.0)
var pitch := deg_to_rad(18.0)
var dist := 9.0
var _touches := {}
var _start := {}

func _init() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	vp = SubViewport.new()
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_2X
	vp.transparent_bg = false
	add_child(vp)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.03, 0.05, 0.09)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.8, 0.85, 1.0)
	env.environment = e
	vp.add_child(env)
	cam = Camera3D.new()
	cam.fov = 40.0
	vp.add_child(cam)
	root3d = Node3D.new()
	vp.add_child(root3d)

func show_project(p: PorterProject) -> void:
	project = p
	rebuild()

func rebuild() -> void:
	for c in root3d.get_children():
		c.queue_free()
	if project == null:
		return
	var d := project.dims
	dist = maxf(d["length_m"], 3.0) * 2.0
	_add_box_outline()
	_add_ground_grid()
	for v in PorterProject.VIEWS:
		var img := project.load_photo(v)
		if img:
			_add_photo(v, img)
	_update_cam()

# frame (view meters) -> world, per view
func _to_world(view: String, p: Vector2) -> Vector3:
	var d := project.dims
	var mid: float = project.front_axle_x() + d["wheelbase_m"] * 0.5
	var w: float = d["width_m"]
	match view:
		"side":
			return Vector3(-w * 0.5 - 0.6, p.y, p.x - mid)          # stands off the car's left side
		"front":
			return Vector3(-p.x, p.y, -mid - 0.6)
		"rear":
			return Vector3(p.x, p.y, d["length_m"] - mid + 0.6)
		_:
			return Vector3(p.y, -0.02, p.x - mid)                   # lies on the ground under the box

func _add_photo(view: String, img: Image) -> void:
	var size := Vector2(img.get_width(), img.get_height())
	var corners := [Vector2(0, 0), Vector2(size.x, 0), size, Vector2(0, size.y)]
	var uv := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for tri in [[0, 1, 2], [0, 2, 3]]:
		for i in tri:
			st.set_uv(uv[i])
			st.add_vertex(_to_world(view, project.image_to_frame(view, corners[i], size)))
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1, 1, 1, 0.8)
	m.albedo_texture = ImageTexture.create_from_image(img)
	mi.material_override = m
	root3d.add_child(mi)

func _line_mesh(points: PackedVector3Array, col: Color) -> MeshInstance3D:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for p in points:
		im.surface_add_vertex(p)
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	mi.material_override = m
	return mi

func _add_box_outline() -> void:
	var d := project.dims
	var mid: float = project.front_axle_x() + d["wheelbase_m"] * 0.5
	var x: float = d["width_m"] * 0.5
	var z0: float = -mid
	var z1: float = d["length_m"] - mid
	var h: float = d["height_m"]
	var c := [Vector3(-x, 0, z0), Vector3(x, 0, z0), Vector3(x, 0, z1), Vector3(-x, 0, z1),
		Vector3(-x, h, z0), Vector3(x, h, z0), Vector3(x, h, z1), Vector3(-x, h, z1)]
	var pts := PackedVector3Array()
	for e in [[0,1],[1,2],[2,3],[3,0],[4,5],[5,6],[6,7],[7,4],[0,4],[1,5],[2,6],[3,7]]:
		pts.append(c[e[0]]); pts.append(c[e[1]])
	root3d.add_child(_line_mesh(pts, Color(0.32, 0.72, 1.0)))
	# wheels as circles at the true track width, axle positions and radius
	var wp := PackedVector3Array()
	for ax in [[-d["wheelbase_m"] * 0.5, d["track_front_m"], false], [d["wheelbase_m"] * 0.5, d["track_rear_m"], true]]:
		var r: float = project.tire_radius(ax[2])
		for sx in [-0.5, 0.5]:
			var cx: float = ax[1] * sx
			for i in 24:
				var a0 := TAU * i / 24.0
				var a1 := TAU * (i + 1) / 24.0
				wp.append(Vector3(cx, r + sin(a0) * r, ax[0] + cos(a0) * r))
				wp.append(Vector3(cx, r + sin(a1) * r, ax[0] + cos(a1) * r))
	root3d.add_child(_line_mesh(wp, Color(1.0, 0.72, 0.2)))

func _add_ground_grid() -> void:
	var pts := PackedVector3Array()
	for i in range(-6, 7):
		pts.append(Vector3(i, 0, -6)); pts.append(Vector3(i, 0, 6))
		pts.append(Vector3(-6, 0, i)); pts.append(Vector3(6, 0, i))
	root3d.add_child(_line_mesh(pts, Color(0.32, 0.62, 1.0, 0.25)))

func _update_cam() -> void:
	var target := Vector3(0, project.dims["height_m"] * 0.45 if project else 0.7, 0)
	var off := Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) * dist
	cam.position = target + off
	cam.look_at(target, Vector3.UP)

func _gui_input(e: InputEvent) -> void:
	if e is InputEventScreenTouch:
		if e.pressed:
			_touches[e.index] = e.position
		else:
			_touches.erase(e.index)
		_start = {"t": _touches.duplicate(), "yaw": yaw, "pitch": pitch, "dist": dist}
		accept_event()
	elif e is InputEventScreenDrag:
		_touches[e.index] = e.position
		var st: Dictionary = _start.get("t", {})
		var keys := _touches.keys()
		if keys.size() == 1 and st.has(keys[0]):
			var dlt: Vector2 = _touches[keys[0]] - st[keys[0]]
			yaw = _start["yaw"] - dlt.x * 0.008
			pitch = clampf(_start["pitch"] + dlt.y * 0.008, deg_to_rad(-10), deg_to_rad(85))
		elif keys.size() >= 2 and st.has(keys[0]) and st.has(keys[1]):
			var k: float = (st[keys[1]] - st[keys[0]]).length() / maxf((_touches[keys[1]] - _touches[keys[0]]).length(), 1.0)
			dist = clampf(_start["dist"] * k, 2.0, 40.0)
		_update_cam()
		accept_event()
	elif e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist = maxf(2.0, dist / 1.1); _update_cam()
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = minf(40.0, dist * 1.1); _update_cam()
