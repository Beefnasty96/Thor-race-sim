class_name WheelCropView
extends Control
## Shows the side photo around one wheel with the tire-edge circle (orange,
## line it up with the tire) and the rim circle inside it (blue, from the tire
## size): only the rim is cut out; the game renders the tire. Drag to move,
## pinch / mouse wheel to resize.

signal crop_changed(final: bool)

var project: PorterProject
var rear := false
var crop := {}                 # cx, cy, r in photo pixels
var texture: Texture2D
var img_size := Vector2.ONE
var _touches := {}
var _start := {}

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	custom_minimum_size = Vector2(0, 420)

func setup(p: PorterProject, rear_axle: bool, photo: Image) -> void:
	project = p
	rear = rear_axle
	if photo:
		texture = ImageTexture.create_from_image(photo)
		img_size = Vector2(photo.get_width(), photo.get_height())
	crop = project.wheel_crop(rear).duplicate()
	queue_redraw()

## Screen pixels per photo pixel: the crop circle fills ~70% of the height.
func _scale() -> float:
	return size.y * 0.35 / maxf(float(crop.get("r", 1.0)), 1.0)

func _photo_to_screen(p: Vector2) -> Vector2:
	return size * 0.5 + (p - Vector2(crop["cx"], crop["cy"])) * _scale()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.05, 0.09))
	if texture == null or crop.is_empty():
		draw_string(get_theme_default_font(), Vector2(20, size.y * 0.5), "Add and align a side photo first.", HORIZONTAL_ALIGNMENT_LEFT, -1, 26, UIKit.WARN)
		return
	var a := _photo_to_screen(Vector2.ZERO)
	var b := _photo_to_screen(img_size)
	draw_texture_rect(texture, Rect2(a, b - a), false)
	var c := size * 0.5
	var r: float = float(crop["r"]) * _scale()
	var rr := r * project.rim_fraction(rear)
	# shade the tire band: it is not part of the picture
	draw_arc(c, (r + rr) * 0.5, 0, TAU, 64, Color(0, 0, 0, 0.45), r - rr, true)
	draw_arc(c, r, 0, TAU, 64, Color(1.0, 0.72, 0.2), 3.0, true)
	draw_arc(c, rr, 0, TAU, 64, Color(0.32, 0.72, 1.0), 3.0, true)
	draw_line(c - Vector2(14, 0), c + Vector2(14, 0), Color(1.0, 0.72, 0.2), 2.0)
	draw_line(c - Vector2(0, 14), c + Vector2(0, 14), Color(1.0, 0.72, 0.2), 2.0)
	var f := get_theme_default_font()
	draw_string(f, Vector2(16, 34), ("REAR" if rear else "FRONT") +  " WHEEL  ·  line orange up with the tire edge  ·  blue = rim picture", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(1, 1, 1, 0.85))

func _gui_input(e: InputEvent) -> void:
	if crop.is_empty():
		return
	if e is InputEventScreenTouch:
		if e.pressed:
			_touches[e.index] = e.position
		else:
			_touches.erase(e.index)
			if _touches.is_empty():
				crop_changed.emit(true)
		_start = {"t": _touches.duplicate(), "crop": crop.duplicate(), "scale": _scale()}
		accept_event()
	elif e is InputEventScreenDrag:
		_touches[e.index] = e.position
		var st: Dictionary = _start.get("t", {})
		var keys := _touches.keys()
		var c0: Dictionary = _start["crop"]
		if keys.size() == 1 and st.has(keys[0]):
			# the photo follows the finger; the circle stays in the middle
			var d: Vector2 = (_touches[keys[0]] - st[keys[0]]) / float(_start["scale"])
			crop["cx"] = float(c0["cx"]) - d.x
			crop["cy"] = float(c0["cy"]) - d.y
		elif keys.size() >= 2 and st.has(keys[0]) and st.has(keys[1]):
			var k: float = (_touches[keys[1]] - _touches[keys[0]]).length() / maxf((st[keys[1]] - st[keys[0]]).length(), 1.0)
			crop["r"] = clampf(float(c0["r"]) * k, 4.0, 4000.0)
		queue_redraw()
		crop_changed.emit(false)
		accept_event()
	elif e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			nudge_size(1.02)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			nudge_size(1.0 / 1.02)

func nudge_size(k: float) -> void:
	crop["r"] = float(crop["r"]) * k
	queue_redraw()
	crop_changed.emit(true)

func nudge_move(dx: float, dy: float) -> void:
	var px := 2.0 / _scale()
	crop["cx"] = float(crop["cx"]) + dx * px
	crop["cy"] = float(crop["cy"]) + dy * px
	queue_redraw()
	crop_changed.emit(true)
