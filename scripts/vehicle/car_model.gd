class_name CarModel
extends Node3D
## Visual car built from the Blender-exported glTF assets:
##   <dir>/tahoe_body.glb   body + interior + "SteeringWheel" node
##   <dir>/tahoe_wheel.glb  one wheel (axis = X, outer face = +X)
##   <dir>/model_info.json  driver eye, steering pivot, gauge positions, credits
## Handles paint (body colour + two-tone lower), the steering wheel turning
## with the front wheels, live speedometer/tach needles and brake lights.

var steering_lock_rad := 3.0 * PI   # half of lock-to-lock (3.0 turns factory) — set from car data
const SPEEDO_MAX_MPH := 100.0
const TACH_MAX_RPM := 6000.0
const NEEDLE_SWEEP := deg_to_rad(240.0)

var car: Vehicle
var info: Dictionary = {}
var wheel_nodes: Array[Node3D] = []
var driver_eye := Vector3(-0.38, 1.46, 0.38)
var _paint_mat: StandardMaterial3D
var _lower_mat: StandardMaterial3D
var _tail_mats: Array[StandardMaterial3D] = []
var _steering: Node3D
var _steer_base := Transform3D.IDENTITY
var _speedo: Node3D
var _tach: Node3D
var _small: Dictionary = {}          # fuel / volts / oil / temp needles
var _tire_mats: Array[ShaderMaterial] = []
var _tire_meshes: Array[MeshInstance3D] = []
var _tire_scale: Array[float] = []
var _wheels_sized := false
const TIRE_SHADER := preload("res://assets/shaders/tire_squash.gdshader")

func build(dir: String, paint: Dictionary) -> void:
	for c in get_children():
		c.queue_free()
	wheel_nodes.clear()
	_tail_mats.clear()
	_tire_mats.clear()
	_tire_meshes.clear()
	_tire_scale.clear()
	_wheels_sized = false
	if FileAccess.file_exists(dir + "/model_info.json"):
		info = JSON.parse_string(FileAccess.get_file_as_string(dir + "/model_info.json"))
		var e: Array = info.get("driver_eye", [-0.38, 1.46, 0.38])
		driver_eye = Vector3(e[0], e[1], e[2])
	var body_scene: PackedScene = load(dir + "/tahoe_body.glb")
	var body := body_scene.instantiate()
	add_child(body)
	_prepare_materials(body)
	_steering = body.find_child("SteeringWheel", true, false) as Node3D
	if _steering:
		_steer_base = _steering.transform
	var wheel_scene: PackedScene = load(dir + "/tahoe_wheel.glb")
	for i in 4:
		var wn := Node3D.new()
		wn.name = ["FL", "FR", "RL", "RR"][i]
		var inst := wheel_scene.instantiate() as Node3D
		if i % 2 == 0:
			inst.scale = Vector3(-1, 1, 1)       # left wheels: outer face toward -X
		wn.add_child(inst)
		add_child(wn)
		wheel_nodes.append(wn)
		_setup_tire(inst)
	_build_gauges()
	set_paint(paint)

## Duplicate the shared materials we animate/recolour so each car owns them.
func _prepare_materials(root: Node) -> void:
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		for s in m.mesh.get_surface_count():
			var mat := m.mesh.surface_get_material(s) as StandardMaterial3D
			if mat == null:
				continue
			var n := mat.resource_name
			if n == "Paint":
				if _paint_mat == null:
					_paint_mat = mat.duplicate()
					_paint_mat.clearcoat_enabled = true
					_paint_mat.clearcoat = 1.0
					_paint_mat.clearcoat_roughness = 0.06
				m.set_surface_override_material(s, _paint_mat)
			elif n == "Lower":
				if _lower_mat == null:
					_lower_mat = mat.duplicate()
					_lower_mat.clearcoat_enabled = true
					_lower_mat.clearcoat = 1.0
				m.set_surface_override_material(s, _lower_mat)
			elif n == "Taillight":
				var t := mat.duplicate() as StandardMaterial3D
				t.emission_enabled = true
				t.emission = Color(1.0, 0.05, 0.02)
				m.set_surface_override_material(s, t)
				_tail_mats.append(t)
			elif n == "Glass":
				var g := mat.duplicate() as StandardMaterial3D
				g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				g.albedo_color.a = 0.45
				g.metallic = 0.2
				g.roughness = 0.04
				g.cull_mode = BaseMaterial3D.CULL_DISABLED
				m.set_surface_override_material(s, g)

## Swap the tyre surface for the squash shader (one material per wheel so each
## can deform on its own).
func _setup_tire(root: Node) -> void:
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		for s in m.mesh.get_surface_count():
			var mat := m.mesh.surface_get_material(s) as StandardMaterial3D
			if mat and mat.resource_name == "Tire":
				var sm := ShaderMaterial.new()
				sm.shader = TIRE_SHADER
				sm.set_shader_parameter("albedo", mat.albedo_color)
				sm.set_shader_parameter("roughness", mat.roughness)
				m.set_surface_override_material(s, sm)
				m.extra_cull_margin = 0.2
				_tire_mats.append(sm)
				_tire_meshes.append(m)
				return

func _update_tires() -> void:
	var n := mini(_tire_mats.size(), car.wheels.size())
	if not _wheels_sized and n > 0:
		_wheels_sized = true
		steering_lock_rad = car.def["steering"].get("lock_to_lock_turns", 3.0) * PI
		for i in n:                     # optional tyre sizes: scale the wheel mesh
			var w0 = car.wheels[i]
			var sc: float = w0.radius / 0.387
			var wn: Node3D = wheel_nodes[i].get_child(0)
			var sx: float = signf(wn.scale.x) * (w0.tire.width / 0.245)   # tread width
			wn.scale = Vector3(sx, sc, sc)
			_tire_scale.append(sc)
	for i in n:
		var w = car.wheels[i]
		var mi := _tire_meshes[i]
		var down_w: Vector3 = -w.hit_normal if w.contact else -car.global_basis.y
		var down_l := (mi.global_basis.inverse() * down_w).normalized()
		var sm := _tire_mats[i]
		sm.set_shader_parameter("down_dir", down_l)
		var sc: float = _tire_scale[i] if i < _tire_scale.size() else 1.0
		sm.set_shader_parameter("squash", (w.tire_defl / sc) if w.contact else 0.0)

func set_paint(paint: Dictionary) -> void:
	var c: Array = paint.get("color", [0.2, 0.25, 0.45])
	var body_col := Color(c[0], c[1], c[2])
	var lc: Array = paint.get("lower", c)
	var lower_col := Color(lc[0], lc[1], lc[2])
	var metal: float = paint.get("metallic", 0.5)
	if _paint_mat:
		_paint_mat.albedo_color = body_col
		_paint_mat.metallic = metal
		_paint_mat.roughness = 0.28
	if _lower_mat:
		_lower_mat.albedo_color = lower_col
		_lower_mat.metallic = paint.get("lower_metallic", metal)
		_lower_mat.roughness = 0.3

func _needle(len: float, col: Color) -> Node3D:
	var pivot := Node3D.new()
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.006, len, 0.003)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 2.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.material = mat
	mi.mesh = bm
	mi.position = Vector3(0, len * 0.5, 0)
	pivot.add_child(mi)
	return pivot

func _dial(radius: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = 0.002
	cm.radial_segments = 20
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.04, 0.05, 0.05)
	mat.emission_enabled = true
	mat.emission = Color(0.35, 0.85, 0.55)      # green-lit 90s GM cluster
	mat.emission_energy_multiplier = 0.12
	cm.material = mat
	mi.mesh = cm
	mi.rotation = Vector3(PI * 0.5, 0, 0)        # face the driver (+Z)
	# white scale ring
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = radius * 0.86
	tm.outer_radius = radius * 0.94
	tm.rings = 20
	tm.ring_segments = 3
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = Color(0.9, 0.95, 0.9)
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tm.material = rmat
	ring.mesh = tm
	ring.scale = Vector3(1, 0.2, 1)
	ring.position = Vector3(0, 0.002, 0)
	mi.add_child(ring)
	return mi

func _build_gauges() -> void:
	var cl: Dictionary = info.get("cluster", {})
	if cl.is_empty():
		return
	var tilt := deg_to_rad(float(cl.get("tilt_deg", -12)))
	for key in ["speedo", "tach", "fuel", "volts", "oil", "temp"]:
		if not cl.has(key):
			continue
		var p: Array = cl[key]
		var holder := Node3D.new()
		holder.position = Vector3(p[0], p[1], p[2] + 0.004)
		holder.rotation = Vector3(-tilt, 0, 0)
		add_child(holder)
		var r := 0.062 if key == "speedo" else (0.05 if key == "tach" else 0.024)
		holder.add_child(_dial(r))
		var n := _needle(r * 0.85, Color(1.0, 0.45, 0.1))
		n.position = Vector3(0, 0, 0.003)
		holder.add_child(n)
		match key:
			"speedo": _speedo = n
			"tach": _tach = n
			_: _small[key] = n

## Small gauges sweep 90 degrees, value 0..1.
func _set_small(key: String, v: float) -> void:
	var n: Node3D = _small.get(key)
	if n:
		n.rotation = Vector3(0, 0, PI * 0.25 - PI * 0.5 * clampf(v, 0.0, 1.0))

func _process(_dt: float) -> void:
	if car == null or not is_instance_valid(car):
		return
	if _steering:
		var a := -car.steer_actual * steering_lock_rad
		_steering.transform = _steer_base * Transform3D(Basis(Vector3(0, 0, 1), a), Vector3.ZERO)
	if _speedo:
		var mph := clampf(absf(car.speed_ms) * 2.23694, 0.0, SPEEDO_MAX_MPH)
		_speedo.rotation = Vector3(0, 0, NEEDLE_SWEEP * 0.5 - NEEDLE_SWEEP * mph / SPEEDO_MAX_MPH)
	if _tach:
		var rpm := clampf(car.engine.rpm(), 0.0, TACH_MAX_RPM)
		_tach.rotation = Vector3(0, 0, NEEDLE_SWEEP * 0.5 - NEEDLE_SWEEP * rpm / TACH_MAX_RPM)
	var rpm_now: float = car.engine.rpm()
	_set_small("fuel", 0.75)
	_set_small("volts", 0.55 if rpm_now > 400.0 else 0.4)                  # ~14 V running, ~12 V off
	_set_small("oil", clampf(0.25 + rpm_now / 4000.0, 0.0, 0.9) if rpm_now > 300.0 else 0.0)
	_set_small("temp", inverse_lerp(40.0, 130.0, car.engine.coolant_c))
	_update_tires()
	var brake := car.in_brake > 0.05
	for t in _tail_mats:
		t.emission_energy_multiplier = 2.5 if brake else 0.35
