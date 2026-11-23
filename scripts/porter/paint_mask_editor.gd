class_name PaintMaskEditor
extends Control
## Touch-up for recolouring photo paint: one photo with what counts as paint
## tinted blue. One finger brushes (Not paint / Paint / Automatic), two
## fingers pinch-zoom and pan to reach small stickers and badges.

signal mask_changed                  # after each stroke (saved)

const SHADER := preload("res://assets/shaders/photo_recolor_2d.gdshader")

var project: PorterProject
var view_name := "side"
var brush_value := 0.0               # 0 not paint, 1 paint, 0.5 automatic
var brush_px := 40.0                 # brush radius on screen
var texture: Texture2D
var img_size := Vector2.ONE
var mask: Image
var mask_tex: ImageTexture
var mat: ShaderMaterial
var zoom := 1.0
var pan := Vector2.ZERO              # screen offset of the photo
var _touches := {}
var _start := {}
var _painting := false
var _dirty := false
var _last := Vector2(-1, -1)
var photo_rect: TextureRect           # the photo, through the mask shader
var overlay: Control                  # text + brush ring on top

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	custom_minimum_size = Vector2(0, 420)
	mat = ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("show_mask", true)
	photo_rect = TextureRect.new()
	photo_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	photo_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	photo_rect.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(photo_rect)
	overlay = Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.draw.connect(_draw_overlay)
	add_child(overlay)
	resized.connect(queue_redraw)

func setup(p: PorterProject, v: String) -> void:
	project = p
	view_name = v
	zoom = 1.0
	pan = Vector2.ZERO
	var img := project.load_photo(v)
	texture = ImageTexture.create_from_image(img) if img else null
	if img:
		img_size = Vector2(img.get_width(), img.get_height())
		mask = project.load_paint_mask(v)
		if mask == null or mask.get_size() != img.get_size():
			mask = PaintKey.blank_mask(img.get_width(), img.get_height())
		mask_tex = ImageTexture.create_from_image(mask)
		mat.set_shader_parameter("override_tex", mask_tex)
		mat.set_shader_parameter("has_override", true)
	photo_rect.texture = texture
	refresh_key()

func refresh_key() -> void:
	if project == null:
		return
	mat.set_shader_parameter("key_color", project.paint_key_color())
	mat.set_shader_parameter("tolerance", project.paint_tolerance())
	photo_rect.material = mat if project.has_paint_key() else null
	queue_redraw()

func queue_redraw_all() -> void:
	queue_redraw()

func clear() -> void:
	if mask == null:
		return
	mask.fill(Color(0.5, 0.5, 0.5))
	mask_tex.update(mask)
	project.clear_paint_mask(view_name)
	queue_redraw()
	mask_changed.emit()

func _base_k() -> float:
	return minf(size.x / img_size.x, size.y / img_size.y)

func _k() -> float:
	return _base_k() * zoom

func _ofs() -> Vector2:
	return (size - img_size * _base_k()) * 0.5 + pan

func _screen_to_px(s: Vector2) -> Vector2:
	return (s - _ofs()) / _k()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.05, 0.09))
	photo_rect.visible = texture != null
	if texture:
		photo_rect.position = _ofs()
		photo_rect.size = img_size * _k()
	overlay.queue_redraw()

func _draw_overlay() -> void:
	var font := get_theme_default_font()
	if texture == null:
		overlay.draw_string(font, Vector2(20, size.y * 0.5), "No %s photo." % view_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 24, UIKit.WARN)
		return
	if not project.has_paint_key():
		overlay.draw_string(font, Vector2(14, 28), "Pick the paint colour first (tap the paint on a photo).", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, UIKit.WARN)
		return
	var what := "Not paint" if brush_value < 0.25 else ("Paint" if brush_value > 0.75 else "Automatic")
	overlay.draw_string(font, Vector2(14, 28), "Blue = recoloured as paint. Brush: %s  ·  pinch to zoom" % what, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(1, 1, 1, 0.9))
	if _last.x >= 0.0:
		overlay.draw_arc(_last, brush_px, 0, TAU, 32, Color(1, 0.65, 0.15), 2.0, true)

func _stroke(s: Vector2) -> void:
	if mask == null:
		return
	PaintKey.brush(mask, _screen_to_px(s), brush_px / _k(), brush_value)
	mask_tex.update(mask)
	_dirty = true
	_last = s
	queue_redraw()

func _end_stroke() -> void:
	if _dirty:
		_dirty = false
		project.save_paint_mask(view_name, mask)
		mask_changed.emit()

func _gui_input(e: InputEvent) -> void:
	if texture == null or mask == null or not project.has_paint_key():
		return
	if e is InputEventScreenTouch:
		if e.pressed:
			_touches[e.index] = e.position
			if _touches.size() == 1:
				_painting = true
				_stroke(e.position)
			else:
				_painting = false
		else:
			_touches.erase(e.index)
			if _touches.is_empty():
				_end_stroke()
				_last = Vector2(-1, -1)
				queue_redraw()
		_start = {"t": _touches.duplicate(), "zoom": zoom, "pan": pan}
		accept_event()
	elif e is InputEventScreenDrag:
		_touches[e.index] = e.position
		var keys := _touches.keys()
		if keys.size() == 1 and _painting:
			_stroke(e.position)
		elif keys.size() >= 2:
			var st: Dictionary = _start.get("t", {})
			if st.has(keys[0]) and st.has(keys[1]):
				var m0: Vector2 = (st[keys[0]] + st[keys[1]]) * 0.5
				var m1: Vector2 = (_touches[keys[0]] + _touches[keys[1]]) * 0.5
				var k: float = (_touches[keys[1]] - _touches[keys[0]]).length() / maxf((st[keys[1]] - st[keys[0]]).length(), 1.0)
				var z0: float = _start["zoom"]
				zoom = clampf(z0 * k, 1.0, 8.0)
				# keep the photo point under the pinch centre under the fingers
				var base := (size - img_size * _base_k()) * 0.5
				var px := (m0 - base - Vector2(_start["pan"])) / (_base_k() * z0)
				pan = m1 - base - px * _base_k() * zoom
				queue_redraw()
		accept_event()
	elif e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom = clampf(zoom * 1.1, 1.0, 8.0)
			queue_redraw()
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom = clampf(zoom / 1.1, 1.0, 8.0)
			queue_redraw()
