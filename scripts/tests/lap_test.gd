extends SceneTree
## Autopilot drives laps of the circuit headless; checks the track geometry,
## surfaces, collisions and how tires/engine/brakes evolve over a stint.
##   godot --headless --fixed-fps 120 -s res://scripts/tests/lap_test.gd

var car: Vehicle
var track: Track
var idx := -1
var t := 0.0
var lap_t := 0.0
var laps := 0
var rel_prev := 0
var max_off := 0.0
var surfaces := {}
var target_laps := 3
var stuck_t := 0.0

func _initialize() -> void:
	var def: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/cars/chevrolet_tahoe_1996.json"))
	track = Track.new()
	root.add_child(track)
	var t0 := Time.get_ticks_msec()
	track.build()
	var kmx := 0.0
	var ki := 0
	for i in track.pts.size():
		if absf(track.curvature[i]) > kmx:
			kmx = absf(track.curvature[i]); ki = i
	print("tightest radius %.1f m at idx %d" % [1.0 / kmx, ki])
	print("track built in %d ms, length %.0f m, %d samples" % [Time.get_ticks_msec() - t0, track.length, track.pts.size()])
	car = Vehicle.new()
	car.configure(def, {"body": "4door", "drivetrain": "4wd", "transfer": "2H", "final_drive": 3.42,
		"trans_mode": "auto", "tire_psi_front": 35, "tire_psi_rear": 35, "abs": true, "speed_limiter": true,
		"brake_bias_front": 0.69, "arb_scale_front": 1.0, "arb_scale_rear": 1.0}, {})
	root.add_child(car)
	car.reset_to(track.start_transform(0))

func _process(dt: float) -> bool:
	t += dt
	lap_t += dt
	var m := track.pts.size()
	idx = track.nearest_index(car.global_position, idx)
	# pure-pursuit steering toward a look-ahead point; speed from curvature ahead
	var look := int(clampf(car.speed_ms * 0.9, 6.0, 30.0) / track.sample_step)
	var tp := track.pts[(idx + look) % m]
	var local := car.global_transform.affine_inverse() * tp
	var ang := atan2(local.x, -local.z)
	car.in_steer = clampf(ang * 2.2, -1.0, 1.0)
	var kmax := 0.0
	for k in range(4, 60):
		kmax = maxf(kmax, absf(track.curvature[(idx + k) % m]) * (1.0 - k / 90.0))
	var v_target := clampf(sqrt(0.62 * 9.81 / maxf(kmax, 0.001)), 6.0, 45.0)
	var err := v_target - car.speed_ms
	car.in_throttle = clampf(err * 0.25, 0.0, 1.0)
	car.in_brake = clampf(-err * 0.12, 0.0, 1.0)
	var off := track.pts[idx].distance_to(car.global_position)
	max_off = maxf(max_off, off)
	var s := car.surface_name
	surfaces[s] = surfaces.get(s, 0) + 1
	if car.speed_ms < 1.0 and t > 5.0:
		stuck_t += dt
		if stuck_t > 5.0:
			print("STUCK at idx %d pos %s off %.1f surface %s gear %s rpm %.0f" % [idx, car.global_position, track.pts[idx].distance_to(car.global_position), car.surface_name, car.trans.gear_label(), car.engine.rpm()])
			return true
	else:
		stuck_t = 0.0
	var rel := (idx - track.start_index + m) % m
	if rel_prev > m * 0.9 and rel < m * 0.1 and t > 10.0:
		laps += 1
		var temps := []
		var tread := []
		for w in car.wheels:
			temps.append("%.0f" % w.tire.avg_temp())
			tread.append("%.2f" % w.tire.avg_tread())
		var bt := []
		for w in car.wheels:
			bt.append("%.0f" % w.brake_c)
		print("LAP %d  %s  max off-centre %.1f m | tire C %s | tread mm %s | brakes C %s | coolant %.0f oil %.0f trans %.0f | eng %.4f" % [
			laps, Game_fmt(lap_t), max_off, temps, tread, bt, car.engine.coolant_c, car.engine.oil_c, car.trans.fluid_c, car.engine.health])
		lap_t = 0.0
		max_off = 0.0
		if laps >= target_laps:
			print("surfaces (ticks): ", surfaces)
			return true
	rel_prev = rel
	if t > 900.0:
		print("timeout")
		return true
	return false

func Game_fmt(x: float) -> String:
	var mm := int(x / 60.0)
	return "%d:%06.3f" % [mm, x - mm * 60.0]
