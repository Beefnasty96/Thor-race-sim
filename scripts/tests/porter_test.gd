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

	# tire sizes
	var t1 := TireSpec.parse("P245/75R16")
	_check(not t1.is_empty() and absf(t1["radius_m"] - 0.3869) < 0.0005, "P245/75R16 radius 0.387 m (30.5 in tall)")
	_check(absf(TireSpec.parse("245/40ZR18 97W")["radius_m"] - 0.3266) < 0.0005, "245/40ZR18 97W parses (with load/speed rating)")
	_check(TireSpec.parse("245/40zr18")["size"] == "245/40ZR18", "ZR marking is kept")
	_check(TireSpec.parse("lt265/75r16")["light_truck"], "LT sizes parse, any case")
	_check(absf(TireSpec.parse("185/65 R15")["width_m"] - 0.185) < 1e-6, "185/65 R15 with a space parses")
	_check(absf(TireSpec.parse("31x10.50R15")["radius_m"] - 0.3937) < 0.0005, "31x10.50R15 flotation size parses (31 in tall)")
	_check(not TireSpec.parse("7.75-15").is_empty(), "old bias-ply 7.75-15 parses")
	_check(TireSpec.find_in("P245/75R16 109S all-season on 16x7 aluminum")["size"] == "P245/75R16", "size found inside longer text")
	_check(TireSpec.parse("hello").is_empty() and TireSpec.parse("999/99R99").is_empty(), "nonsense is rejected")
	var tp := PorterProject.new()
	_check(tp.set_tires("245/40ZR18", "285/40ZR18", 32, 34) == "", "staggered tires accepted")
	_check(tp.tire_radius(true) > tp.tire_radius(false), "rear radius follows the bigger rear tire")
	var tg := tp.align_targets("side")
	_check(absf(tg[1]["pos"].y - tp.tire_radius(true)) < 1e-6, "rear wheel center uses the rear tire")
	_check(tp.set_tires("P245/75R16", "", 35, 35) == "" and tp.tires["rear"] == "P245/75R16", "empty rear means same as front")
	_check(tp.set_tires("bad", "", 35, 35) != "", "a bad size is refused")
	_check(tp.set_tires("P245/75R16", "", 5, 35) != "", "an impossible pressure is refused")
	var gp := PorterProject.new()
	gp.fill_from_car(def, "4door")
	_check(gp.tires["front"] == "P245/75R16" and gp.tires["front_psi"] == 35.0, "game Tahoe pre-fills P245/75R16 at 35 PSI")
	p.set_tires("P245/75R16", "P265/75R16", 35, 38)
	p.save()
	var p3 := PorterProject.load_project(p.id)
	_check(p3.tires["rear"] == "P265/75R16" and p3.tires["rear_psi"] == 38.0, "tires survive save/load")
	_check(absf(p3.dims["tire_radius_rear_m"] - TireSpec.parse("P265/75R16")["radius_m"]) < 1e-6, "rear radius survives save/load")

	# clean up
	for f in DirAccess.get_files_at(p.dir()):
		DirAccess.remove_absolute(p.dir() + f)
	DirAccess.remove_absolute(p.dir())
	print("\n%s (%d failed)" % ["ALL PASSED" if fails == 0 else "FAILURES", fails])
	quit(1 if fails else 0)
