class_name PaintDB
extends RefCounted
## Factory paint colors by make and model year, researched from period sales
## material, manufacturer press releases and paint-code references (see
## data/paints/README.md; built by tools/paints/build_paints.py). Shared by
## the game (garage paint list) and Car Porter (preview colors).
## Colors are estimated from their names unless measured ("rgb_estimated").

const DIR := "res://data/paints/"
static var _by_make := {}            # make (lower) -> Array of paint dicts
static var _loaded := false

static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	var da := DirAccess.open(DIR)
	if da == null:
		return
	for f in da.get_files():
		if not f.ends_with(".json"):
			continue
		var d = JSON.parse_string(FileAccess.get_file_as_string(DIR + f))
		if d is Dictionary:
			var lst: Array = d.get("paints", [])
			for p in lst:
				var ys: Array = []
				for y in p.get("years", []):
					ys.append(int(y))          # JSON numbers load as floats
				p["years"] = ys
			_by_make[String(d.get("make", f.get_basename())).to_lower()] = lst

static func makes() -> Array:
	_load()
	return _by_make.keys()

static func count() -> int:
	_load()
	var n := 0
	for k in _by_make:
		n += (_by_make[k] as Array).size()
	return n

## Factory colors for a car. Colors sourced for that model year first; if a
## year has none yet, the nearest years within `spread` (marked "near_year").
## `model` narrows to colors listed for that model (or "all", or a matching
## family such as trucks / SUVs); if that leaves nothing, every color of the
## make and year is returned.
static func paints_for(make: String, year: int, model: String = "", spread: int = 3) -> Array:
	_load()
	var all: Array = _by_make.get(make.to_lower(), [])
	var exact := []
	for p in all:
		if year in (p["years"] as Array):
			exact.append(p)
	var picked := exact
	if picked.is_empty():
		for d in range(1, spread + 1):
			for p in all:
				var ys: Array = p["years"]
				if (year - d) in ys or (year + d) in ys:
					var q: Dictionary = p.duplicate()
					q["near_year"] = true
					if not picked.any(func(o): return o["name"] == q["name"] and o["codes"] == q["codes"]):
						picked.append(q)
			if not picked.is_empty():
				break
	if model == "":
		return picked
	var narrowed := picked.filter(func(p): return fits_model(p, model))
	return narrowed if not narrowed.is_empty() else picked

const FAMILIES := {
	"trucks": ["silverado", "sierra", "c/k", "c1500", "k1500", "pickup", "truck", "f-150", "f150", "f-series", "ram", "s10", "s-10", "tacoma", "tundra", "colorado", "ranger"],
	"suvs": ["tahoe", "suburban", "yukon", "blazer", "trailblazer", "explorer", "expedition", "durango", "cherokee", "wrangler", "4runner", "escalade"],
	"cars": ["camaro", "corvette", "impala", "malibu", "cavalier", "monte", "lumina", "mustang", "taurus", "grand am", "grand prix", "firebird", "neon", "intrepid"],
}

static func fits_model(p: Dictionary, model: String) -> bool:
	var m := model.to_lower()
	for tag in p.get("models", ["all"]):
		var t := String(tag).to_lower()
		if t == "all" or (t.length() > 2 and m.contains(t)):
			return true
		if FAMILIES.has(t):
			for word in FAMILIES[t]:
				if m.contains(word):
					return true
	return false

## A database color as the game's paint entry.
static func to_game_paint(p: Dictionary) -> Dictionary:
	var c: Array = p["rgb"]
	var label: String = p["name"]
	var code := String(p.get("codes", "")).get_slice("/", 0)
	if code != "":
		label += " (%s)" % code
	return {"name": label, "color": c, "lower": c, "metallic": float(p.get("metallic", 0.3)),
		"code": p.get("codes", ""), "finish": p.get("finish", "solid"), "factory_db": true,
		"rgb_estimated": p.get("rgb_estimated", true), "near_year": p.get("near_year", false)}

## Game paints for a car: its own list plus database colors it doesn't already
## have (same name, or a near-identical color).
static func merged_game_paints(existing: Array, make: String, year: int, model: String) -> Array:
	var out := existing.duplicate()
	for p in paints_for(make, year, model):
		var gp := to_game_paint(p)
		var dup := false
		for e in out:
			var en := String(e.get("name", "")).to_lower()
			var ec: Array = e.get("color", [0, 0, 0])
			var dc: Array = gp["color"]
			var dist := Vector3(ec[0] - dc[0], ec[1] - dc[1], ec[2] - dc[2]).length()
			if en.begins_with(String(p["name"]).to_lower()) or String(p["name"]).to_lower().begins_with(en) or dist < 0.03:
				dup = true
				break
		if not dup:
			out.append(gp)
	return out
