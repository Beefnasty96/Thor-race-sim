extends Node
## Dev tool: run the game with `-- --shots` to auto-capture screenshots of the
## menu, editor and driving (used to check visuals without a device).

var main: Node
var t := 0.0
var step := 0
var out_dir := "user://shots/"

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	process_mode = Node.PROCESS_MODE_ALWAYS

func _shot(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(out_dir + name + ".png")
	print("saved ", ProjectSettings.globalize_path(out_dir + name + ".png"))

func _process(dt: float) -> void:
	t += dt
	match step:
		0:
			if t > 0.6 and not has_meta("front"):
				set_meta("front", true)
				main.cam._orbit = 2.55
				main.cam.fov = 40
			if t > 1.2 and not has_meta("front_shot"):
				set_meta("front_shot", true)
				_shot("00_front")
			if t > 3.0:
				_shot("01_menu"); step += 1
		1:
			main._show_editor(); step += 1; t = 0
		2:
			if t > 1.5:
				_shot("02_editor"); step += 1
		3:
			main._start_race(); step += 1; t = 0
		4:
			if t > 2.0:
				_shot("03_grid"); step += 1; t = 0
		5:
			main.car.in_throttle = 1.0
			if t > 9.0:
				_shot("04_driving"); step += 1; t = 0
		6:
			main.cam.cycle(); main.cam.cycle()
			step += 1; t = 0
		7:
			if t > 1.0:
				_shot("05_hood"); step += 1; t = 0
				main.cam.mode = ChaseCamera.Mode.ORBIT
		8:
			if t > 1.5:
				_shot("06_orbit"); step += 1
				get_tree().quit()
