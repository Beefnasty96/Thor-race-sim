class_name CarFinder
extends VBoxContainer
## "Find a production car": pick year → make → model from the dimension
## database, check the numbers, then start a project with them filled in.

signal chosen(row: Dictionary)
signal cancelled

var year := 0
var make := ""
var row := {}
var year_list: VBoxContainer
var make_list: VBoxContainer
var model_list: VBoxContainer
var search: LineEdit
var details: Label
var create_btn: Button
var units := "imperial"

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 10)
	var top := HBoxContainer.new()
	top.add_child(PorterUI.button("◀ Back", func(): cancelled.emit(), 160))
	var t := UIKit.label("FIND A PRODUCTION CAR", 34, Color.WHITE)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(t)
	top.add_child(PorterUI.button("in / mm", func():
		units = "metric" if units == "imperial" else "imperial"
		_show_details(), 150))
	add_child(top)
	if not VehicleDB.available():
		add_child(UIKit.label("The car database isn't in this build yet.", 26, UIKit.WARN))
		return
	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 14)
	add_child(cols)
	year_list = _column(cols, "YEAR", 170)
	make_list = _column(cols, "MAKE", 330)
	var mcol := VBoxContainer.new()
	mcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mcol.add_theme_constant_override("separation", 8)
	cols.add_child(mcol)
	mcol.add_child(UIKit.label("MODEL", 22, UIKit.ACCENT))
	search = LineEdit.new()
	search.placeholder_text = "Search, e.g. tahoe 4dr"
	search.custom_minimum_size = Vector2(0, 64)
	search.clear_button_enabled = true
	search.text_changed.connect(func(_t): _fill_models())
	mcol.add_child(search)
	model_list = _scroll_list(mcol)
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(560, 0)
	right.add_theme_constant_override("separation", 12)
	cols.add_child(right)
	right.add_child(UIKit.label("DIMENSIONS", 22, UIKit.ACCENT))
	details = UIKit.label("Pick a year, make and model.", 24, UIKit.DIM)
	details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(details)
	create_btn = PorterUI.button("Start project with these ▶", func(): chosen.emit(row))
	create_btn.disabled = true
	create_btn.add_theme_color_override("font_color", UIKit.GOOD)
	right.add_child(create_btn)
	var src := UIKit.label("%d models · Source: %s" % [VehicleDB.count(), VehicleDB.source_note()], 18, UIKit.DIM)
	src.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(src)
	for y in VehicleDB.years():
		var yy: int = y
		year_list.add_child(_item(str(yy), func(): _pick_year(yy)))

func _column(parent: Control, title: String, w: float) -> VBoxContainer:
	var c := VBoxContainer.new()
	c.custom_minimum_size = Vector2(w, 0)
	c.add_theme_constant_override("separation", 8)
	parent.add_child(c)
	c.add_child(UIKit.label(title, 22, UIKit.ACCENT))
	return _scroll_list(c)

func _scroll_list(parent: Control) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.scroll_deadzone = 24            # a finger drag scrolls instead of pressing
	parent.add_child(sc)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 6)
	sc.add_child(v)
	return v

func _item(text: String, cb: Callable) -> Button:
	var b := PorterUI.button(text, cb)
	b.custom_minimum_size.y = 64
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	b.toggle_mode = true
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return b

func _mark(list: VBoxContainer, text: String) -> void:
	for b in list.get_children():
		(b as Button).set_pressed_no_signal(b.text == text)

func _pick_year(y: int) -> void:
	year = y
	make = ""
	row = {}
	_mark(year_list, str(y))
	for c in make_list.get_children():
		c.queue_free()
	for c in model_list.get_children():
		c.queue_free()
	for m in VehicleDB.makes(y):
		var mk: String = m
		make_list.add_child(_item(mk, func(): _pick_make(mk)))
	_show_details()

func _pick_make(m: String) -> void:
	make = m
	row = {}
	_mark(make_list, m)
	_fill_models()
	_show_details()

func _fill_models() -> void:
	if model_list == null:
		return
	for c in model_list.get_children():
		c.queue_free()
	if make == "":
		return
	for r in VehicleDB.models(year, make, search.text):
		var rr: Dictionary = r
		var b := _item(VehicleDB.pretty(rr["model"]), func(): _pick_model(rr))
		model_list.add_child(b)

func _pick_model(r: Dictionary) -> void:
	row = r
	_mark(model_list, VehicleDB.pretty(r["model"]))
	_show_details()

func _show_details() -> void:
	if details == null:
		return
	if row.is_empty():
		details.text = "Pick a year, make and model." if make == "" else "Pick a model."
		create_btn.disabled = true
		return
	var L := func(m: float) -> String:
		return PorterUI.fmt_len(m, units) if m > 0.0 else "n/a"
	var lines := [
		"%d %s" % [row["year"], row["make"]],
		VehicleDB.pretty(row["model"]),
		"",
		"Length         %s" % L.call(row["length_m"]),
		"Width          %s" % L.call(row["width_m"]),
		"Height         %s" % L.call(row["height_m"]),
		"Wheelbase      %s" % L.call(row["wheelbase_m"]),
		"Front track    %s" % L.call(row["track_front_m"]),
		"Rear track     %s" % L.call(row["track_rear_m"]),
		"Front overhang %s" % L.call(row["front_overhang_m"]),
		"Rear overhang  %s" % L.call(row["rear_overhang_m"]),
	]
	if row.get("curb_kg") != null and float(row["curb_kg"]) > 0:
		var kg := float(row["curb_kg"])
		lines.append("Curb weight    %s" % ("%d kg" % kg if units == "metric" else "%d lb" % roundi(kg / 0.4536)))
	details.text = "\n".join(lines)
	details.add_theme_color_override("font_color", Color.WHITE)
	create_btn.disabled = false
