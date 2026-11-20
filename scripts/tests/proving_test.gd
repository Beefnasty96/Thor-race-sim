extends SceneTree
## Drives the Tahoe through every proving-ground area headless.
##   godot --headless --fixed-fps 120 -s res://scripts/tests/proving_test.gd

var map: MapBuilder
var car: Vehicle
var rig := TestRig.new()
var def: Dictionary
var phase := ""
var t := 0.0
var log_t := 0.0
var data := {}
var queue := ["drag", "skidpad", "hill_2h", "hill_4l", "whoops", "done"]
var only := OS.get_cmdline_user_args()

func _initialize() -> void:
	def = JSON.parse_string(FileAccess.get_file_as_string("res://data/cars/chevrolet_tahoe_1996.json"))
	map = MapBuilder.new()
	root.add_child(map)
	var t0 := Time.get_ticks_msec()
	map.build_from_file("res://data/maps/proving_ground.json")
	print("proving ground built in %d ms, %d roads" % [Time.get_ticks_msec() - t0, map.road_lines.size()])
	rig.result.connect(func(s): print("   [test] ", s))
	if not only.is_empty():
		queue = Array(only) + ["done"]
	_next()

func _spawn(xf: Transform3D, transfer := "2H") -> void:
	if car:
		car.queue_free()
	car = Vehicle.new()
	car.configure(def, {"body": "4door", "drivetrain": "4wd", "transfer": transfer, "final_drive": 3.42,
		"trans_mode": "auto", "tire_psi_front": 35, "tire_psi_rear": 35, "abs": true, "speed_limiter": true,
		"brake_bias_front": 0.69}, {})
	root.add_child(car)
	car.reset_to(xf)
	rig.setup(car, map.data.get("zones", {}))

func _road(name: String) -> PackedVector3Array:
	for i in map.data["roads"].size():
		if map.data["roads"][i]["name"] == name:
			return map.road_lines[i]
	return PackedVector3Array()

func _xf_on(line: PackedVector3Array, i: int) -> Transform3D:
	var fwd := (line[mini(i + 3, line.size() - 1)] - line[i])
	fwd.y = 0
	return Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP), line[i] + Vector3.UP * 0.3)

func _next() -> void:
	phase = queue.pop_front()
	t = 0.0
	data = {}
	print("\n== ", phase)
	match phase:
		"drag":
			var z: Dictionary = map.zone("drag_start")
			_spawn(Transform3D(Basis.looking_at(Vector3(0, 0, -1), Vector3.UP), Vector3(z["pos"][0], 0.3, z["pos"][2])))
		"skidpad":
			var sp: Dictionary = map.zone("skidpad")
			var c := Vector3(sp["center"][0], 0.3, sp["center"][2])
			# start on the circle heading tangentially (counter-clockwise from above = left turns)
			_spawn(Transform3D(Basis.looking_at(Vector3(0, 0, -1), Vector3.UP), c + Vector3(sp["radius"], 0, 0)))
			data["c"] = c
			data["r"] = float(sp["radius"])
		"hill_2h", "hill_4l":
			var line := _road("grade_hill")
			_spawn(_xf_on(line, 20), "4L" if phase == "hill_4l" else "2H")
			data["line"] = line
			data["max_y"] = 0.0
		"whoops":
			var line := _road("offroad_loop")
			var idx := int(250.0 / 0.25)   # a little before the whoops (wavelength/4 sampling)
			_spawn(_xf_on(line, mini(idx, line.size() - 10)))
			data["line"] = line
			data["idx"] = idx
			data["max_comp"] = 0.0
			data["min_up"] = 1.0
		"done":
			print("\nALL DONE")

func _process(dt: float) -> bool:
	if phase == "done":
		return true
	t += dt
	rig.update(dt)
	var mph := car.speed_ms * 2.23694
	match phase:
		"drag":
			if t < 2.0:
				car.in_brake = 1.0
				car.in_throttle = 0.0
			elif not data.has("braking"):
				car.in_brake = 0.0
				car.in_throttle = 1.0
				if rig.last["1/4"] > 0.0 and mph > 62.0:
					data["braking"] = true
			else:
				car.in_throttle = 0.0
				car.in_brake = 1.0 if mph < 60.5 or data.has("hard") else 0.25
				if mph < 60.5:
					data["hard"] = true
				if absf(car.speed_ms) < 0.1 and data.has("hard"):
					print("   z at stop %.0f (strip ends at -620)" % car.global_position.z)
					_next()
			if t > 60:
				print("   timeout"); _next()
		"skidpad":
			var c: Vector3 = data["c"]
			var rel := car.global_position - c
			rel.y = 0
			var r := rel.length()
			# pure pursuit on a point further round the circle (counter-clockwise)
			var th := atan2(rel.z, rel.x) - 0.45
			var tp := c + Vector3(cos(th), 0, sin(th)) * float(data["r"])
			var lp := car.global_transform.affine_inverse() * tp
			car.in_steer = clampf(atan2(lp.x, -lp.z) * 2.2, -1.0, 1.0)
			var target := 12.0 + t * 0.25
			car.in_throttle = clampf((target - car.speed_ms) * 0.3, 0.0, 1.0)
			car.in_brake = 0.0
			log_t += dt
			if log_t > 4.0:
				log_t = 0.0
				print("   t=%.0f v=%.1f mph r=%.1f m  live %.2f g  best %.2f g" % [t, mph, r, rig.skidpad_live, rig.best["skidpad"]])
			if t > 40:
				_next()
		"hill_2h", "hill_4l":
			var line: PackedVector3Array = data["line"]
			var i := map.nearest_road_point(car.global_position)
			var local := car.global_transform.affine_inverse() * (car.global_position + (-car.global_transform.basis.z) * 10.0)
			car.in_steer = clampf(-car.global_position.x - 30.0, -0.3, 0.3) * 0.0 + clampf((car.global_position.x - (-30.0)) * 0.2, -0.5, 0.5)
			car.in_throttle = 1.0
			car.in_brake = 0.0
			data["max_y"] = maxf(data["max_y"], car.global_position.y)
			log_t += dt
			if log_t > 3.0:
				log_t = 0.0
				var grade := -car.global_transform.basis.z.y * 100.0
				print("   t=%.0f y=%.1f m grade %.0f%% %.1f mph gear %s rpm %.0f coolant %.0f" % [t, car.global_position.y, grade, mph, car.trans.gear_label(), car.engine.rpm(), car.engine.coolant_c])
			if car.global_position.y > 59.5 or t > 70:
				print("   reached %.1f m of 61 m summit in %.1f s" % [data["max_y"], t])
				_next()
		"whoops":
			car.in_throttle = clampf((13.4 - car.speed_ms) * 0.3, 0.0, 1.0)
			car.in_brake = 0.0
			var line: PackedVector3Array = data["line"]
			var pos := car.global_position
			var best := 1e12
			var bi := 0
			var start: int = maxi(0, int(data["idx"]) - 200)
			for k in range(start, mini(line.size(), int(data["idx"]) + 2000), 4):
				var d := pos.distance_squared_to(line[k])
				if d < best:
					best = d; bi = k
			var ahead := line[mini(bi + 40, line.size() - 1)]
			var lp := car.global_transform.affine_inverse() * ahead
			car.in_steer = clampf(atan2(lp.x, -lp.z) * 2.0, -1, 1)
			for w in car.wheels:
				data["max_comp"] = maxf(data["max_comp"], w.compression / w.travel)
			data["min_up"] = minf(data["min_up"], car.global_transform.basis.y.y)
			if t > 25:
				print("   30 mph over whoops: max suspension use %.0f%%, min upright %.2f (1 = level), speed %.1f mph" % [data["max_comp"] * 100.0, data["min_up"], mph])
				_next()
	return false
