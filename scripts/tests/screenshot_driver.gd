extends Node
## Dev tool: run the game with `-- --shots` to auto-capture screenshots of the
## menu, editor and each area of the current location (used to check visuals
## without a device).

var main: Node
var t := 0.0
var step := 0
var out_dir := "user://shots/"
var views := [
	["05_drag_strip", Vector3(100, 0, 175), Vector3(0, 0, -1)],
	["05b_cockpit", Vector3(100, 0, 120), Vector3(0, 0, -1)],
	["06_skidpad", Vector3(-169.5, 0, 10), Vector3(0, 0, -1)],
	["07_hill", Vector3(-30, 0, 170), Vector3(0, 0, 1)],
	["08_offroad", Vector3(330, 0, 185), Vector3(1, 0, 0.4)],
	["09_handling", Vector3(-150, 0, -500), Vector3(1, 0, -0.2)],
]
var view_i := 0

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	process_mode = Node.PROCESS_MODE_ALWAYS

func _shot(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(out_dir + name + ".png")
	print("saved ", ProjectSettings.globalize_path(out_dir + name + ".png"))

func _place(pos: Vector3, dir: Vector3) -> void:
	var p := pos
	if main.map:
		var r: Array = main.map.nearest_road_point(pos)
		p = r[0]
	main.car.reset_to(Transform3D(Basis.looking_at(dir.normalized(), Vector3.UP), p + Vector3.UP * 0.5))
	main.cam.snap()

func _process(dt: float) -> void:
	t += dt
	match step:
		0:
			if t > 0.6 and not has_meta("front"):
				set_meta("front", true)
				main.cam._orbit = 2.55
			if t > 3.0:
				_shot("01_menu"); step += 1
		1:
			if not has_meta("settings"):
				set_meta("settings", true)
				main._show_settings(); t = 0
				return
			if t < 1.0:
				return
			if not has_meta("thanks"):
				_shot("02a_settings")
				set_meta("thanks", true)
				main._show_thanks(); t = 0
				return
			_shot("02c_thanks")
			main._show_editor(); step += 1; t = 0
		2:
			if t > 1.5:
				_shot("02_editor"); step += 1
		3:
			main._show_locations(); step += 1; t = 0
		4:
			if t > 1.0:
				_shot("02b_locations"); step += 1
				main._start_race(); t = 0
		5:
			if t > 2.0:
				_shot("03_start"); step += 1; t = 0
		6:
			main.car.in_throttle = 0.7
			if t > 6.0:
				_shot("04_driving"); step += 1; t = 0
				main.car.in_throttle = 0.0
		7:
			if view_i >= views.size():
				step += 1; t = 0
				main.cam.mode = ChaseCamera.Mode.ORBIT
				return
			if not has_meta("placed_%d" % view_i):
				set_meta("placed_%d" % view_i, true)
				var v: Array = views[view_i]
				_place(v[1], v[2])
			main.car.in_throttle = 0.25
			var cockpit: bool = views[view_i][0] == "05b_cockpit"
			main.cam.mode = ChaseCamera.Mode.COCKPIT if cockpit else ChaseCamera.Mode.CHASE_FAR
			main.car.in_steer = 0.35 if cockpit else 0.0
			if t > 2.5:
				_shot(views[view_i][0])
				view_i += 1
				t = 0
		8:
			if t > 1.5:
				_shot("10_orbit"); step += 1
				get_tree().quit()
