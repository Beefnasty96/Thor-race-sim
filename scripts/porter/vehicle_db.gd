class_name VehicleDB
extends RefCounted
## Production car body dimensions for Car Porter's "Find a production car".
## Data: Transport Canada, Canadian Vehicle Specifications (CVS), via NHTSA's
## vPIC API (model years 1971 on). Contains information licensed under the
## Open Government Licence - Canada. Built by tools/vehicle_db/fetch_cvs.py.

const PATH := "res://data/vehicle_db/vehicle_dimensions.json"

static var _db: Dictionary = {}
static var _index: Dictionary = {}       # year -> make -> [row indices]

static func available() -> bool:
	return FileAccess.file_exists(PATH)

static func _load() -> void:
	if not _db.is_empty() or not available():
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not (d is Dictionary):
		return
	_db = d
	_index.clear()
	var rows: Array = _db.get("rows", [])
	for i in rows.size():
		var r: Array = rows[i]
		var y := int(r[0])
		var mk: String = r[1]
		if not _index.has(y):
			_index[y] = {}
		if not _index[y].has(mk):
			_index[y][mk] = []
		_index[y][mk].append(i)

static func source_note() -> String:
	_load()
	return "%s. %s." % [_db.get("source", "Canadian Vehicle Specifications"), _db.get("licence", "Open Government Licence - Canada")]

static func count() -> int:
	_load()
	return _db.get("rows", []).size()

## Model years with data, newest first.
static func years() -> Array:
	_load()
	var ys := _index.keys()
	ys.sort()
	ys.reverse()
	return ys

static func makes(year: int) -> Array:
	_load()
	var m: Array = _index.get(year, {}).keys()
	m.sort()
	return m

## Models for a year and make, optionally filtered by words in `query`
## (all words must appear). Returns row dictionaries.
static func models(year: int, make: String, query: String = "") -> Array:
	_load()
	var out := []
	var words := query.to_lower().split(" ", false)
	for i in _index.get(year, {}).get(make, []):
		var r := row_dict(i)
		var name: String = r["model"].to_lower()
		var ok := true
		for w in words:
			if not name.contains(w):
				ok = false
				break
		if ok:
			out.append(r)
	out.sort_custom(func(a, b): return a["model"] < b["model"])
	return out

static func row_dict(i: int) -> Dictionary:
	var r: Array = _db["rows"][i]
	var f: Array = _db["fields"]
	var d := {}
	for k in f.size():
		d[f[k]] = r[k]
	return d

## Readable model name ("TAHOE 4WD 4DR" -> "Tahoe 4WD 4DR"): words with
## digits or short all-caps codes stay as they are.
static func pretty(model: String) -> String:
	var out := []
	for w in model.split(" ", false):
		var has_digit := false
		for ch in w:
			if ch >= "0" and ch <= "9":
				has_digit = true
		var keep := has_digit or w.length() <= 3 or w.contains("/") or w.contains("-")
		out.append(w if keep else w.capitalize())
	return " ".join(out)
