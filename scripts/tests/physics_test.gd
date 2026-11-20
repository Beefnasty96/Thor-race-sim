extends SceneTree
## Headless physics validation. Run:
##   godot --headless --fixed-fps 120 -s res://scripts/tests/physics_test.gd
## Compares the simulated Tahoe against real-world figures.

var car: Vehicle
var t := 0.0
var phase := 0
var phase_t := 0.0
var results := {}
var def: Dictionary
var drive := "4wd"
var configs := ["2wd", "4wd"]
var cfg_i := 0
var dist_m := 0.0
var start_pos := Vector3.ZERO
var max_lat := 0.0
var lat_samples := []

func _initialize() -> void:
	def = JSON.parse_string(FileAccess.get_file_as_string("res://data/cars/chevrolet_tahoe_1996.json"))
	var ground := StaticBody3D.new()
	ground.set_meta("surface", Track.SURF_ASPHALT)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6000, 1, 6000)
	cs.shape = box
	cs.position = Vector3(0, -0.5, 0)
	ground.add_child(cs)
	root.add_child(ground)
	_spawn()

func _spawn() -> void:
	if car:
		car.queue_free()
	drive = configs[cfg_i]
	car = Vehicle.new()
	var setup := {
		"body": "4door", "drivetrain": drive, "transfer": "2H", "final_drive": 3.42,
		"trans_mode": "auto", "tire_psi_front": 35, "tire_psi_rear": 35, "abs": true,
		"speed_limiter": true, "brake_bias_front": 0.69,
	}
	car.configure(def, setup, {"engine_health": 1.0})
	root.add_child(car)
	car.global_position = Vector3(0, 0.15, 0)
	phase = 0
	phase_t = 0.0
	print("\n=== 1996 Tahoe 4-door ", drive.to_upper(), "  mass ", car.mass, " kg ===")

func _set_phase(p: int) -> void:
	phase = p
	phase_t = 0.0

func _process(delta: float) -> bool:
	t += delta
	phase_t += delta
	if car == null or car.wheels.is_empty():
		return false
	var mph: float = car.speed_ms * 2.23694
	match phase:
		0:  # settle
			car.in_brake = 1.0
			if phase_t > 2.5:
				var c := []
				for w in car.wheels:
					c.append("%.0f%%" % (w.compression / w.travel * 100.0))
				var loads := []
				for w in car.wheels:
					loads.append("%.0f" % w.load)
				print("settled: compression ", c, " loads N ", loads, " body y %.3f" % car.global_position.y)
				print("idle rpm %.0f  coolant %.1fC" % [car.engine.rpm(), car.engine.coolant_c])
				start_pos = car.global_position
				_set_phase(1)
		1:  # 0-60 + quarter mile
			car.in_brake = 0.0
			car.in_throttle = 1.0
			var d: float = car.global_position.distance_to(start_pos)
			if mph >= 30.0 and not results.has("030" + drive):
				results["030" + drive] = phase_t
			if mph >= 60.0 and not results.has("060" + drive):
				results["060" + drive] = phase_t
				print("0-60 mph: %.2f s   (real-world tests: ~8.5-10 s)" % phase_t)
			if d >= 402.3 and not results.has("qm" + drive):
				results["qm" + drive] = phase_t
				print("1/4 mile: %.2f s @ %.1f mph  (real: ~16.5-17 s)" % [phase_t, mph])
			if int(phase_t * 2) != int((phase_t - delta) * 2) and phase_t < 12:
				print("  t=%.1f mph=%.1f rpm=%.0f gear=%s lock=%.2f slipRL=%.3f" % [phase_t, mph, car.engine.rpm(), car.trans.gear_label(), car.trans.lock_amount, car.wheels[2].tire.slip_ratio])
			if phase_t > 45.0:
				print("speed after 45s WOT: %.1f mph (governor 98 mph)  rpm %.0f gear %s" % [mph, car.engine.rpm(), car.trans.gear_label()])
				print("coolant %.1fC oil %.1fC trans %.1fC" % [car.engine.coolant_c, car.engine.oil_c, car.trans.fluid_c])
				_set_phase(2)
		2:  # slow to 60 then brake test
			car.in_throttle = 0.0
			car.in_brake = 0.3 if mph > 61.0 else 0.0
			if mph <= 61.0:
				start_pos = car.global_position
				_set_phase(3)
		3:
			car.in_brake = 1.0
			if int(phase_t * 4) != int((phase_t - delta) * 4):
				var info := ""
				for w in car.wheels:
					info += " %s k=%.2f abs=%.2f Fz=%.0f Fx=%.0f |" % [w.name, w.tire.slip_ratio, w.abs_factor, w.load, w.tire.fx]
				print("  brk t=%.2f mph=%.1f glong=%.2f %s" % [phase_t, mph, car.g_long, info])
			if absf(car.speed_ms) < 0.2:
				var d: float = car.global_position.distance_to(start_pos)
				print("60-0 braking: %.1f ft  (real: ~140-150 ft)" % (d * 3.28084))
				var bt := []
				for w in car.wheels:
					bt.append("%.0f" % w.brake_c)
				print("brake temps C ", bt)
				_set_phase(4)
		4:  # accelerate to 40 mph for skidpad
			car.in_brake = 0.0
			car.in_throttle = clampf((40.0 - mph) * 0.1, 0.0, 1.0)
			car.in_steer = 0.0
			if phase_t > 8.0:
				max_lat = 0.0
				lat_samples.clear()
				_set_phase(5)
		5:  # steady-state cornering: ramp steering, hold speed
			car.in_steer = minf(phase_t * 0.05, 0.6)
			car.in_throttle = clampf((40.0 - mph) * 0.15 + 0.15, 0.0, 1.0)
			var lat := absf(car.g_lat)
			if phase_t > 3.0:
				max_lat = maxf(max_lat, lat)
			if phase_t > 14.0:
				var temps := []
				var roll := rad_to_deg(car.global_transform.basis.get_euler().z)
				for w in car.wheels:
					temps.append("%s %.0f/%.0f/%.0f" % [w.name, w.tire.t_zone[0], w.tire.t_zone[1], w.tire.t_zone[2]])
				print("max lateral g at ~40 mph: %.3f  (real skidpad: ~0.70-0.72 g)" % max_lat)
				print("body roll %.1f deg  speed %.1f mph" % [roll, mph])
				print("tire temps in/mid/out C: ", temps)
				var psi := []
				for w in car.wheels:
					psi.append("%.1f" % w.tire.psi)
				print("hot pressures psi: ", psi)
				var tread := []
				for w in car.wheels:
					tread.append("%.3f" % w.tire.avg_tread())
				print("tread mm: ", tread, "  engine health %.5f" % car.engine.health)
				_set_phase(6)
		6:
			cfg_i += 1
			if cfg_i >= configs.size():
				print("\nDONE")
				return true
			_spawn()
	return false
