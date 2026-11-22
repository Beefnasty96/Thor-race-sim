extends Node
## Game flow: Main menu → Vehicle Editor / Race (free practice) → Pause.
## Builds the world (environment, track, car, camera) and wires player input.

enum State { MENU, EDITOR, SETTINGS, THANKS, RACE, PAUSED }

var state := State.MENU
var world: Node3D
var track: Track                 # race circuit (lap timing)
var map: MapBuilder              # data-driven map (proving ground, future town maps)
var location := ""
var tests := TestRig.new()
var rumble := Rumble.new()
const LOCATIONS := {
	"proving_ground": {"name": "Proving Ground", "file": "res://data/maps/proving_ground.json"},
	"ridgeview": {"name": "Ridgeview Circuit", "file": ""},
}
var car: Vehicle
var model: CarModel
var cam: ChaseCamera
var hud: HUD
var ui: CanvasLayer
var menu_root: Control
var spec_label: RichTextLabel

# lap timing
var _idx := -1
var _rel_prev := 0
var _checkpoints := 0
var _lap_valid := false
var _upside_t := 0.0
var _save_t := 0.0

func _ready() -> void:
	InputSetup.register()
	InputSetup.apply_deadzones(Game.settings)
	rumble.strength = Game.settings.get("rumble", 1.0)
	Input.joy_connection_changed.connect(func(id, connected):
		if hud and state == State.RACE:
			hud.flash(("CONTROLLER CONNECTED" if connected else "CONTROLLER DISCONNECTED"), 2.0)
		if not connected and state == State.RACE:
			_pause())
	ui = CanvasLayer.new()
	add_child(ui)
	var theme_root := Control.new()
	theme_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	theme_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme_root.theme = UIKit.theme()
	ui.add_child(theme_root)
	menu_root = theme_root
	_build_world()
	hud = HUD.new()
	hud.visible = false
	theme_root.add_child(hud)
	_load_location(Game.settings.get("location", "proving_ground"))
	_spawn_car()
	tests.result.connect(func(t): hud.flash(t, 3.0))
	_show_main_menu()
	if "--shots" in OS.get_cmdline_user_args():
		var d = load("res://scripts/tests/screenshot_driver.gd").new()
		d.main = self
		add_child(d)

# =====================================================================
# World
# =====================================================================
func _build_world() -> void:
	world = Node3D.new()
	add_child(world)
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.26, 0.45, 0.76)
	sky_mat.sky_horizon_color = Color(0.70, 0.78, 0.86)
	sky_mat.ground_horizon_color = Color(0.62, 0.66, 0.66)
	sky_mat.ground_bottom_color = Color(0.25, 0.27, 0.25)
	sky_mat.sun_angle_max = 30.0
	sky_mat.sky_energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.75
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0
	# soft bloom + aerial haze: the PS2-era "Gran Turismo" glow
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_strength = 0.9
	env.glow_bloom = 0.06
	env.glow_hdr_threshold = 0.9
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.fog_enabled = true
	env.fog_light_color = Color(0.72, 0.79, 0.88)
	env.fog_density = 0.0016
	env.fog_aerial_perspective = 0.35
	env.fog_sky_affect = 0.15
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.07
	env.adjustment_saturation = 1.12
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, -35, 0)
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 140.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	world.add_child(sun)

	cam = ChaseCamera.new()
	cam.far = 2500.0
	cam.current = true
	world.add_child(cam)

func _load_location(loc: String) -> void:
	if not LOCATIONS.has(loc):
		loc = "proving_ground"
	if loc == location and (track or map):
		return
	if track:
		track.queue_free()
		track = null
	if map:
		map.queue_free()
		map = null
	location = loc
	Game.settings["location"] = loc
	if loc == "ridgeview":
		track = Track.new()
		world.add_child(track)
		track.build()
		hud.set_track(track)
		hud.show_laps = true
	else:
		map = MapBuilder.new()
		world.add_child(map)
		map.build_from_file(LOCATIONS[loc]["file"])
		hud.set_lines(map.minimap_lines())
		hud.show_laps = map.data.get("laps", false)
	if car:
		car.reset_to(_spawn_xform())
		_setup_tests()

func location_name() -> String:
	return LOCATIONS.get(location, {}).get("name", "")

func _spawn_xform() -> Transform3D:
	return track.start_transform(0) if track else map.spawn_transform()

func _setup_tests() -> void:
	tests.setup(car, map.data.get("zones", {}) if map else {})
	tests.reset_run()
	hud.tests = tests

func _spawn_car() -> void:
	if car:
		car.queue_free()
	var def := Game.car_def()
	car = Vehicle.new()
	car.name = "PlayerCar"
	car.configure(def, Game.setup, Game.condition)
	world.add_child(car)
	model = CarModel.new()
	var paints: Array = def["paints"]
	car.add_child(model)
	model.build(def.get("model_dir", "res://assets/cars/tahoe_1999"),
			paints[clampi(int(Game.setup.get("paint", 0)), 0, paints.size() - 1)])
	model.car = car
	for i in 4:
		car.wheels[i].visual = model.wheel_nodes[i]
	cam.cockpit_eye = model.driver_eye
	car.reset_to(_spawn_xform())
	rumble.mute()
	cam.target = car
	cam.snap()
	if hud:
		hud.car = car
	_idx = -1
	_checkpoints = 0
	_lap_valid = false
	if hud:
		_setup_tests()

# =====================================================================
# Race loop
# =====================================================================
func _physics_process(dt: float) -> void:
	if car == null:
		return
	if state != State.RACE:
		if rumble.strong > 0.0 or rumble.weak > 0.0:
			rumble.stop()
			rumble.strong = 0.0
			rumble.weak = 0.0
		car.in_throttle = 0.0
		car.in_brake = 1.0 if state != State.PAUSED else car.in_brake
		car.in_steer = 0.0
		return
	if not "--shots" in OS.get_cmdline_user_args():
		_read_driver_input(dt)
	if track:
		_lap_timing(dt)
	tests.update(dt)
	rumble.update(car, dt)
	# auto-recover if the truck ends up on its roof
	if car.global_transform.basis.y.y < 0.25:
		_upside_t += dt
		if _upside_t > 3.0:
			_reset_on_track()
	else:
		_upside_t = 0.0
	_save_t += dt
	if _save_t > 30.0:
		_save_t = 0.0
		_store_condition()

func _read_driver_input(dt: float) -> void:
	var thr := Input.get_action_strength("throttle")
	var brk := Input.get_action_strength("brake")
	var raw := Input.get_action_strength("steer_right") - Input.get_action_strength("steer_left")
	var lin: float = Game.settings.get("steer_linearity", 1.6)
	var sens: float = Game.settings.get("steer_sensitivity", 1.0)
	var steer := signf(raw) * pow(absf(raw), lin) * sens
	# speed-sensitive lock for thumbsticks (a stick has ~20 mm of travel,
	# a real wheel has 1.7 turns lock to lock)
	var spd := absf(car.speed_ms)
	steer *= lerpf(1.0, 0.32, clampf((spd - 5.0) / 30.0, 0.0, 1.0))
	car.in_steer = clampf(steer, -1.0, 1.0)
	# reverse: when stopped, holding brake selects R; throttle drives
	if car.trans.gear == -1:
		car.in_throttle = thr
		car.in_brake = brk
	else:
		car.in_throttle = thr
		car.in_brake = brk
	car.in_handbrake = 1.0 if Input.is_action_pressed("handbrake") else 0.0
	var look := Input.get_action_strength("look_right") - Input.get_action_strength("look_left")
	cam.look_yaw = lerpf(cam.look_yaw, -look * PI * 0.6, clampf(dt * 8.0, 0, 1))
	cam.look_back = Input.is_action_pressed("look_back")
	# automatic: hold brake at a standstill for 0.6 s to engage reverse
	if not car.trans.manual:
		if spd < 0.5 and brk > 0.5 and thr < 0.05 and car.trans.gear == 1:
			_rev_hold += dt
			if _rev_hold > 0.6:
				car.trans.request_shift(-1)
				hud.flash("REVERSE", 1.0)
				_rev_hold = 0.0
		elif spd < 0.5 and thr > 0.1 and car.trans.gear == -1 and brk < 0.1:
			pass
		else:
			_rev_hold = 0.0
		if car.trans.gear == -1 and spd < 0.5 and brk > 0.5 and thr < 0.05:
			_fwd_hold += dt
			if _fwd_hold > 0.6:
				car.trans.request_shift(1)
				hud.flash("DRIVE", 1.0)
				_fwd_hold = 0.0
		else:
			_fwd_hold = 0.0

var _rev_hold := 0.0
var _fwd_hold := 0.0

func _unhandled_input(e: InputEvent) -> void:
	if state == State.RACE:
		if e.is_action_pressed("pause"):
			_pause()
		elif e.is_action_pressed("shift_up"):
			car.shift_up()
		elif e.is_action_pressed("shift_down"):
			car.shift_down()
		elif e.is_action_pressed("camera"):
			cam.cycle()
			hud.cam_name = ChaseCamera.MODE_NAMES[cam.mode]
		elif e.is_action_pressed("telemetry"):
			hud.show_telemetry = not hud.show_telemetry
			Game.settings["show_telemetry"] = hud.show_telemetry
		elif e.is_action_pressed("transfer_case"):
			_cycle_transfer()
		elif e.is_action_pressed("trans_mode"):
			car.trans.manual = not car.trans.manual
			Game.setup["trans_mode"] = "manual" if car.trans.manual else "auto"
			hud.flash("MANUAL" if car.trans.manual else "AUTOMATIC", 1.2)
		elif e.is_action_pressed("reset_car"):
			_reset_on_track()
	elif state == State.PAUSED and (e.is_action_pressed("pause") or e.is_action_pressed("ui_cancel")):
		_resume()
	elif state == State.THANKS and e.is_action_pressed("ui_cancel"):
		_show_settings()
	elif (state == State.EDITOR or state == State.SETTINGS) and e.is_action_pressed("ui_cancel"):
		Game.save_game()
		_show_main_menu()

func _cycle_transfer() -> void:
	if car.drivetrain != "4wd":
		hud.flash("2WD TRUCK", 1.0)
		return
	var order := ["2H", "4H", "4L"]
	var next: String = order[(order.find(car.transfer) + 1) % 3]
	if next == "4L" and absf(car.speed_ms) > 2.0:
		next = "2H"    # low range needs the truck (nearly) stopped
	car.set_transfer(next)
	Game.setup["transfer"] = next
	hud.flash("4WD " + next, 1.2)

func _lap_timing(dt: float) -> void:
	hud.lap_time += dt
	var m := track.pts.size()
	_idx = track.nearest_index(car.global_position, _idx)
	var rel := (_idx - track.start_index + m) % m
	if rel > m * 0.30 and rel < m * 0.40:
		_checkpoints |= 1
	if rel > m * 0.62 and rel < m * 0.72:
		_checkpoints |= 2
	if _rel_prev > m * 0.9 and rel < m * 0.1:
		if _checkpoints == 3 and _lap_valid:
			var t := hud.lap_time
			hud.last_lap = t
			var key := Game.setup_key() + "|" + location_name()
			var best: float = Game.best_laps.get(key, 0.0)
			if best <= 0.0 or t < best:
				Game.best_laps[key] = t
				hud.flash("BEST LAP  " + Game.fmt_time(t), 3.0)
			else:
				hud.flash("LAP  " + Game.fmt_time(t), 2.0)
			hud.best_lap = Game.best_laps[key]
			hud.lap += 1
			_store_condition()
		_lap_valid = true
		_checkpoints = 0
		hud.lap_time = 0.0
	_rel_prev = rel

func _reset_on_track() -> void:
	var p: Vector3
	var t: Vector3
	if track:
		var i := track.nearest_index(car.global_position, _idx)
		p = track.pts[i]
		t = track.tangents[i]
	else:
		var r := map.nearest_road_point(car.global_position)
		p = r[0]
		t = r[1]
	var flat := Vector3(t.x, 0, t.z).normalized()
	car.reset_to(Transform3D(Basis.looking_at(flat, Vector3.UP), p + Vector3.UP * 0.4))
	rumble.mute()
	cam.snap()
	hud.flash("RESET", 1.0)

func _store_condition() -> void:
	var c := car.condition_snapshot()
	Game.condition["engine_health"] = c["engine_health"]
	Game.condition["tire_tread_mm"] = c["tire_tread_mm"]
	Game.condition["odometer_km"] = Game.condition.get("odometer_km", 0.0) + car.odometer_m / 1000.0
	car.odometer_m = 0.0
	Game.save_game()

# =====================================================================
# Menus
# =====================================================================
func _clear_menu() -> void:
	for c in menu_root.get_children():
		if c != hud:
			c.queue_free()
	spec_label = null

func _panel(anchor_left: float, top: float, width: float) -> VBoxContainer:
	var pc := PanelContainer.new()
	pc.position = Vector2(get_viewport().get_visible_rect().size.x * anchor_left, top)
	pc.custom_minimum_size = Vector2(width, 0)
	menu_root.add_child(pc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	pc.add_child(v)
	return v

func _button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(420, 60)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b

func _show_main_menu() -> void:
	state = State.MENU
	get_tree().paused = false
	_clear_menu()
	hud.visible = false
	cam.mode = ChaseCamera.Mode.ORBIT
	var v := _panel(0.06, 300, 480)
	v.add_child(UIKit.label("RACING SIM", 54, Color.WHITE))
	var d := Game.car_def()
	v.add_child(UIKit.label("%d %s %s  ·  %s" % [d["year"], d["make"], d["model"], location_name()], 22, UIKit.DIM))
	v.add_child(HSeparator.new())
	var first := _button(v, "Free Practice", _show_locations)
	_button(v, "Vehicle Editor", _show_editor)
	_button(v, "Settings", _show_settings)
	if OS.get_name() != "Web":
		_button(v, "Quit", func(): Game.save_game(); get_tree().quit())
	var hint := UIKit.label("A select   B back   D-pad navigate", 20, UIKit.DIM)
	v.add_child(hint)
	first.call_deferred("grab_focus")

func _show_locations() -> void:
	_clear_menu()
	var v := _panel(0.06, 300, 520)
	v.add_child(UIKit.label("CHOOSE LOCATION", 40, Color.WHITE))
	var first: Button = null
	for key in LOCATIONS:
		var b := _button(v, LOCATIONS[key]["name"], func():
			_clear_menu()
			_load_location(key)
			_start_race())
		if first == null or key == location:
			first = b
	_button(v, "Back", _show_main_menu)
	v.add_child(UIKit.label("Your town will appear here once its map data is imported.", 18, UIKit.DIM))
	first.call_deferred("grab_focus")

func _start_race() -> void:
	_clear_menu()
	_spawn_car()
	state = State.RACE
	hud.visible = true
	hud.show_telemetry = Game.settings.get("show_telemetry", true)
	hud.lap = 1
	hud.lap_time = 0.0
	hud.last_lap = 0.0
	hud.best_lap = Game.best_laps.get(Game.setup_key() + "|" + location_name(), 0.0)
	cam.mode = Game.settings.get("camera", 0) as ChaseCamera.Mode
	cam.snap()
	hud.cam_name = ChaseCamera.MODE_NAMES[cam.mode]
	hud.flash(location_name().to_upper(), 2.0)

func _pause() -> void:
	state = State.PAUSED
	_clear_menu()
	var v := _panel(0.36, 280, 480)
	v.add_child(UIKit.label("PAUSED", 44, Color.WHITE))
	var r := _button(v, "Resume", _resume)
	_button(v, "Restart from start", func(): _resume(); car.reset_to(_spawn_xform()); cam.snap(); hud.lap_time = 0.0; _lap_valid = false; _checkpoints = 0; tests.reset_run())
	_button(v, "Reset to track", func(): _resume(); _reset_on_track())
	_button(v, "Exit to menu", func(): _store_condition(); _show_main_menu())
	v.add_child(UIKit.label("Controls (XInput): RT throttle · LT brake · Left stick steer\nRB/LB shift (manual) · A handbrake · Y camera · X look back\nD-pad ↑ transfer case · D-pad ↓ auto/manual · Back telemetry · RS reset", 18, UIKit.DIM))
	get_tree().paused = false
	car.in_throttle = 0.0
	r.call_deferred("grab_focus")

func _resume() -> void:
	_clear_menu()
	state = State.RACE
	Game.settings["camera"] = cam.mode

# ---------------------------------------------------------------------
func _show_editor() -> void:
	state = State.EDITOR
	_clear_menu()
	cam.mode = ChaseCamera.Mode.ORBIT
	var d := Game.car_def()
	var s := Game.setup
	var v := _panel(0.03, 40, 800)
	v.add_child(UIKit.label("VEHICLE EDITOR  —  %d %s %s" % [d["year"], d["make"], d["model"]], 34, Color.WHITE))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(790, 820)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	scroll.add_child(list)

	var rows := []
	var paints: Array = d["paints"]
	var paint_idx := []
	var paint_names := []
	for i in paints.size():
		paint_idx.append(i); paint_names.append(paints[i]["name"])
	rows.append(_section(list, "BODY & DRIVETRAIN"))
	rows.append(_row(list, "body", "Body", ["4door", "2door"], ["4-Door", "2-Door"], s["body"]))
	rows.append(_row(list, "drivetrain", "Drivetrain", ["2wd", "4wd"], ["2WD (rear)", "4WD part-time"], s["drivetrain"]))
	rows.append(_row(list, "rear_diff", "Rear differential", ["open", "g80_locker"], ["Open", "G80 auto-locker"], s["rear_diff"]))
	rows.append(_row(list, "final_drive", "Axle ratio", [3.42, 3.73], ["3.42", "3.73"], s["final_drive"]))
	rows.append(_row(list, "trans_mode", "Transmission", ["auto", "manual"], ["Automatic (D)", "Manual shift (L1/R1)"], s["trans_mode"]))
	rows.append(_row(list, "paint", "Paint", paint_idx, paint_names, s["paint"]))
	rows.append(_section(list, "TIRES & SUSPENSION"))
	var topts: Dictionary = d["tires"].get("options", {})
	if not topts.is_empty():
		var tk := []
		var tl := []
		for k in topts:
			tk.append(k); tl.append(topts[k]["label"])
		rows.append(_row(list, "tire_size", "Tire size", tk, tl, s.get("tire_size", tk[0])))
	rows.append(_row_range(list, "tire_psi_front", "Tire pressure front (placard 35)", 24, 44, 1, s["tire_psi_front"], " psi"))
	rows.append(_row_range(list, "tire_psi_rear", "Tire pressure rear (placard 35)", 24, 44, 1, s["tire_psi_rear"], " psi"))
	rows.append(_row_pct(list, "spring_scale_front", "Front springs (torsion bars)", 0.7, 1.6, 0.05, s["spring_scale_front"]))
	rows.append(_row_pct(list, "spring_scale_rear", "Rear leaf springs", 0.7, 1.6, 0.05, s["spring_scale_rear"]))
	rows.append(_row_pct(list, "damper_scale", "Shock absorbers", 0.7, 1.8, 0.05, s["damper_scale"]))
	rows.append(_row_pct(list, "arb_scale_front", "Front anti-roll bar", 0.0, 2.5, 0.1, s["arb_scale_front"]))
	rows.append(_row(list, "arb_scale_rear", "Rear anti-roll bar", [1.0, 1.5, 2.0, 2.5], ["None (stock)", "Light", "Medium", "Heavy"], s["arb_scale_rear"]))
	rows.append(_row_range(list, "ride_height_offset_mm", "Ride height", -50, 100, 25, s["ride_height_offset_mm"], " mm"))
	rows.append(_row_range(list, "camber_front_deg", "Front camber (factory +0.65)", -2.0, 1.5, 0.05, s["camber_front_deg"], "°"))
	rows.append(_row_range(list, "caster_deg", "Caster (factory 3.0)", 1.0, 6.0, 0.25, s.get("caster_deg", 3.0), "°"))
	rows.append(_row_range(list, "toe_total_in", "Toe-in, total (factory 0.12)", -0.24, 0.48, 0.02, s.get("toe_total_in", 0.12), " in"))
	rows.append(_section(list, "BRAKES & ASSISTS"))
	rows.append(_row_pct(list, "brake_bias_front", "Brake bias (front)", 0.55, 0.80, 0.01, s["brake_bias_front"]))
	rows.append(_row_pct(list, "brake_power", "Brake pads", 0.85, 1.3, 0.05, s["brake_power"]))
	rows.append(_row(list, "abs", "ABS", [true, false], ["On (factory)", "Off"], s["abs"]))
	rows.append(_row(list, "tcs", "Traction control", [false, true], ["Off (factory)", "On (assist)"], s["tcs"]))
	rows.append(_row(list, "speed_limiter", "Speed limiter", [true, false], ["98 mph (factory)", "Removed"], s["speed_limiter"]))
	rows.append(_section(list, "SERVICE"))
	var svc_e := Button.new()
	svc_e.custom_minimum_size = Vector2(760, 52)
	svc_e.alignment = HORIZONTAL_ALIGNMENT_LEFT
	list.add_child(svc_e)
	var svc_t := Button.new()
	svc_t.custom_minimum_size = Vector2(760, 52)
	svc_t.alignment = HORIZONTAL_ALIGNMENT_LEFT
	list.add_child(svc_t)
	var refresh_service := func():
		svc_e.text = "Rebuild engine        (condition %d%%)" % roundi(Game.condition["engine_health"] * 100.0)
		var tr: Array = Game.condition["tire_tread_mm"]
		var avg := 0.0
		for x in tr:
			avg += (d["tires"]["tread_depth_new_mm"] if x < 0 else x)
		avg /= 4.0
		svc_t.text = "Fit new tires         (tread %.1f mm of %.1f)" % [avg, d["tires"]["tread_depth_new_mm"]]
	refresh_service.call()
	svc_e.pressed.connect(func(): Game.service_engine(); refresh_service.call())
	svc_t.pressed.connect(func(): Game.new_tires(); refresh_service.call())
	var reset := Button.new()
	reset.text = "Restore factory setup"
	reset.custom_minimum_size = Vector2(760, 52)
	reset.alignment = HORIZONTAL_ALIGNMENT_LEFT
	reset.pressed.connect(func():
		var keep_paint = Game.setup.get("paint", 0)
		Game.setup = Game.default_setup(Game.current_car_id)
		Game.setup["paint"] = keep_paint
		Game.save_game()
		_spawn_car()
		_show_editor())
	list.add_child(reset)
	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(760, 52)
	back.pressed.connect(func(): Game.save_game(); _show_main_menu())
	list.add_child(back)

	# spec sheet on the right
	var sp := PanelContainer.new()
	sp.position = Vector2(get_viewport().get_visible_rect().size.x - 600, 40)
	sp.custom_minimum_size = Vector2(560, 0)
	menu_root.add_child(sp)
	spec_label = RichTextLabel.new()
	spec_label.bbcode_enabled = true
	spec_label.fit_content = true
	spec_label.custom_minimum_size = Vector2(530, 0)
	spec_label.add_theme_font_size_override("normal_font_size", 22)
	spec_label.add_theme_font_size_override("bold_font_size", 24)
	sp.add_child(spec_label)
	_update_specs()
	for r in rows:
		if r is UIKit.OptionRow:
			r.call_deferred("grab_focus")
			break

func _section(parent: Control, title: String) -> Label:
	var l := UIKit.label(title, 20, UIKit.ACCENT)
	parent.add_child(l)
	return l

func _row(parent: Control, key: String, title: String, vals: Array, labs: Array, current) -> UIKit.OptionRow:
	var r := UIKit.OptionRow.new()
	r.setup(key, title, vals, labs, current)
	r.value_changed.connect(_on_setup_changed)
	parent.add_child(r)
	return r

func _row_range(parent: Control, key: String, title: String, lo: float, hi: float, step: float, current, unit: String) -> UIKit.OptionRow:
	var vals := []
	var labs := []
	var x := lo
	while x <= hi + 0.0001:
		vals.append(snappedf(x, step))
		labs.append(("%+.2f" % x if step < 1.0 else ("%+d" % roundi(x) if lo < 0 else "%d" % roundi(x))) + unit)
		x += step
	return _row(parent, key, title, vals, labs, current)

func _row_pct(parent: Control, key: String, title: String, lo: float, hi: float, step: float, current) -> UIKit.OptionRow:
	var vals := []
	var labs := []
	var x := lo
	while x <= hi + 0.0001:
		vals.append(snappedf(x, 0.001))
		labs.append("%d%%" % roundi(x * 100.0))
		x += step
	return _row(parent, key, title, vals, labs, current)

func _on_setup_changed(key: String, value) -> void:
	Game.setup[key] = value
	if key == "paint" and model:
		model.set_paint(Game.car_def()["paints"][int(value)])
	elif key in ["body", "drivetrain", "ride_height_offset_mm"]:
		_spawn_car()
		cam.mode = ChaseCamera.Mode.ORBIT
	_update_specs()

func _update_specs() -> void:
	if spec_label == null:
		return
	var d := Game.car_def()
	var s := Game.setup
	var b: Dictionary = d["bodies"][s["body"]]
	var m: float = b["mass_4wd_kg"] if s["drivetrain"] == "4wd" else b["mass_2wd_kg"]
	var f: float = b["front_weight_fraction"] - (0.012 if s["drivetrain"] == "2wd" else 0.0)
	var e: Dictionary = d["engine"]
	var front_sus: String = d["suspension"]["front_type_4wd"] if s["drivetrain"] == "4wd" else d["suspension"]["front_type_2wd"]
	var txt := "[b]%d %s %s %s[/b]\n" % [d["year"], d["make"], d["model"], b["label"]]
	txt += "[color=#9fb0c8]%s[/color]\n\n" % d["platform"]
	txt += "Engine: %s\n" % e["name"]
	txt += "Power: %d hp @ %d rpm\n" % [e["rated_hp"], e["rated_hp_rpm"]]
	txt += "Torque: %d lb-ft @ %d rpm\n" % [e["rated_torque_lbft"], e["rated_torque_rpm"]]
	txt += "Transmission: %s\n" % d["transmission"]["name"]
	txt += "Drive: %s\n" % ("4WD, " + d["drivetrain"]["transfer_case"] if s["drivetrain"] == "4wd" else "Rear-wheel drive")
	txt += "Axle: %.2f, %s\n\n" % [s["final_drive"], "G80 locker" if s["rear_diff"] == "g80_locker" else "open diff"]
	txt += "Curb weight: %d lb (%d kg)\n" % [roundi(m * 2.20462), roundi(m)]
	txt += "Weight split: %d / %d\n" % [roundi(f * 100.0), roundi((1.0 - f) * 100.0)]
	txt += "Wheelbase: %.1f in\n" % (b["wheelbase_m"] / 0.0254)
	txt += "Power-to-weight: %.1f lb/hp\n\n" % (m * 2.20462 / e["rated_hp"])
	txt += "Front: %s\nRear: %s\n" % [front_sus, d["suspension"]["rear_type"]]
	txt += "Brakes: %s / %s\n" % [d["brakes"]["front"], d["brakes"]["rear"]]
	txt += "Tires: %s\n\n" % d["tires"]["size"]
	txt += "[color=#9fb0c8]Odometer: %d mi[/color]" % roundi(Game.condition.get("odometer_km", 0.0) * 0.621371)
	spec_label.text = txt

# ---------------------------------------------------------------------
## "Thanks To" screen (reached from Settings). People and asset credits come
## from data/thanks.json so names can be added without touching code.
func _show_thanks() -> void:
	state = State.THANKS
	_clear_menu()
	var data: Dictionary = {}
	if FileAccess.file_exists("res://data/thanks.json"):
		data = JSON.parse_string(FileAccess.get_file_as_string("res://data/thanks.json"))
	var v := _panel(0.06, 120, 960)
	v.add_child(UIKit.label(str(data.get("title", "Thanks To")).to_upper(), 40, Color.WHITE))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(940, 640)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 10)
	scroll.add_child(list)
	var add_section := func(title: String, entries: Array) -> void:
		if entries.is_empty():
			return
		list.add_child(UIKit.label(title, 22, UIKit.ACCENT))
		for e in entries:
			var name := UIKit.label(str(e.get("name", "")), 26, Color.WHITE)
			list.add_child(name)
			if str(e.get("for", "")) != "":
				var why := UIKit.label(str(e["for"]), 19, UIKit.DIM)
				why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				why.custom_minimum_size = Vector2(900, 0)
				list.add_child(why)
		list.add_child(HSeparator.new())
	add_section.call("SPECIAL THANKS", data.get("people", []))
	add_section.call("ASSETS & TOOLS", data.get("assets", []))
	if data.has("note"):
		list.add_child(UIKit.label(str(data["note"]), 17, UIKit.DIM))
	var b := _button(v, "Back", _show_settings)
	b.call_deferred("grab_focus")

func _show_settings() -> void:
	state = State.SETTINGS
	_clear_menu()
	var v := _panel(0.06, 200, 820)
	v.add_child(UIKit.label("SETTINGS", 40, Color.WHITE))
	var st := Game.settings
	var r1 := UIKit.OptionRow.new().setup("units", "Units", ["imperial", "metric"], ["mph / °F", "km/h / °C"], st["units"])
	var sens_vals := [0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.35, 1.5]
	var r2 := UIKit.OptionRow.new().setup("steer_sensitivity", "Steering sensitivity", sens_vals, sens_vals.map(func(x): return "%d%%" % roundi(x * 100)), st["steer_sensitivity"])
	var lin_vals := [1.0, 1.2, 1.4, 1.6, 1.8, 2.0, 2.4]
	var r3 := UIKit.OptionRow.new().setup("steer_linearity", "Steering linearity", lin_vals, lin_vals.map(func(x): return "%.1f" % x), st["steer_linearity"])
	var dz_vals := [0.0, 0.03, 0.05, 0.08, 0.10, 0.12, 0.15, 0.20, 0.24]
	var r4 := UIKit.OptionRow.new().setup("stick_deadzone", "Stick deadzone", dz_vals, dz_vals.map(func(x): return "%d%%" % roundi(x * 100) + ("  (XInput default)" if x == 0.24 else "")), st.get("stick_deadzone", 0.10))
	var tz_vals := [0.0, 0.02, 0.04, 0.06, 0.08, 0.12, 0.16]
	var r5 := UIKit.OptionRow.new().setup("trigger_deadzone", "Trigger deadzone", tz_vals, tz_vals.map(func(x): return "%d%%" % roundi(x * 100) + ("  (XInput default)" if x == 0.12 else "")), st.get("trigger_deadzone", 0.06))
	var rb_vals := [0.0, 0.25, 0.5, 0.75, 1.0]
	var r6 := UIKit.OptionRow.new().setup("rumble", "Rumble", rb_vals, rb_vals.map(func(x): return "Off" if x == 0.0 else "%d%%" % roundi(x * 100)), st.get("rumble", 1.0))
	for r in [r1, r2, r3, r4, r5, r6]:
		r.value_changed.connect(func(k, val):
			Game.settings[k] = val
			InputSetup.apply_deadzones(Game.settings)
			rumble.strength = Game.settings.get("rumble", 1.0)
			if k == "rumble" and val > 0.0:
				for id in Input.get_connected_joypads():
					Input.start_joy_vibration(id, 0.4 * val, 0.6 * val, 0.25))
		v.add_child(r)
	v.add_child(UIKit.label("Controller", 20, UIKit.ACCENT))
	var info := UIKit.label(InputSetup.controller_info(), 20, UIKit.TEXT)
	v.add_child(info)
	var live := UIKit.label("", 18, UIKit.DIM)
	v.add_child(live)
	# live readout so deadzones can be checked by feel
	var tmr := Timer.new()
	tmr.wait_time = 0.1
	tmr.autostart = true
	tmr.timeout.connect(func():
		if not is_instance_valid(live):
			return
		info.text = InputSetup.controller_info()
		live.text = "Steer %+.2f   Throttle %.2f   Brake %.2f" % [
			Input.get_action_strength("steer_right") - Input.get_action_strength("steer_left"),
			Input.get_action_strength("throttle"), Input.get_action_strength("brake")])
	v.add_child(tmr)
	_button(v, "Thanks To", func(): Game.save_game(); _show_thanks())
	_button(v, "Back", func(): Game.save_game(); _show_main_menu())
	r1.call_deferred("grab_focus")
