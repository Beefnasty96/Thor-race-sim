extends Node
## Dev tool: run Car Porter with `-- --shots` to capture screenshots of each
## screen using a generated test photo (checks the UI without a phone).

var app: Node
var out_dir := "user://shots/"
var t := 0.0
var step := 0
var browser: Node

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)

func _shot(n: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(out_dir + n + ".png")
	print("saved ", ProjectSettings.globalize_path(out_dir + n + ".png"))

## A crude side-view "photo" of a boxy SUV: body, glass, wheels, ground.
static func fake_side_photo() -> Image:
	var img := Image.create(1800, 820, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.62, 0.7, 0.78))
	img.fill_rect(Rect2i(0, 640, 1800, 180), Color(0.35, 0.36, 0.35))
	img.fill_rect(Rect2i(170, 330, 1460, 250), Color(0.55, 0.06, 0.06))       # body
	img.fill_rect(Rect2i(560, 150, 1050, 190), Color(0.55, 0.06, 0.06))       # cab/roof
	img.fill_rect(Rect2i(600, 175, 300, 140), Color(0.15, 0.2, 0.28))         # windows
	img.fill_rect(Rect2i(930, 175, 300, 140), Color(0.15, 0.2, 0.28))
	img.fill_rect(Rect2i(1260, 175, 320, 140), Color(0.15, 0.2, 0.28))
	for cx in [470, 1350]:
		for y in range(440, 650):
			for x in range(cx - 110, cx + 110):
				var d := Vector2(x - cx, y - 540).length()
				if d < 105:
					img.set_pixel(x, y, Color(0.08, 0.08, 0.08) if d > 60 else Color(0.7, 0.7, 0.72))
	return img

func _process(delta: float) -> void:
	t += delta
	if t < 1.0:
		return
	t = 0.0
	match step:
		0:
			_shot("porter_01_projects")
		1:
			var def: Dictionary = Game.cars["chevrolet_tahoe_1999"]
			var p := PorterProject.create("Screenshot Tahoe")
			p.fill_from_car(def, "4door")
			p.import_image("side", fake_side_photo())
			# wheel centres in the fake photo are at (470,540) and (1350,540)
			p.align_two_points("side", Vector2(470, 540), Vector2(1350, 540), Vector2(1800, 820))
			p.save()
			app._open(p)
		2:
			_shot("porter_02_side_aligned")
			app.canvas.start_align()
		3:
			_shot("porter_03_align_prompt")
			app._select_view("front")
		4:
			_shot("porter_04_front_empty")
			# photo browser over a folder of generated photos
			var dir := OS.get_user_data_dir().path_join("shots_photos")
			DirAccess.make_dir_recursive_absolute(dir)
			for i in 9:
				var im := fake_side_photo()
				im.adjust_bcs(1.0 - i * 0.05, 1.0, 1.0)
				im.save_jpg(dir.path_join("IMG_%04d.jpg" % i), 0.8)
			var b := PhotoBrowser.new()
			b.folders = [dir]
			b.picked.connect(func(path): app._import_photo_file(path))
			app.safe.add_child(b)
			browser = b
		5:
			_shot("porter_04b_photo_browser")
			var first: TextureButton = browser.grid.get_child(0)
			first.pressed.emit()
		6:
			_shot("porter_04c_front_loaded")
			app._select_view("3d")
		7:
			_shot("porter_05_3d_check")
			var p2: PorterProject = app.project
			for f in DirAccess.get_files_at(p2.dir()):
				DirAccess.remove_absolute(p2.dir() + f)
			DirAccess.remove_absolute(p2.dir())
			get_tree().quit()
	step += 1
