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
var body_drop := 0.0
var _paint_mat: ShaderMaterial
const PAINT_SHADER := preload("res://assets/shaders/body_paint.gdshader")
const BAKED_SHADER := preload("res://assets/shaders/body_baked.gdshader")
var _model_dir := ""
var _baked := false
var _susp := {}                      # suspension part name -> MeshInstance3D
var _susp_mat: StandardMaterial3D
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
		body_drop = float(info.get("body_drop", 0.0))
		driver_eye = Vector3(e[0], e[1] + body_drop, e[2])
	_model_dir = dir
	var body_scene: PackedScene = load(dir + "/tahoe_body.glb")
	var body := body_scene.instantiate()
	body.position.y = body_drop          # seat the body over the factory-size tyres
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
	_build_suspension()
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
			if n == "BakedBody":
				if _paint_mat == null:
					_paint_mat = ShaderMaterial.new()
					_paint_mat.shader = BAKED_SHADER
					var bk: Dictionary = info.get("baked", {})
					_paint_mat.set_shader_parameter("detail_tex", load(_model_dir + "/" + bk.get("detail", "body_detail.png")))
					_paint_mat.set_shader_parameter("mask_tex", load(_model_dir + "/" + bk.get("mask", "body_mask.png")))
					_baked = true
				m.set_surface_override_material(s, _paint_mat)
			elif n == "Paint":
				if _paint_mat == null:
					_paint_mat = ShaderMaterial.new()
					_paint_mat.shader = PAINT_SHADER
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
		_paint_mat.set_shader_parameter("body_color", body_col)
		_paint_mat.set_shader_parameter("lower_color", lower_col)
		_paint_mat.set_shader_parameter("body_metallic", metal)
		_paint_mat.set_shader_parameter("lower_metallic", paint.get("lower_metallic", metal))
		_paint_mat.set_shader_parameter("two_tone", paint.has("lower"))
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
	mat.albedo_color = Color(0.025, 0.025, 0.03)  # black faces, white scales ('95-'99 cluster)
	mat.roughness = 0.6
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
		holder.position = Vector3(p[0], p[1] + body_drop, p[2] + 0.004)
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
	if _baked:
		_paint_mat.set_shader_parameter("brake", 1.0 if brake else 0.0)
	_update_suspension()


# ---------------------------------------------------------------- suspension
# Independent moving parts, rebuilt from the wheel positions every frame:
#  front: SLA control arms, knuckles, tie rods, shocks, torsion bars, and the
#         4WD front diff + half-shafts + front driveshaft
#  rear:  solid axle + diff, 2-stage leaf springs, shocks, rear driveshaft
#  chassis: frame rails, transmission / transfer case
const _BOX := 0
const _CYL := 1

func _part(name: String, kind: int, radius := 0.03, size := Vector2(0.05, 0.05), mat: Material = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	if kind == _BOX:
		var bm := BoxMesh.new()
		bm.size = Vector3(size.x, 1.0, size.y)       # length along local Y
		mi.mesh = bm
	else:
		var cm := CylinderMesh.new()
		cm.top_radius = radius
		cm.bottom_radius = radius
		cm.height = 1.0
		cm.radial_segments = 8
		cm.rings = 1
		mi.mesh = cm
	mi.material_override = mat if mat else _susp_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_susp[name] = mi
	return mi

## Stretch a unit-length part between two points (local Y = a -> b).
func _span(name: String, a: Vector3, b: Vector3, up := Vector3.UP) -> void:
	var mi: MeshInstance3D = _susp.get(name)
	if mi == null:
		return
	var d := b - a
	var L := d.length()
	if L < 0.001:
		return
	var y := d / L
	var x := up.cross(y)
	if x.length() < 0.01:
		x = Vector3.FORWARD.cross(y)
	x = x.normalized()
	var z := x.cross(y)
	mi.transform = Transform3D(Basis(x, y * L, z), (a + b) * 0.5)

func _build_suspension() -> void:
	_susp.clear()
	_susp_mat = StandardMaterial3D.new()
	_susp_mat.albedo_color = Color(0.07, 0.07, 0.075)
	_susp_mat.roughness = 0.7
	_susp_mat.metallic = 0.3
	for sd in ["L", "R"]:
		_part("lca_" + sd, _BOX, 0.0, Vector2(0.06, 0.20))
		_part("uca_" + sd, _BOX, 0.0, Vector2(0.05, 0.14))
		_part("knuckle_" + sd, _BOX, 0.0, Vector2(0.06, 0.08))
		_part("tierod_" + sd, _CYL, 0.012)
		_part("fshock_" + sd, _CYL, 0.024)
		_part("torsion_" + sd, _CYL, 0.015)
		_part("halfshaft_" + sd, _CYL, 0.03)
		_part("leaf_f_" + sd, _BOX, 0.0, Vector2(0.065, 0.05))
		_part("leaf_r_" + sd, _BOX, 0.0, Vector2(0.065, 0.04))
		_part("rshock_" + sd, _CYL, 0.024)
		_part("rail_" + sd, _BOX, 0.0, Vector2(0.06, 0.14))
	_part("axle", _CYL, 0.045)
	_part("rdiff", _BOX, 0.0, Vector2(0.28, 0.26))
	_part("fdiff", _BOX, 0.0, Vector2(0.26, 0.22))
	_part("rdriveshaft", _CYL, 0.04)
	_part("fdriveshaft", _CYL, 0.03)
	_part("trans", _BOX, 0.0, Vector2(0.32, 0.28))
	# ---- underside, after a photo of a GMT400 Tahoe from below
	var alu := StandardMaterial3D.new()          # 4L60-E pan / transfer case
	alu.albedo_color = Color(0.62, 0.62, 0.6)
	alu.metallic = 0.85
	alu.roughness = 0.4
	var steel := StandardMaterial3D.new()        # exhaust pipe
	steel.albedo_color = Color(0.42, 0.40, 0.38)
	steel.metallic = 0.8
	steel.roughness = 0.5
	var cat := StandardMaterial3D.new()          # heat-coloured converter / muffler shells
	cat.albedo_color = Color(0.58, 0.47, 0.32)
	cat.metallic = 0.7
	cat.roughness = 0.45
	for k in ["xm_front", "xm_torsion", "xm_trans", "xm_rear_a", "xm_rear_b", "xm_rear_end"]:
		_part(k, _BOX, 0.0, Vector2(0.18, 0.09))
	_part("oilpan", _BOX, 0.0, Vector2(0.30, 0.14))
	_part("transpan", _BOX, 0.0, Vector2(0.30, 0.06), alu)
	_part("tcase", _BOX, 0.0, Vector2(0.30, 0.24), alu)
	_part("tank", _BOX, 0.0, Vector2(0.78, 0.24))
	for k in ["ex_l1", "ex_l2", "ex_r1", "ex_r2", "ex_mid", "ex_tail1", "ex_tail2", "ex_tail3"]:
		_part(k, _CYL, 0.028, Vector2.ZERO, steel)
	_part("converter", _CYL, 0.075, Vector2.ZERO, cat)
	_part("muffler", _CYL, 0.11, Vector2.ZERO, cat)

func _update_suspension() -> void:
	if _susp.is_empty() or wheel_nodes.size() < 4:
		return
	var four := car.drivetrain == "4wd"
	for k in ["halfshaft_L", "halfshaft_R", "fdiff", "fdriveshaft"]:
		_susp[k].visible = four
	var fy := 0.47 + body_drop                  # frame rail centre height
	# ---- front independent suspension
	for i in 2:
		var h: Vector3 = wheel_nodes[i].position
		var st: float = wheel_nodes[i].rotation.y
		var s := signf(h.x)
		var sd := "L" if s < 0.0 else "R"
		var rot := Basis(Vector3.UP, st)
		var bl := h + Vector3(-s * 0.13, -0.11, 0.0)            # lower ball joint
		var bu := h + Vector3(-s * 0.16, 0.17, 0.02)            # upper ball joint
		var pl := Vector3(s * 0.40, fy - 0.10, h.z)             # lower arm frame pivot
		var pu := Vector3(s * 0.47, fy + 0.16, h.z + 0.03)      # upper arm frame pivot
		_span("lca_" + sd, pl, bl)
		_span("uca_" + sd, pu, bu)
		var kc := h + Vector3(-s * 0.13, 0.03, 0.0)
		_span("knuckle_" + sd, kc + Vector3(0, -0.15, 0), kc + Vector3(0, 0.15, 0), rot * Vector3.FORWARD)
		_span("tierod_" + sd, Vector3(s * 0.30, fy - 0.12, h.z + 0.20), h + rot * Vector3(-s * 0.13, -0.05, 0.17))
		_span("fshock_" + sd, (pl + bl) * 0.5 + Vector3(0, 0.03, 0.08), Vector3(s * 0.52, fy + 0.34, h.z + 0.08))
		_span("torsion_" + sd, pl, Vector3(s * 0.40, fy - 0.08, h.z + 1.10))
		_span("halfshaft_" + sd, Vector3(s * 0.12, h.y, h.z), h + Vector3(-s * 0.10, 0, 0))
	var fz: float = wheel_nodes[0].position.z
	_span("fdiff", Vector3(0.05, fy - 0.20, fz), Vector3(0.05, fy + 0.02, fz))
	# ---- rear solid axle on leaf springs
	var hl: Vector3 = wheel_nodes[2].position
	var hr: Vector3 = wheel_nodes[3].position
	var a := hl + (hr - hl).normalized() * 0.12
	var b := hr - (hr - hl).normalized() * 0.12
	_span("axle", a, b)
	var mid := (hl + hr) * 0.5
	_span("rdiff", mid + Vector3(0, -0.13, 0.02), mid + Vector3(0, 0.13, 0.02))
	for sd in ["L", "R"]:
		var s := -1.0 if sd == "L" else 1.0
		var t := inverse_lerp(hl.x, hr.x, s * 0.52)
		var seat := hl.lerp(hr, t) + Vector3(0, -0.07, 0)
		_span("leaf_f_" + sd, Vector3(s * 0.52, fy - 0.03, seat.z - 0.72), seat)
		_span("leaf_r_" + sd, seat, Vector3(s * 0.52, fy - 0.02, seat.z + 0.68))
		var ts := inverse_lerp(hl.x, hr.x, s * 0.42)
		_span("rshock_" + sd, hl.lerp(hr, ts) + Vector3(0, -0.05, 0.12), Vector3(s * 0.45, fy + 0.25, seat.z + 0.30))
		_span("rail_" + sd, Vector3(s * 0.44, fy, -2.05), Vector3(s * 0.44, fy, 2.25), Vector3.RIGHT)
	_span("trans", Vector3(0.0, fy + 0.02, -0.75), Vector3(0.0, fy + 0.02, 0.05), Vector3.RIGHT)
	_susp["tcase"].visible = four
	var rz := mid.z
	# crossmembers (front one carries the lower control arms)
	var X := Vector3.FORWARD
	_span("xm_front", Vector3(-0.44, fy - 0.06, fz), Vector3(0.44, fy - 0.06, fz), X)
	_span("xm_torsion", Vector3(-0.44, fy - 0.04, fz + 1.10), Vector3(0.44, fy - 0.04, fz + 1.10), X)
	_span("xm_trans", Vector3(-0.44, fy - 0.05, -0.12), Vector3(0.44, fy - 0.05, -0.12), X)
	_span("xm_rear_a", Vector3(-0.44, fy, rz - 0.80), Vector3(0.44, fy, rz - 0.80), X)
	_span("xm_rear_b", Vector3(-0.44, fy + 0.02, rz + 0.62), Vector3(0.44, fy + 0.02, rz + 0.62), X)
	_span("xm_rear_end", Vector3(-0.44, fy, 2.22), Vector3(0.44, fy, 2.22), X)
	# engine oil pan, silver transmission pan, transfer case, fuel tank
	_span("oilpan", Vector3(0.0, fy - 0.07, fz - 0.15), Vector3(0.0, fy - 0.07, fz + 0.35), Vector3.RIGHT)
	_span("transpan", Vector3(0.0, fy - 0.15, -0.62), Vector3(0.0, fy - 0.15, -0.20), Vector3.RIGHT)
	_span("tcase", Vector3(0.05, fy - 0.07, 0.05), Vector3(0.05, fy - 0.07, 0.38), Vector3.RIGHT)
	_span("tank", Vector3(0.0, fy - 0.02, rz + 0.70), Vector3(0.0, fy - 0.02, rz + 1.08), Vector3.RIGHT)
	# exhaust: dual down-pipes -> Y -> converter -> muffler -> tailpipe out the right rear
	var ey := fy - 0.13
	_span("ex_l1", Vector3(-0.32, fy + 0.12, fz + 0.30), Vector3(-0.22, ey, -0.78))
	_span("ex_l2", Vector3(-0.22, ey, -0.78), Vector3(0.14, ey, -0.32))
	_span("ex_r1", Vector3(0.32, fy + 0.12, fz + 0.30), Vector3(0.24, ey, -0.78))
	_span("ex_r2", Vector3(0.24, ey, -0.78), Vector3(0.18, ey, -0.32))
	_span("converter", Vector3(0.18, ey, -0.30), Vector3(0.22, ey, 0.22))
	_span("ex_mid", Vector3(0.22, ey, 0.22), Vector3(0.32, ey + 0.03, 0.70))
	_span("muffler", Vector3(0.33, ey + 0.04, 0.72), Vector3(0.36, ey + 0.04, 1.18))
	_span("ex_tail1", Vector3(0.36, ey + 0.04, 1.18), Vector3(0.38, fy + 0.10, rz - 0.05))
	_span("ex_tail2", Vector3(0.38, fy + 0.10, rz - 0.05), Vector3(0.40, fy + 0.04, rz + 0.45))
	_span("ex_tail3", Vector3(0.40, fy + 0.04, rz + 0.45), Vector3(0.62, fy - 0.06, rz + 1.02))
	_span("rdriveshaft", Vector3(0.0, fy - 0.03, 0.05), mid + Vector3(0, 0.0, -0.16))
	_span("fdriveshaft", Vector3(0.06, fy - 0.05, -0.30), Vector3(0.05, fy - 0.09, fz + 0.14))
