extends SceneTree
## Checks the factory paint database and how the game / Car Porter use it.
##   godot --headless -s res://scripts/tests/paintdb_test.gd

var fails := 0

func _check(cond: bool, what: String) -> void:
	print(("  ok    " if cond else "  FAIL  ") + what)
	if not cond:
		fails += 1

func _initialize() -> void:
	var n := PaintDB.count()
	_check(n >= 100, "paint database loads (%d colors, %d makes)" % [n, PaintDB.makes().size()])
	var bad := 0
	for mk in PaintDB.makes():
		for p in PaintDB._by_make[mk]:
			var c: Array = p["rgb"]
			if (p["years"] as Array).is_empty() or (p["sources"] as Array).is_empty() or c.size() != 3 \
					or c.any(func(x): return x < 0.0 or x > 1.0) or not (p["finish"] in ["solid", "metallic", "pearl", "tricoat", "tintcoat"]):
				bad += 1
	_check(bad == 0, "every color has model years, a source, a 0..1 color and a finish")
	var tahoe := PaintDB.paints_for("Chevrolet", 1999, "Tahoe")
	var names := tahoe.map(func(p): return p["name"])
	_check("Victory Red" in names and "Indigo Metallic" in names and "Emerald Green Metallic" in names, "1999 Tahoe gets its factory colors (%d)" % tahoe.size())
	_check(tahoe.all(func(p): return 1999 in p["years"] and not p.get("near_year", false)), "…all sourced for 1999 itself")
	_check(not ("Hugger Orange" in names), "Camaro-only colors stay off the Tahoe")
	var camaro := PaintDB.paints_for("Chevrolet", 2000, "Camaro").map(func(p): return p["name"])
	_check("Hugger Orange" in camaro and not ("Tan" in camaro), "2000 Camaro gets Hugger Orange, not truck Tan")
	var near := PaintDB.paints_for("Chevrolet", 1997, "Tahoe")
	_check(near.size() > 0 and near.all(func(p): return p.get("near_year", false)), "a year with nothing sourced falls back to the nearest years, marked as such")
	_check(PaintDB.paints_for("Lada", 1999).is_empty(), "an unknown make gives no colors")
	_check(PaintDB.paints_for("chevrolet", 1999, "TAHOE 4WD").size() == tahoe.size(), "make and model match regardless of case")
	var gp := PaintDB.to_game_paint(tahoe[0])
	_check(gp.has("name") and gp.has("color") and gp.has("lower") and gp.has("metallic") and gp["factory_db"], "database colors become game paints")
	_check(String(PaintDB.to_game_paint({"name": "Victory Red", "codes": "74/WA9260", "rgb": [0.6, 0.1, 0.1], "years": [1999]})["name"]) == "Victory Red (74)", "game paint names carry the paint code")
	var def: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/cars/chevrolet_tahoe_1999.json"))
	var own: Array = def["paints"]
	var merged := PaintDB.merged_game_paints(own, "Chevrolet", 1999, "Tahoe")
	var reds := merged.filter(func(p): return String(p["name"]).begins_with("Victory Red"))
	_check(merged.size() > own.size() and reds.size() == 1, "the game's Tahoe gains database colors without doubling Victory Red (%d → %d)" % [own.size(), merged.size()])
	_check(merged.slice(0, own.size()) == own, "the car's own paints stay first and unchanged (saved paint choices keep working)")
	# Car Porter project
	var pp := PorterProject.new()
	pp.db_row = {"year": 1999, "make": "CHEVROLET", "model": "TAHOE 4WD"}
	_check(pp.factory_paints().size() == tahoe.size(), "a project from the production-car database gets that car's factory colors")
	pp.add_custom_paint("Victory Red", "74", Color(0.6, 0.08, 0.09))
	_check(pp.custom_paints.size() == 1 and pp.custom_paints[0]["code"] == "74", "paints added from photos are kept with name and code")
	print("ALL PASSED (0 failed)" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails > 0 else 0)
