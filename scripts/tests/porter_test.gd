extends SceneTree
## Headless checks for Car Porter's project model. Run:
##   godot --headless -s res://scripts/tests/porter_test.gd

var fails := 0

func _check(cond: bool, what: String) -> void:
	print(("  ok    " if cond else "  FAIL  ") + what)
	if not cond:
		fails += 1

func _near(a: Vector2, b: Vector2, tol: float = 0.002) -> bool:
	return a.distance_to(b) <= tol

func _initialize() -> void:
	var def = JSON.parse_string(FileAccess.get_file_as_string("res://data/cars/chevrolet_tahoe_1999.json"))
	var p := PorterProject.create("porter test car")
	p.fill_from_car(def, "4door")
	_check(absf(p.dims["wheelbase_m"] - 2.985) < 1e-6, "dimensions copied from the Tahoe car file")
	_check(p.source_car == "chevrolet_tahoe_1999", "source car recorded")

	# synthetic side photo: 1600x700, wheels at known pixels, photo mirrored and tilted
	var img := Image.create(1600, 700, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.8, 0.8, 0.8))
	_check(p.import_image("side", img) == "", "photo imported")
	_check(FileAccess.file_exists(p.dir() + "side.png"), "photo copied into the project folder")
	var size := Vector2(1600, 700)
	for flip in [false, true]:
		p.views["side"]["flip"] = flip
		var a := Vector2(310, 540)
		var b := Vector2(1290, 525)    # slightly tilted photo
		_check(p.align_two_points("side", a, b, size), "two-point align solves (mirror=%s)" % flip)
		var tg := p.align_targets("side")
		_check(_near(p.image_to_frame("side", a, size), tg[0]["pos"]), "front wheel tap lands on the front axle (mirror=%s)" % flip)
		_check(_near(p.image_to_frame("side", b, size), tg[1]["pos"]), "rear wheel tap lands on the rear axle (mirror=%s)" % flip)
		var q := Vector2(777, 123)
		_check(_near(p.frame_to_image("side", p.image_to_frame("side", q, size), size), q, 0.01), "pixel → frame → pixel round trip (mirror=%s)" % flip)
	_check(not p.align_two_points("side", Vector2(10, 10), Vector2(11, 10), size), "taps too close together are rejected")

	# front view: tire contact points land at ± half the front track
	p.align_two_points("front", Vector2(200, 600), Vector2(1100, 600), size)
	var t: float = p.dims["track_front_m"] * 0.5
	_check(_near(p.image_to_frame("front", Vector2(200, 600), size), Vector2(-t, 0)), "front view left tire at -track/2")

	# save / load
	p.units = "metric"
	p.dims["front_overhang_m"] = 0.912
	_check(p.save(), "project saved")
	var p2 := PorterProject.load_project(p.id)
	_check(p2 != null and p2.name == p.name, "project loads with its name")
	_check(p2 != null and absf(p2.dims["front_overhang_m"] - 0.912) < 1e-6, "edited dimension survives save/load")
	_check(p2 != null and p2.units == "metric", "units survive save/load")
	_check(p2 != null and _near(Vector2(p2.views["front"]["cx"], p2.views["front"]["cy"]), Vector2(p.views["front"]["cx"], p.views["front"]["cy"]), 1e-6), "photo alignment survives save/load")
	var listed := false
	for info in PorterProject.list_projects():
		if info["id"] == p.id:
			listed = true
	_check(listed, "project appears in the project list")

	# unit parsing
	_check(absf(PorterUI.parse_len("188", "imperial") - 4.7752) < 1e-4, "188 (inches) parses")
	_check(absf(PorterUI.parse_len("4775 mm", "imperial") - 4.775) < 1e-6, "4775 mm parses in imperial mode")
	_check(absf(PorterUI.parse_len("2985", "metric") - 2.985) < 1e-6, "2985 (mm) parses")
	_check(PorterUI.parse_len("abc", "imperial") < 0.0, "garbage is rejected")

	# clean up
	for f in DirAccess.get_files_at(p.dir()):
		DirAccess.remove_absolute(p.dir() + f)
	DirAccess.remove_absolute(p.dir())
	print("\n%s (%d failed)" % ["ALL PASSED" if fails == 0 else "FAILURES", fails])
	quit(1 if fails else 0)
