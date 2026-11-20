class_name Vehicle
extends RigidBody3D
## Full vehicle simulation on top of a Godot rigid body.
## Forward is -Z, right is +X, up is +Y. The body origin sits on the ground
## midway between the axles at static ride height.
##
## Each physics tick (120 Hz) the wheels, driveline and engine are sub-stepped
## (SUBSTEPS times) because wheel spin and tire deflection are much stiffer
## than the body motion; the averaged tire and suspension forces are then
## applied to the rigid body once.

const SUBSTEPS := 6
const AIR_DENSITY := 1.225

signal engine_damaged(health: float)

class Wheel:
	var name := ""
	var front := true
	var left := true
	var side_sign := -1.0        # -1 left, +1 right (outer direction along X)
	var anchor := Vector3.ZERO   # local, wheel centre at full bump
	var travel := 0.2
	var k := 40000.0             # spring rate N/m (at wheel)
	var spring_preload := 0.0           # m of spring compression at full droop
	var c_bump := 3000.0
	var c_rebound := 4500.0
	var radius := 0.367
	var inertia := 1.9
	var driven := false
	var roll_center_h := 0.1
	var camber_static := 0.0
	var camber_gain := 0.0       # deg per m of compression (IFS); 0 for solid axle
	var solid_axle := false
	var tire := Tire.new()
	# state
	var compression := 0.0
	var comp_vel := 0.0
	var contact := false
	var hit_point := Vector3.ZERO
	var hit_normal := Vector3.UP
	var surface: Dictionary = {}
	var omega := 0.0
	var spin_angle := 0.0
	var steer := 0.0             # radians
	var load := 0.0
	var drive_torque := 0.0
	var brake_torque := 0.0
	var abs_factor := 1.0
	var brake_c := 30.0
	var brake_fade_start := 400.0
	var camber_ground := 0.0
	var vx := 0.0
	var vy := 0.0
	var fx_acc := 0.0
	var fy_acc := 0.0
	var visual: Node3D

# ---------- configuration ----------
var def: Dictionary
var cfg: Dictionary
var body_def: Dictionary
var wheels: Array[Wheel] = []
var engine := CarEngine.new()
var trans := Transmission.new()
var wheelbase := 2.985
var drivetrain := "4wd"
var transfer := "2H"
var rear_locker := false
var abs_enabled := true
var tcs_enabled := false
var limiter_ms := 43.8
var limiter_on := true
var brake_bias := 0.69
var brake_front_max := 4200.0
var brake_rear_max := 1900.0
var arb_front := 28000.0
var arb_rear := 0.0
var max_steer := deg_to_rad(33.0)
var ackermann := 0.6
var cda := 1.56

# ---------- driver inputs (set by PlayerController / AI / tests) ----------
var in_throttle := 0.0
var in_brake := 0.0
var in_steer := 0.0
var in_handbrake := 0.0
var steer_actual := 0.0

# ---------- telemetry ----------
var speed_ms := 0.0
var g_lat := 0.0
var g_long := 0.0
var odometer_m := 0.0
var surface_name := "asphalt"
var _prev_vel := Vector3.ZERO
var _rear_locked := false
var _tcs_cut := 0.0
var ray_exclude: Array[RID] = []

func configure(car_def: Dictionary, setup: Dictionary, condition: Dictionary) -> void:
	def = car_def
	cfg = setup
	body_def = def["bodies"][setup.get("body", "4door")]
	drivetrain = setup.get("drivetrain", "4wd")
	transfer = setup.get("transfer", "2H") if drivetrain == "4wd" else "2H"
	rear_locker = setup.get("rear_diff", "open") == "g80_locker"
	abs_enabled = setup.get("abs", true)
	tcs_enabled = setup.get("tcs", false)
	limiter_on = setup.get("speed_limiter", true)
	limiter_ms = def["limits"]["speed_limiter_mph"] / 2.23694
	brake_bias = setup.get("brake_bias_front", 0.69)
	var bp: float = setup.get("brake_power", 1.0)
	brake_front_max = def["brakes"]["max_torque_front_nm"] * bp
	brake_rear_max = def["brakes"]["max_torque_rear_nm"] * bp
	max_steer = deg_to_rad(def["steering"]["max_wheel_angle_deg"])
	ackermann = def["steering"]["ackermann"]
	cda = body_def["drag_coefficient"] * body_def["frontal_area_m2"]

	# --- mass properties ---
	var m: float = body_def["mass_4wd_kg"] if drivetrain == "4wd" else body_def["mass_2wd_kg"]
	mass = m
	wheelbase = body_def["wheelbase_m"]
	var f: float = body_def["front_weight_fraction"]
	if drivetrain == "2wd":
		f -= 0.012     # no front axle / transfer case
	var cg_h: float = body_def["cg_height_m"] + setup.get("ride_height_offset_mm", 0.0) / 1000.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, cg_h, wheelbase * (0.5 - f))
	var L: float = body_def["length_m"]
	var W: float = body_def["width_m"]
	var H: float = body_def["height_m"]
	var s: Array = body_def["inertia_scale"]
	inertia = Vector3(
		m * (L * L + H * H) / 12.0 * 0.85 * s[0],   # pitch (about X)
		m * (L * L + W * W) / 12.0 * 0.85 * s[1],   # yaw   (about Y)
		m * (W * W + H * H) / 12.0 * 0.85 * s[2])   # roll  (about Z)
	can_sleep = false
	continuous_cd = true
	linear_damp = 0.0
	angular_damp = 0.02
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE

	# --- driveline ---
	engine.setup(def["engine"], condition.get("engine_health", 1.0))
	trans.setup(def["transmission"], setup.get("final_drive", 3.42), setup.get("trans_mode", "auto") == "manual")
	trans.range_ratio = def["drivetrain"]["low_range_ratio"] if transfer == "4L" else 1.0

	# --- wheels / suspension ---
	_build_wheels(m, f, setup, condition)
	_build_collision()

func _build_wheels(m: float, f: float, setup: Dictionary, condition: Dictionary) -> void:
	wheels.clear()
	var sus: Dictionary = def["suspension"]
	var tdef: Dictionary = def["tires"]
	var g := 9.81
	var treads: Array = condition.get("tire_tread_mm", [-1, -1, -1, -1])
	var names := ["FL", "FR", "RL", "RR"]
	for i in 4:
		var w := Wheel.new()
		w.name = names[i]
		w.front = i < 2
		w.left = i % 2 == 0
		w.side_sign = -1.0 if w.left else 1.0
		var track: float = body_def["track_front_m"] if w.front else body_def["track_rear_m"]
		var z: float = -wheelbase * 0.5 if w.front else wheelbase * 0.5
		w.radius = tdef["radius_m"]
		w.inertia = tdef["wheel_inertia_kgm2"]
		w.travel = sus["front_travel_m"] if w.front else sus["rear_travel_m"]
		var corner_load: float = m * g * (f if w.front else 1.0 - f) * 0.5
		var corner_mass := corner_load / g
		var hz: float = sus["front_ride_hz"] if w.front else sus["rear_ride_hz"]
		var scale: float = setup.get("spring_scale_front" if w.front else "spring_scale_rear", 1.0)
		w.k = corner_mass * pow(TAU * hz, 2.0) * scale
		var damp: float = setup.get("damper_scale", 1.0)
		var crit := 2.0 * sqrt(w.k * corner_mass)
		w.c_bump = crit * sus["damping_ratio_bump"] * damp
		w.c_rebound = crit * sus["damping_ratio_rebound"] * damp
		# static compression ~55% of travel: spring_preload makes up the rest
		var c_static := w.travel * 0.55
		w.spring_preload = corner_load / w.k - c_static
		var ride_off: float = setup.get("ride_height_offset_mm", 0.0) / 1000.0
		w.anchor = Vector3(track * 0.5 * w.side_sign, w.radius + w.travel - c_static + ride_off, z)
		w.compression = c_static
		w.driven = (not w.front) or (drivetrain == "4wd" and transfer != "2H")
		w.solid_axle = not w.front
		w.roll_center_h = 0.06 if w.front else 0.28
		w.camber_static = setup.get("camber_front_deg" if w.front else "camber_rear_deg", 0.0)
		w.camber_gain = -15.0 if w.front else 0.0
		w.brake_fade_start = def["brakes"]["front_fade_start_c"] if w.front else def["brakes"]["rear_fade_start_c"]
		var psi: float = setup.get("tire_psi_front" if w.front else "tire_psi_rear", 35.0)
		w.tire.setup(tdef, psi, treads[i] if i < treads.size() else -1.0)
		wheels.append(w)
	arb_front = def["suspension"]["front_arb_nm_per_m"] * setup.get("arb_scale_front", 1.0)
	arb_rear = def["suspension"]["rear_arb_nm_per_m"] * setup.get("arb_scale_rear", 1.0)
	if arb_rear == 0.0 and setup.get("arb_scale_rear", 1.0) > 1.0:
		arb_rear = 6000.0 * (setup.get("arb_scale_rear", 1.0) - 1.0) * 4.0  # aftermarket rear bar

func _build_collision() -> void:
	for c in get_children():
		if c is CollisionShape3D:
			c.queue_free()
	var L: float = body_def["length_m"]
	var W: float = body_def["width_m"]
	var H: float = body_def["height_m"]
	var shape := BoxShape3D.new()
	var clearance := 0.38
	shape.size = Vector3(W * 0.98, H - clearance - 0.05, L * 0.98)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = Vector3(0, clearance + (H - clearance) * 0.5, 0.0)
	add_child(cs)
	var pm := PhysicsMaterial.new()
	pm.friction = 0.35
	pm.bounce = 0.05
	physics_material_override = pm

func _ready() -> void:
	ray_exclude = [get_rid()]

# =====================================================================
func _physics_process(dt: float) -> void:
	if wheels.is_empty():
		return
	var xf := global_transform
	var basis_n := xf.basis.orthonormalized()
	var up := basis_n.y
	var fwd := -basis_n.z
	var com := xf * center_of_mass
	var space := get_world_3d().direct_space_state
	speed_ms = linear_velocity.dot(fwd)

	_update_steering(dt)

	# ---------- suspension: ray casts ----------
	for w in wheels:
		var a := xf * w.anchor
		var ray_len := w.travel + w.radius + 0.25
		var q := PhysicsRayQueryParameters3D.create(a + up * 0.25, a - up * ray_len)
		q.exclude = ray_exclude
		var hit := space.intersect_ray(q)
		var prev := w.compression
		if hit.is_empty():
			w.contact = false
			w.compression = maxf(0.0, w.compression - w.travel * dt * 8.0)
			w.comp_vel = (w.compression - prev) / dt
			continue
		var dist: float = (hit["position"] - a).dot(-up)    # anchor → ground along -up
		var c := w.radius + w.travel - dist
		w.contact = c > 0.0
		w.compression = clampf(c, 0.0, w.travel + 0.06)
		w.comp_vel = (w.compression - prev) / dt
		w.hit_point = hit["position"]
		w.hit_normal = hit["normal"]
		var col = hit["collider"]
		w.surface = col.get_meta("surface", Track.SURF_ASPHALT) if col else Track.SURF_ASPHALT

	# ---------- spring / damper / anti-roll / bump-stop ----------
	var arb_f := (wheels[0].compression - wheels[1].compression) * arb_front
	var arb_r := (wheels[2].compression - wheels[3].compression) * arb_rear
	for i in 4:
		var w := wheels[i]
		if not w.contact:
			w.load = 0.0
			continue
		var cmp := minf(w.compression, w.travel)
		var fs := w.k * (cmp + w.spring_preload)
		var fd := w.comp_vel * (w.c_bump if w.comp_vel > 0.0 else w.c_rebound)
		fd = clampf(fd, -12000.0, 18000.0)
		var fb := 0.0
		var bs_start := w.travel * 0.88
		if w.compression > bs_start:
			var e := w.compression - bs_start
			fb = 4.0e6 * e * e + 60000.0 * e
		var farb := 0.0
		if i < 2:
			farb = arb_f if i == 0 else -arb_f
		else:
			farb = arb_r if i == 2 else -arb_r
		w.load = maxf(0.0, fs + fd + fb + farb)
		# suspension force along body up at the wheel's position
		var wp := xf * Vector3(w.anchor.x, w.anchor.y - w.travel + w.compression, w.anchor.z)
		apply_force(up * w.load, wp - global_position)

	# ---------- wheel kinematics in contact frame ----------
	var roll_ld_f := atan((wheels[0].compression - wheels[1].compression) / maxf(body_def["track_front_m"], 0.1))
	var roll_ld_r := atan((wheels[2].compression - wheels[3].compression) / maxf(body_def["track_rear_m"], 0.1))
	var frames := []
	for i in 4:
		var w := wheels[i]
		var n := w.hit_normal if w.contact else up
		var wfwd := fwd.rotated(up, w.steer)
		wfwd = (wfwd - n * wfwd.dot(n)).normalized()
		var wright := wfwd.cross(n).normalized()
		var p := w.hit_point if w.contact else xf * w.anchor
		var v := linear_velocity + angular_velocity.cross(p - com)
		w.vx = v.dot(wfwd)
		w.vy = v.dot(wright)
		# camber relative to the ground
		var roll := rad_to_deg(roll_ld_f if w.front else roll_ld_r)
		if w.solid_axle:
			w.camber_ground = w.camber_static
		else:
			var cam_body := w.camber_static + w.camber_gain * (w.compression - w.travel * 0.55)
			w.camber_ground = cam_body + (roll if w.left else -roll)
		w.fx_acc = 0.0
		w.fy_acc = 0.0
		frames.append([wfwd, wright, n])

	# ---------- sub-stepped driveline + tires ----------
	var sdt := dt / SUBSTEPS
	var throttle := _driver_throttle(dt)
	var trans_slip_power := 0.0
	for step in SUBSTEPS:
		trans_slip_power += _driveline_substep(throttle, sdt) / SUBSTEPS
		for w in wheels:
			_wheel_substep(w, sdt)
	trans.update_thermal(trans_slip_power, absf(speed_ms), dt)

	# ---------- apply averaged tire forces ----------
	for i in 4:
		var w := wheels[i]
		if not w.contact:
			continue
		var fr: Array = frames[i]
		var fxv: float = w.fx_acc / SUBSTEPS
		var fyv: float = w.fy_acc / SUBSTEPS
		var f_long: Vector3 = fr[0] * fxv
		var f_lat: Vector3 = fr[1] * fyv
		# lateral force acts at roll-centre height (suspension geometry jacking)
		var p_lat: Vector3 = w.hit_point + up * w.roll_center_h
		var p_long: Vector3 = w.hit_point + up * 0.05
		apply_force(f_long, p_long - global_position)
		apply_force(f_lat, p_lat - global_position)
		w.tire.fx = fxv
		w.tire.fy = fyv

	# ---------- aerodynamic drag ----------
	var v2 := linear_velocity.length_squared()
	if v2 > 0.01:
		var drag := -linear_velocity.normalized() * 0.5 * AIR_DENSITY * cda * v2
		apply_force(drag, com + up * 0.2 - global_position)

	# ---------- automatic transmission / housekeeping ----------
	var wheel_rpm_equiv := _driven_wheel_omega() * 60.0 / TAU
	trans.update_auto(absf(speed_ms), throttle, engine.rpm(), engine.redline, dt)
	trans.update_lockup(absf(speed_ms), throttle, dt)
	engine.set_airflow(absf(speed_ms))
	odometer_m += absf(speed_ms) * dt
	var acc := (linear_velocity - _prev_vel) / dt
	_prev_vel = linear_velocity
	g_lat = lerpf(g_lat, acc.dot(basis_n.x) / 9.81, 0.15)
	g_long = lerpf(g_long, acc.dot(fwd) / 9.81, 0.15)
	surface_name = wheels[0].surface.get("name", "asphalt") if wheels[0].contact else "air"
	_update_visuals(dt)

# ---------------------------------------------------------------------
func _update_steering(dt: float) -> void:
	# steering rack has a finite speed (about 1.7 turns lock-to-lock in ~0.8s)
	var target := in_steer
	steer_actual = move_toward(steer_actual, target, dt * 3.2)
	var a := steer_actual * max_steer
	# Ackermann: inside wheel turns more
	var inner := a
	var outer := a
	if absf(a) > 0.0001:
		var r := wheelbase / tan(absf(a))
		var t: float = body_def["track_front_m"]
		var ai := atan(wheelbase / (r - t * 0.5))
		var ao := atan(wheelbase / (r + t * 0.5))
		inner = signf(a) * lerpf(absf(a), ai, ackermann)
		outer = signf(a) * lerpf(absf(a), ao, ackermann)
	# positive steer = turn right → right wheel is inner
	# (Godot rotation about +Y is counter-clockwise from above, so negate)
	if a > 0.0:
		wheels[0].steer = -outer
		wheels[1].steer = -inner
	else:
		wheels[0].steer = -inner
		wheels[1].steer = -outer

func _driver_throttle(dt: float) -> float:
	var thr := in_throttle
	if limiter_on and speed_ms > limiter_ms:
		thr = 0.0
	if engine.stalled:
		return 0.0
	# traction control (optional assist; not fitted to the real '96 Tahoe)
	if tcs_enabled:
		var worst := 0.0
		for w in wheels:
			if w.driven and w.contact:
				worst = maxf(worst, w.tire.slip_ratio)
		if worst > 0.14:
			_tcs_cut = minf(1.0, _tcs_cut + dt * 6.0)
		else:
			_tcs_cut = maxf(0.0, _tcs_cut - dt * 3.0)
		thr *= 1.0 - _tcs_cut
	return thr

func _driven_wheels() -> Array[Wheel]:
	var out: Array[Wheel] = []
	for w in wheels:
		if w.driven:
			out.append(w)
	return out

func _driven_wheel_omega() -> float:
	var s := 0.0
	var n := 0
	for w in wheels:
		if w.driven:
			s += w.omega
			n += 1
	return s / maxi(n, 1)

## One driveline sub-step: engine ↔ converter/lock-up ↔ gearbox ↔ diffs.
## Returns heat dissipated in the converter (W).
func _driveline_substep(throttle: float, dt: float) -> float:
	var ratio := trans.total_ratio()
	var driven := _driven_wheels()
	var wheel_w := _driven_wheel_omega()
	var turbine_w := wheel_w * ratio
	var out_torque := 0.0
	var engine_load := 0.0
	var heat := 0.0
	if trans.gear == 0 or ratio == 0.0:
		engine_load = 0.0
		out_torque = 0.0
	else:
		var tc := trans.converter(engine.omega, turbine_w, engine.curve_torque(trans.stall_rpm))
		engine_load = tc[0]
		out_torque = tc[1]
		heat = absf(tc[0] * engine.omega - tc[1] * turbine_w)
		# lock-up clutch: implicit sync torque limited by clutch capacity
		if trans.lock_amount > 0.0:
			var i_t := 0.0
			for w in driven:
				i_t += w.inertia
			i_t = maxf(i_t / (ratio * ratio), 0.02)
			var sync := (engine.omega - turbine_w) / (dt * (1.0 / engine.inertia + 1.0 / i_t))
			var cap := 900.0 * trans.lock_amount
			var t_cl := clampf(sync, -cap, cap)
			engine_load += t_cl
			out_torque += t_cl
	if trans.shifting > 0.0:
		out_torque *= 0.4      # torque handed between clutches mid-shift
	engine.integrate(throttle, engine_load, dt)

	# torque at the wheels (drivetrain efficiency ~88%)
	var axle_torque := out_torque * ratio * 0.88
	for w in wheels:
		w.drive_torque = 0.0
	if driven.is_empty():
		return heat
	if drivetrain == "4wd" and transfer != "2H":
		# part-time transfer case: front and rear shafts locked together
		var front_t := axle_torque * 0.5
		var rear_t := axle_torque * 0.5
		var wf := (wheels[0].omega + wheels[1].omega) * 0.5
		var wr := (wheels[2].omega + wheels[3].omega) * 0.5
		var i_ax := wheels[0].inertia * 2.0
		var sync := (wf - wr) / (dt * (2.0 / i_ax)) * 0.9
		sync = clampf(sync, -3000.0, 3000.0)
		front_t -= sync
		rear_t += sync
		_split_axle(0, 1, front_t, false, dt)
		_split_axle(2, 3, rear_t, rear_locker, dt)
	else:
		_split_axle(2, 3, axle_torque, rear_locker, dt)
	return heat

## Open differential splits torque equally; the G80 locker clamps the two
## sides together once their speed difference exceeds ~100 rpm at low speed.
func _split_axle(a: int, b: int, torque: float, locker: bool, dt: float) -> void:
	var wa := wheels[a]
	var wb := wheels[b]
	wa.drive_torque = torque * 0.5
	wb.drive_torque = torque * 0.5
	if locker:
		var d := wa.omega - wb.omega
		if not _rear_locked and absf(d) > 10.5 and absf(speed_ms) < 9.0:
			_rear_locked = true
		elif _rear_locked and (absf(speed_ms) > 11.0 or absf(torque) < 50.0):
			_rear_locked = false
		if _rear_locked:
			var sync := d / (dt * (2.0 / wa.inertia)) * 0.9
			sync = clampf(sync, -2500.0, 2500.0)
			wa.drive_torque -= sync
			wb.drive_torque += sync

func _wheel_substep(w: Wheel, dt: float) -> void:
	# --- brakes (with heat fade and ABS) ---
	var brake_in := in_brake
	var bt := 0.0
	if w.front:
		bt = brake_in * brake_front_max * (brake_bias / 0.69)
	else:
		bt = brake_in * brake_rear_max * ((1.0 - brake_bias) / 0.31)
		bt = maxf(bt, in_handbrake * 2600.0)
	var fade := 1.0 - clampf((w.brake_c - w.brake_fade_start) / 250.0, 0.0, 0.55)
	bt *= fade
	if abs_enabled and in_handbrake < 0.1 and absf(w.vx) > 2.0:
		# slip-targeting ABS: modulate line pressure to hold ~11% slip
		var err := w.tire.slip_ratio + 0.11
		w.abs_factor = clampf(w.abs_factor + err * dt * 55.0, 0.2, 1.0)
		bt *= w.abs_factor
	else:
		w.abs_factor = 1.0
	w.brake_torque = bt

	# --- tire forces ---
	var surface := w.surface if not w.surface.is_empty() else Track.SURF_ASPHALT
	if w.contact:
		w.tire.update(w.load, w.vx, w.vy, w.omega, w.camber_ground, surface, w.side_sign, dt)
		w.fx_acc += w.tire.fx
		w.fy_acc += w.tire.fy
	else:
		w.tire.update(0.0, w.vx, w.vy, w.omega, w.camber_ground, surface, w.side_sign, dt)
	var fx := w.tire.fx if w.contact else 0.0

	# rolling resistance (tire hysteresis + soft surfaces)
	var crr: float = w.tire.crr() + surface.get("crr", 0.0)
	var t_roll := crr * w.load * w.radius * signf(w.omega)

	# --- wheel spin integration ---
	var t_net := w.drive_torque - fx * w.radius - t_roll
	w.omega += t_net / w.inertia * dt
	var dw := bt / w.inertia * dt
	if absf(w.omega) <= dw:
		w.omega = 0.0
	else:
		w.omega -= signf(w.omega) * dw

	# brake temperature (front vented disc ≈ 11 kg, rear drum ≈ 9 kg of iron)
	var mass_c := 11.0 * 460.0 if w.front else 9.0 * 460.0
	var cool := (3.0 + (1.6 if w.front else 0.8) * absf(w.vx)) * (w.brake_c - 25.0)
	w.brake_c += (bt * absf(w.omega) - cool) / mass_c * dt

func _update_visuals(dt: float) -> void:
	for w in wheels:
		w.spin_angle = wrapf(w.spin_angle + w.omega * dt, -TAU, TAU)
		if w.visual:
			var y := w.anchor.y - w.travel + minf(w.compression, w.travel + 0.04)
			w.visual.position = Vector3(w.anchor.x, y, w.anchor.z)
			w.visual.rotation = Vector3(-w.spin_angle, w.steer, 0.0)

# ---------- helpers for UI / editor ----------
func set_transfer(mode: String) -> void:
	if drivetrain != "4wd":
		return
	transfer = mode
	trans.range_ratio = def["drivetrain"]["low_range_ratio"] if mode == "4L" else 1.0
	for w in wheels:
		w.driven = (not w.front) or mode != "2H"

func shift_up() -> void:
	if trans.gear < 0:
		trans.request_shift(0 if absf(speed_ms) > 1.0 else 1)
	elif trans.gear == 0:
		trans.request_shift(1)
	elif trans.manual:
		trans.manual_shift(1, _driven_wheel_omega() * 60.0 / TAU, engine.limiter)

func shift_down() -> void:
	if trans.gear == 1 or trans.gear == 0:
		if absf(speed_ms) < 1.5:
			trans.request_shift(-1)
	elif trans.manual:
		trans.manual_shift(-1, _driven_wheel_omega() * 60.0 / TAU, engine.limiter)

func reset_to(xform: Transform3D) -> void:
	global_transform = xform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_prev_vel = Vector3.ZERO
	for w in wheels:
		w.omega = 0.0
		w.tire.defl_x = 0.0
		w.tire.defl_y = 0.0
	if trans.gear <= 0:
		trans.gear = 1
		trans.target_gear = 1
	if engine.stalled and engine.health > 0.02:
		engine.restart()

func condition_snapshot() -> Dictionary:
	var treads := []
	for w in wheels:
		treads.append(w.tire.avg_tread())
	return {"engine_health": engine.health, "tire_tread_mm": treads}
