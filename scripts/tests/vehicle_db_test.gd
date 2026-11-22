extends SceneTree
## Checks the production car dimension database and filling a project from it.
##   godot --headless -s res://scripts/tests/vehicle_db_test.gd

var fails := 0

func _check(cond: bool, what: String) -> void:
	print(("  ok    " if cond else "  FAIL  ") + what)
	if not cond:
		fails += 1

func _initialize() -> void:
	_check(VehicleDB.available(), "database file is in the project")
	var n := VehicleDB.count()
	_check(n > 5000, "database has thousands of models (%d)" % n)
	var ys := VehicleDB.years()
	_check(ys.size() > 40 and ys[ys.size() - 1] <= 1975 and ys[0] >= 2020, "years span the 1970s to the 2020s (%s..%s)" % [ys[ys.size() - 1], ys[0]])
	_check(VehicleDB.makes(1999).has("Chevrolet"), "1999 includes Chevrolet")
	var tahoes := VehicleDB.models(1999, "Chevrolet", "tahoe")
	_check(tahoes.size() >= 1, "search finds the 1999 Tahoe (%d entries)" % tahoes.size())
	var bad := 0
	var rows: int = n
	for i in rows:
		var r := VehicleDB.row_dict(i)
		if not (r["length_m"] > 2.0 and r["length_m"] < 12.0 and r["width_m"] > 1.2 and r["width_m"] < 3.0
				and r["height_m"] > 0.9 and r["height_m"] < 4.0 and r["wheelbase_m"] < r["length_m"]):
			bad += 1
	_check(bad <= n * 0.002, "dimensions are plausible (%d odd rows of %d)" % [bad, n])
	if not tahoes.is_empty():
		var t: Dictionary = tahoes[0]
		for r in tahoes:
			if String(r["model"]).contains("4"):
				t = r
		print("  1999 Tahoe entry: %s  L %.3f W %.3f H %.3f WB %.3f" % [t["model"], t["length_m"], t["width_m"], t["height_m"], t["wheelbase_m"]])
		_check(absf(t["wheelbase_m"] - 2.985) < 0.08 or absf(t["wheelbase_m"] - 2.832) < 0.08, "Tahoe wheelbase matches the 117.5 in (4-door) or 111.5 in (2-door) spec")
		var p := PorterProject.new()
		p.fill_from_db(t)
		_check(p.dims["length_m"] == t["length_m"] and p.dims["height_m"] == t["height_m"], "project gets length and height from the database")
		_check(p.dims["front_overhang_m"] > 0.3 and p.dims["front_overhang_m"] < p.dims["length_m"] - p.dims["wheelbase_m"], "front overhang is set and sensible")
		_check(p.dims["track_front_m"] > 1.2 and p.dims["track_front_m"] < p.dims["width_m"], "track width is set and narrower than the body")
		_check(p.name.begins_with("1999 Chevrolet"), "project is named after the car (%s)" % p.name)
		var p2 := PorterProject.load_project("x_does_not_exist")
		_check(p2 == null, "missing project loads as null")
	_check(VehicleDB.pretty("TAHOE 4WD 4DR") == "Tahoe 4WD 4DR", "model names are tidied for display")
	_check(VehicleDB.pretty("CX-5 GS/GT 4DR SUV AWD") == "CX-5 GS/GT 4DR SUV AWD", "codes stay as written")
	print("\n%s (%d failed)" % ["ALL PASSED" if fails == 0 else "FAILURES", fails])
	quit(1 if fails else 0)
