class_name PorterProject
extends RefCounted
## A Car Porter project: the car's real dimensions and the reference photos
## (side, front, rear, top) aligned to a true-scale outline. Saved as
## user://porter/projects/<id>/project.json with the photos copied alongside.
##
## Blueprint frames (meters, y up on screen):
##   side  : x from the front bumper toward the rear (front on the left), y up from the ground
##   front : x across the car (screen right = car's left side), y up from the ground
##   rear  : x across the car (screen right = car's right side), y up from the ground
##   top   : x from the front bumper toward the rear, y across (screen up = car's right side)

const ROOT := "user://porter/projects/"
const VIEWS := ["side", "front", "rear", "top"]
## Interior photos (not part of the blueprint alignment):
##   dash     : taken from the driver's seat looking forward; frame = (x, y)
##              like the rear view (screen right = car's right), fitted to the
##              dash in the Interior screen
##   steering : the steering wheel face-on; cut out with a crop circle
##   door     : inside of the driver's door, face-on from the cabin; frame =
##              (-z, y) (forward to the right); both doors use it
##   pillar   : the driver's A-pillar from the seat; frame = (-|x|, y); both
##              pillars use it
##   ceiling  : headliner, phone overhead with its top toward the windshield;
##              frame = (-x, -z)
const INTERIOR_VIEWS := ["dash", "steering", "door", "pillar", "ceiling"]
const VIEW_LABELS := {"side": "Side", "front": "Front", "rear": "Rear", "top": "Top", "dash": "Dashboard",
	"steering": "Steering wheel", "door": "Inside door", "pillar": "A-pillar", "ceiling": "Ceiling"}
const IMAGE_MAX_PX := 2048        # photos are downscaled to this on import (phone memory)

var id := ""
var name := "New car"
var source_car := ""              # car id the dimensions were copied from, if any
var source_db := ""               # production car the dimensions came from (database), if any
var db_row := {}                  # that database row (keeps curb weight etc. for later specs)
var dims := {
	"length_m": 4.5, "width_m": 1.8, "height_m": 1.4, "wheelbase_m": 2.7,
	"front_overhang_m": 0.85, "track_front_m": 1.55, "track_rear_m": 1.55,
	"tire_radius_m": 0.32,           # front tire (from the tire size)
	"tire_radius_rear_m": 0.32,      # rear tire (same as front unless staggered)
}
## Tires entered when the car is created: sizes as printed on the placard and
## cold pressures in PSI.
var tires := {"front": "", "rear": "", "front_psi": 0.0, "rear_psi": 0.0}
## Wheel picture crops from the side photo, per axle: center and radius in
## photo pixels (cx, cy, r). "rear_same" reuses the front picture at the rear.
var wheels := {"front": {}, "rear": {}, "rear_same": true}
var units := "imperial"           # imperial | metric (display only; storage is meters)
var paint := {}                   # preview paint: {"color": [r,g,b], "lower": [r,g,b]}
## Per view: file, cx, cy (photo center in frame meters), mpp (meters per pixel),
## rot (radians), flip (mirror horizontally), opacity.
var views := {}
## Interior for the first-person view (all metres in the game's coordinates):
##   driver_eye : [x, y, z] the driver's eye ([] = default from the body size)
##   gauges     : [{type, x, y, z, r, max}] live gauges on the dash face; type
##                speedo / tach / fuel / temp / oil / volts; max = full-scale
##                mph or rpm (speedo / tach)
##   steering   : {diameter_m, thickness_m, tilt_deg, center: [x,y,z] or [],
##                crop: {cx, cy, r} in steering-photo pixels,
##                holes: [[[u, v], ...]] cut-outs in unit-circle coordinates
##                (u right, v down, as on the photo)}
var interior := {"driver_eye": [], "gauges": [], "steering": {}}

signal changed

func _init() -> void:
	for v in VIEWS + INTERIOR_VIEWS:
		views[v] = _blank_view()

static func _blank_view() -> Dictionary:
	return {"file": "", "cx": 0.0, "cy": 0.0, "mpp": 0.001, "rot": 0.0, "flip": false, "opacity": 0.85}

# ---------------------------------------------------------------- dimensions

## Copy real dimensions from a game car definition (data/cars/*.json).
func fill_from_car(def: Dictionary, body_key: String = "4door") -> void:
	var b: Dictionary = def["bodies"][body_key]
	dims["length_m"] = b["length_m"]
	dims["width_m"] = b["width_m"]
	dims["height_m"] = b["height_m"]
	dims["wheelbase_m"] = b["wheelbase_m"]
	dims["track_front_m"] = b["track_front_m"]
	dims["track_rear_m"] = b["track_rear_m"]
	dims["tire_radius_m"] = def["tires"]["radius_m"]
	dims["tire_radius_rear_m"] = def["tires"]["radius_m"]
	var spec := TireSpec.find_in(String(def["tires"].get("size", "")))
	var fp: float = def["tires"].get("placard_psi_front", def["tires"].get("cold_pressure_psi", 0.0))
	var rp: float = def["tires"].get("placard_psi_rear", fp)
	if not spec.is_empty():
		set_tires(spec["size"], spec["size"], fp, rp)
	# overhangs aren't in the car file; split the remainder 45/55 front/rear as a start
	dims["front_overhang_m"] = snappedf((b["length_m"] - b["wheelbase_m"]) * 0.45, 0.005)
	source_car = def["id"]
	var paints: Array = def.get("paints", [])
	if not paints.is_empty() and paint.is_empty():
		paint = {"color": paints[0]["color"], "lower": paints[0].get("lower", paints[0]["color"])}
	if name == "New car":
		name = "%d %s %s %s" % [def["year"], def["make"], def["model"], b.get("label", body_key)]

## Copy dimensions from a production-car database row (VehicleDB.row_dict).
## Missing track or overhang values are estimated from width and length.
func fill_from_db(r: Dictionary) -> void:
	dims["length_m"] = r["length_m"]
	dims["width_m"] = r["width_m"]
	dims["height_m"] = r["height_m"]
	dims["wheelbase_m"] = r["wheelbase_m"]
	var tf: float = r.get("track_front_m", 0.0)
	var tr: float = r.get("track_rear_m", 0.0)
	dims["track_front_m"] = tf if tf > 0.5 else snappedf(r["width_m"] * 0.86, 0.005)
	dims["track_rear_m"] = tr if tr > 0.5 else dims["track_front_m"]
	var fo: float = r.get("front_overhang_m", 0.0)
	var spare: float = r["length_m"] - r["wheelbase_m"]
	dims["front_overhang_m"] = fo if (fo > 0.2 and fo < spare) else snappedf(spare * 0.45, 0.005)
	# CVS has no tire size: placeholder radius until the tires are entered
	dims["tire_radius_m"] = snappedf(clampf(r["height_m"] * 0.22, 0.28, 0.42), 0.005)
	dims["tire_radius_rear_m"] = dims["tire_radius_m"]
	source_car = ""
	source_db = "%d %s %s" % [r["year"], r["make"], VehicleDB.pretty(r["model"])]
	db_row = r.duplicate()
	if name == "New car":
		name = source_db

## Set the tire sizes and pressures; wheel radii follow the sizes.
## Returns "" or a message saying what's wrong.
func set_tires(front: String, rear: String, front_psi: float, rear_psi: float) -> String:
	var f := TireSpec.parse(front)
	if f.is_empty():
		return "Front tire size not recognized. Use the size on the sidewall or door sticker, e.g. P245/75R16."
	var r := f if rear.strip_edges() == "" else TireSpec.parse(rear)
	if r.is_empty():
		return "Rear tire size not recognized."
	if front_psi < 10 or front_psi > 90 or rear_psi < 10 or rear_psi > 90:
		return "Tire pressures should be between 10 and 90 PSI."
	tires = {"front": f["size"], "rear": r["size"], "front_psi": front_psi, "rear_psi": rear_psi,
		"front_width_m": f["width_m"], "rear_width_m": r["width_m"],
		"front_rim_in": f["rim_in"], "rear_rim_in": r["rim_in"]}
	dims["tire_radius_m"] = f["radius_m"]
	dims["tire_radius_rear_m"] = r["radius_m"]
	return ""

func has_tires() -> bool:
	return tires.get("front", "") != ""

## Tire radius at the front or rear axle.
func tire_radius(rear_axle: bool) -> float:
	return dims.get("tire_radius_rear_m", dims["tire_radius_m"]) if rear_axle else dims["tire_radius_m"]

## Rim (bead seat) radius from the tire size; ~52% of the tire radius if unknown.
func rim_radius(rear_axle: bool) -> float:
	var rim_in := float(tires.get("rear_rim_in" if rear_axle else "front_rim_in", 0.0))
	return rim_in * 0.0254 * 0.5 if rim_in > 0.0 else tire_radius(rear_axle) * 0.525

## Rim radius as a fraction of the tire radius (the blue circle in the crop).
func rim_fraction(rear_axle: bool) -> float:
	return clampf(rim_radius(rear_axle) / tire_radius(rear_axle), 0.3, 0.95)

func front_axle_x() -> float:
	return dims["front_overhang_m"]

func rear_axle_x() -> float:
	return dims["front_overhang_m"] + dims["wheelbase_m"]

## Outline of the true-scale frame for a view: width and height in meters.
func frame_size(view: String) -> Vector2:
	match view:
		"side":
			return Vector2(dims["length_m"], dims["height_m"])
		"top":
			return Vector2(dims["length_m"], dims["width_m"])
		_:
			return Vector2(dims["width_m"], dims["height_m"])

## Frame-space origin offset so the outline sits centerd: returns the frame
## rect (position = lower-left corner in frame meters, size).
func frame_rect(view: String) -> Rect2:
	var s := frame_size(view)
	match view:
		"side":
			return Rect2(0, 0, s.x, s.y)
		"top":
			return Rect2(0, -s.y * 0.5, s.x, s.y)
		_:
			return Rect2(-s.x * 0.5, 0, s.x, s.y)

# ---------------------------------------------------------------- two-point align

## The two reference points the user taps for each view, with their true
## positions in frame meters.
func align_targets(view: String) -> Array:
	match view:
		"side":
			return [
				{"label": "the FRONT wheel center", "pos": Vector2(front_axle_x(), tire_radius(false))},
				{"label": "the REAR wheel center", "pos": Vector2(rear_axle_x(), tire_radius(true))},
			]
		"front":
			var t: float = dims["track_front_m"] * 0.5
			return [
				{"label": "the bottom middle of the tire on the LEFT of the photo (where it meets the ground)", "pos": Vector2(-t, 0.0)},
				{"label": "the bottom middle of the tire on the RIGHT of the photo", "pos": Vector2(t, 0.0)},
			]
		"rear":
			var t2: float = dims["track_rear_m"] * 0.5
			return [
				{"label": "the bottom middle of the tire on the LEFT of the photo (where it meets the ground)", "pos": Vector2(-t2, 0.0)},
				{"label": "the bottom middle of the tire on the RIGHT of the photo", "pos": Vector2(t2, 0.0)},
			]
		_:
			return [
				{"label": "the middle of the FRONT bumper", "pos": Vector2(0.0, 0.0)},
				{"label": "the middle of the REAR bumper", "pos": Vector2(dims["length_m"], 0.0)},
			]

## Photo pixel → frame meters, with the view's current transform.
func image_to_frame(view: String, px: Vector2, img_size: Vector2) -> Vector2:
	var v: Dictionary = views[view]
	var local := _local(px, img_size, v["flip"]) * float(v["mpp"])
	return Vector2(v["cx"], v["cy"]) + local.rotated(v["rot"])

## Frame meters → photo pixel (inverse of image_to_frame).
func frame_to_image(view: String, p: Vector2, img_size: Vector2) -> Vector2:
	var v: Dictionary = views[view]
	var local := (p - Vector2(v["cx"], v["cy"])).rotated(-float(v["rot"])) / float(v["mpp"])
	var x := local.x * (-1.0 if v["flip"] else 1.0)
	return Vector2(x + img_size.x * 0.5, img_size.y * 0.5 - local.y)

static func _local(px: Vector2, img_size: Vector2, flip: bool) -> Vector2:
	var x := px.x - img_size.x * 0.5
	if flip:
		x = -x
	return Vector2(x, img_size.y * 0.5 - px.y)

## Solve the photo transform so pixel a lands on target ta and pixel b on tb
## (scale + rotation + offset; flip is kept).
func align_two_points(view: String, a_px: Vector2, b_px: Vector2, img_size: Vector2) -> bool:
	var tg := align_targets(view)
	var ta: Vector2 = tg[0]["pos"]
	var tb: Vector2 = tg[1]["pos"]
	var v: Dictionary = views[view]
	var la := _local(a_px, img_size, v["flip"])
	var lb := _local(b_px, img_size, v["flip"])
	var d_img := lb - la
	var d_frame := tb - ta
	if d_img.length() < 4.0:
		return false              # taps too close together to be meaningful
	var mpp := d_frame.length() / d_img.length()
	var rot := d_frame.angle() - d_img.angle()
	rot = wrapf(rot, -PI, PI)
	v["mpp"] = mpp
	v["rot"] = rot
	var c := ta - (la * mpp).rotated(rot)
	v["cx"] = c.x
	v["cy"] = c.y
	changed.emit()
	return true

## Rough starting fit: scale the photo so its width spans the frame, centerd.
func fit_to_frame(view: String, img_size: Vector2) -> void:
	var r := frame_rect(view)
	var v: Dictionary = views[view]
	v["mpp"] = r.size.x / maxf(img_size.x, 1.0) * 1.1
	v["rot"] = 0.0
	var c := r.get_center()
	v["cx"] = c.x
	v["cy"] = c.y
	changed.emit()

# ---------------------------------------------------------------- storage

func dir() -> String:
	return ROOT + id + "/"

static func slug(s: String) -> String:
	var out := ""
	for ch in s.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
		elif not out.ends_with("_"):
			out += "_"
	return out.strip_edges().trim_suffix("_").trim_prefix("_")

static func create(project_name: String) -> PorterProject:
	var p := PorterProject.new()
	p.name = project_name
	var base := slug(project_name)
	if base == "":
		base = "car"
	var candidate := base
	var n := 2
	while DirAccess.dir_exists_absolute(ROOT + candidate):
		candidate = "%s_%d" % [base, n]
		n += 1
	p.id = candidate
	DirAccess.make_dir_recursive_absolute(p.dir())
	return p

func to_dict() -> Dictionary:
	return {"format": 1, "id": id, "name": name, "source_car": source_car,
		"units": units, "dims": dims, "views": views, "paint": paint,
		"source_db": source_db, "db_row": db_row, "tires": tires, "wheels": wheels,
		"interior": interior}

func save() -> bool:
	DirAccess.make_dir_recursive_absolute(dir())
	var f := FileAccess.open(dir() + "project.json", FileAccess.WRITE)
	if f == null:
		push_error("Car Porter: cannot write " + dir())
		return false
	f.store_string(JSON.stringify(to_dict(), "  "))
	return true

static func load_project(project_id: String) -> PorterProject:
	var path := ROOT + project_id + "/project.json"
	if not FileAccess.file_exists(path):
		return null
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (d is Dictionary):
		return null
	var p := PorterProject.new()
	p.id = project_id
	p.name = d.get("name", project_id)
	p.source_car = d.get("source_car", "")
	p.units = d.get("units", "imperial")
	p.paint = d.get("paint", {})
	p.source_db = d.get("source_db", "")
	p.db_row = d.get("db_row", {})
	p.tires = d.get("tires", p.tires)
	p.wheels = d.get("wheels", p.wheels)
	var inn: Dictionary = d.get("interior", {})
	for k in inn:
		p.interior[k] = inn[k]
	if not d.get("dims", {}).has("tire_radius_rear_m"):
		p.dims["tire_radius_rear_m"] = p.dims["tire_radius_m"]      # projects saved before staggered tires
	for k in d.get("dims", {}):
		p.dims[k] = float(d["dims"][k])
	for v in VIEWS + INTERIOR_VIEWS:
		var src: Dictionary = d.get("views", {}).get(v, {})
		for k in src:
			p.views[v][k] = src[k]
	return p

## All saved projects, newest first: [{id, name, modified}].
static func list_projects() -> Array:
	var out := []
	var da := DirAccess.open(ROOT)
	if da == null:
		return out
	for sub in da.get_directories():
		var path := ROOT + sub + "/project.json"
		if FileAccess.file_exists(path):
			var d = JSON.parse_string(FileAccess.get_file_as_string(path))
			out.append({"id": sub, "name": (d.get("name", sub) if d is Dictionary else sub),
				"modified": FileAccess.get_modified_time(path)})
	out.sort_custom(func(a, b): return a["modified"] > b["modified"])
	return out

# ---------------------------------------------------------------- photos

## Decode image bytes (PNG / JPEG / WebP, sniffed from the header).
static func decode_image(bytes: PackedByteArray) -> Image:
	if bytes.size() < 12:
		return null
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes[0] == 0x89 and bytes[1] == 0x50:
		err = img.load_png_from_buffer(bytes)
	elif bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = img.load_jpg_from_buffer(bytes)
	elif bytes[8] == 0x57 and bytes[9] == 0x45 and bytes[10] == 0x42 and bytes[11] == 0x50:
		err = img.load_webp_from_buffer(bytes)
	return img if err == OK else null

## Import a photo for a view from a path (a content:// URI on Android works
## too). Stores a downscaled PNG copy in the project folder and fits it.
func import_photo(view: String, path: String) -> String:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return "Couldn't read that file."
	var img := decode_image(bytes)
	if img == null:
		return "That file isn't a PNG, JPEG or WebP image."
	return import_image(view, img)

func import_image(view: String, img: Image) -> String:
	var longest := maxi(img.get_width(), img.get_height())
	if longest > IMAGE_MAX_PX:
		var k := float(IMAGE_MAX_PX) / longest
		img.resize(maxi(1, int(img.get_width() * k)), maxi(1, int(img.get_height() * k)), Image.INTERPOLATE_LANCZOS)
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var file := view + ".png"
	DirAccess.make_dir_recursive_absolute(dir())
	if img.save_png(dir() + file) != OK:
		return "Couldn't save the photo."
	views[view]["file"] = file
	fit_to_frame(view, Vector2(img.get_width(), img.get_height()))
	save()
	return ""

func load_photo(view: String) -> Image:
	var file: String = views[view]["file"]
	if file == "" or not FileAccess.file_exists(dir() + file):
		return null
	return Image.load_from_file(ProjectSettings.globalize_path(dir() + file))

func photo_count() -> int:
	var n := 0
	for v in VIEWS:
		if views[v]["file"] != "":
			n += 1
	return n

# ---------------------------------------------------------------- body model

func has_mesh() -> bool:
	return FileAccess.file_exists(dir() + "body.json")

func save_mesh(m: HalfMesh) -> bool:
	DirAccess.make_dir_recursive_absolute(dir())
	var f := FileAccess.open(dir() + "body.json", FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(m.to_dict()))
	return true

func load_mesh() -> HalfMesh:
	if not has_mesh():
		return null
	var d = JSON.parse_string(FileAccess.get_file_as_string(dir() + "body.json"))
	return HalfMesh.from_dict(d) if d is Dictionary else null

# ---------------------------------------------------------------- interior

func has_dash() -> bool:
	return FileAccess.file_exists(dir() + "dash.json")

func save_dash(m: HalfMesh) -> bool:
	DirAccess.make_dir_recursive_absolute(dir())
	var f := FileAccess.open(dir() + "dash.json", FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(m.to_dict()))
	return true

func load_dash() -> HalfMesh:
	if not has_dash():
		return null
	var d = JSON.parse_string(FileAccess.get_file_as_string(dir() + "dash.json"))
	return HalfMesh.from_dict(d) if d is Dictionary else null

## The driver's eye (left-hand drive): saved, or behind the windshield, left
## of center, from the body size.
func driver_eye() -> Vector3:
	var e: Array = interior.get("driver_eye", [])
	if e.size() == 3:
		return Vector3(e[0], e[1], e[2])
	return Vector3(-dims["width_m"] * 0.2, dims["height_m"] * 0.68, -dims["wheelbase_m"] * 0.12)

func set_driver_eye(p: Vector3) -> void:
	interior["driver_eye"] = [snappedf(p.x, 0.001), snappedf(p.y, 0.001), snappedf(p.z, 0.001)]

const STEERING_DEFAULTS := {"diameter_m": 0.40, "thickness_m": 0.03, "tilt_deg": 22.0}

## Steering wheel settings with defaults filled in.
func steering() -> Dictionary:
	var s: Dictionary = interior.get("steering", {})
	for k in STEERING_DEFAULTS:
		if not s.has(k):
			s[k] = STEERING_DEFAULTS[k]
	if not s.has("holes"):
		s["holes"] = []
	if not s.has("crop"):
		s["crop"] = {}
	interior["steering"] = s
	return s

## Where the steering wheel hub sits: saved, or ~50 cm ahead of and 30 cm
## below the driver's eye.
func steering_center() -> Vector3:
	var c: Array = steering().get("center", [])
	if c.size() == 3:
		return Vector3(c[0], c[1], c[2])
	var e := driver_eye()
	return Vector3(e.x, e.y - 0.30, e.z - 0.50)

func set_steering_center(p: Vector3) -> void:
	steering()["center"] = [snappedf(p.x, 0.001), snappedf(p.y, 0.001), snappedf(p.z, 0.001)]

## Default crop circle for the steering photo: centered, 45% of the short side.
func steering_crop() -> Dictionary:
	var c: Dictionary = steering()["crop"]
	if c.is_empty():
		var img := load_photo("steering")
		if img == null:
			return {}
		c = {"cx": img.get_width() * 0.5, "cy": img.get_height() * 0.5, "r": mini(img.get_width(), img.get_height()) * 0.45}
	return c

const STEERING_TEX_PX := 512

## Cut the steering wheel picture (inside the crop circle) out of its photo.
func make_steering_texture() -> Image:
	var src := load_photo("steering")
	var c := steering_crop()
	if src == null or c.is_empty():
		return null
	var n := STEERING_TEX_PX
	var out := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var cx: float = c["cx"]
	var cy: float = c["cy"]
	var r: float = c["r"]
	var dark := Color(0.08, 0.08, 0.085)
	for y in n:
		for x in n:
			var sx := cx + ((x + 0.5) / n * 2.0 - 1.0) * r
			var sy := cy + ((y + 0.5) / n * 2.0 - 1.0) * r
			if sx < 0 or sy < 0 or sx >= src.get_width() or sy >= src.get_height():
				out.set_pixel(x, y, dark)
			else:
				out.set_pixel(x, y, src.get_pixel(int(sx), int(sy)))
	out.save_png(dir() + "steering_wheel.png")
	return out

## The interior part of the game's model_info.json (what export will write):
## driver_eye, steering_wheel_pivot, steering_rake_deg and the gauge cluster.
## Gauges carry their size and full scale; the cluster tilt is 0 because each
## gauge already sits on the dash face. Only gauges on the dash are written,
## and only the first of each type (the game has one needle per reading).
func interior_model_info() -> Dictionary:
	var e := driver_eye()
	var s := steering()
	var c := steering_center()
	var cluster := {"tilt_deg": 0}
	for g in interior.get("gauges", []):
		if not g.get("on_dash", true) or cluster.has(g["type"]):
			continue
		var entry := {"pos": [g["x"], g["y"], g["z"]], "r": g["r"]}
		if g["type"] in ["speedo", "tach"]:
			entry["max"] = g["max"]
		cluster[g["type"]] = entry
	return {"driver_eye": [e.x, e.y, e.z], "steering_wheel_pivot": [c.x, c.y, c.z],
		"steering_rake_deg": s["tilt_deg"], "steering_diameter_m": s["diameter_m"], "cluster": cluster}

func load_steering_texture() -> Image:
	var f := dir() + "steering_wheel.png"
	if not FileAccess.file_exists(f):
		return null
	return Image.load_from_file(ProjectSettings.globalize_path(f))

# ---------------------------------------------------------------- wheels

const WHEEL_TEX_PX := 256

## Where a wheel sits in the side photo, from the photo alignment and the
## tire size: {cx, cy, r} in photo pixels, or {} without a side photo.
func wheel_auto_crop(rear_axle: bool) -> Dictionary:
	var img := load_photo("side")
	if img == null:
		return {}
	var sz := Vector2(img.get_width(), img.get_height())
	var r := tire_radius(rear_axle)
	var x := rear_axle_x() if rear_axle else front_axle_x()
	var c := frame_to_image("side", Vector2(x, r), sz)
	return {"cx": c.x, "cy": c.y, "r": r / float(views["side"]["mpp"])}

func wheel_crop(rear_axle: bool) -> Dictionary:
	var key := "rear" if rear_axle and not wheels.get("rear_same", true) else "front"
	var c: Dictionary = wheels.get(key, {})
	if c.is_empty():
		c = wheel_auto_crop(key == "rear")
	return c

## Cut the rim picture out of the side photo (square, WHEEL_TEX_PX) and save
## it as wheel_front.png / wheel_rear.png. Only the rim is kept (the blue
## circle inside the tire edge): the game builds the tire itself so it can
## squash and flex. Outside the rim is filled with dark rubber.
func make_wheel_texture(rear_axle: bool) -> Image:
	var src := load_photo("side")
	var c := wheel_crop(rear_axle)
	if src == null or c.is_empty():
		return null
	var n := WHEEL_TEX_PX
	var out := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var rubber := WheelBuilder.RUBBER
	var cx: float = c["cx"]
	var cy: float = c["cy"]
	var r: float = float(c["r"]) * rim_fraction(rear_axle)
	var flip: bool = views["side"]["flip"]
	for y in n:
		for x in n:
			var u := (x + 0.5) / n * 2.0 - 1.0
			var v := (y + 0.5) / n * 2.0 - 1.0
			if u * u + v * v > 1.0:
				out.set_pixel(x, y, rubber)
				continue
			var sx := cx + (-u if flip else u) * r
			var sy := cy + v * r
			if sx < 0 or sy < 0 or sx >= src.get_width() or sy >= src.get_height():
				out.set_pixel(x, y, rubber)
			else:
				out.set_pixel(x, y, src.get_pixel(int(sx), int(sy)))
	out.save_png(dir() + ("wheel_rear.png" if rear_axle else "wheel_front.png"))
	return out

func load_wheel_texture(rear_axle: bool) -> Image:
	var f := dir() + ("wheel_rear.png" if rear_axle else "wheel_front.png")
	if not FileAccess.file_exists(f):
		return null
	return Image.load_from_file(ProjectSettings.globalize_path(f))
