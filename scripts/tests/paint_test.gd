extends SceneTree
## Checks recolouring photo paint: what counts as paint, the recolour, the
## touch-up mask and saving it.
##   godot --headless -s res://scripts/tests/paint_test.gd

var fails := 0

func _check(cond: bool, what: String) -> void:
	print(("  ok    " if cond else "  FAIL  ") + what)
	if not cond:
		fails += 1

func _initialize() -> void:
	var red := Color(0.62, 0.06, 0.05)
	var tol := PaintKey.DEFAULT_TOLERANCE
	_check(PaintKey.amount(red, red, tol) > 0.99, "the picked paint itself is paint")
	_check(PaintKey.amount(Color(0.25, 0.025, 0.02), red, tol) > 0.95, "the same red in shadow is paint")
	_check(PaintKey.amount(Color(0.85, 0.2, 0.18), red, tol) > 0.9, "the same red in bright light is paint")
	_check(PaintKey.amount(Color(0.1, 0.15, 0.5), red, tol) == 0.0, "blue glass is not paint")
	_check(PaintKey.amount(Color(0.02, 0.02, 0.02), red, tol) == 0.0, "black rubber / trim is not paint")
	_check(PaintKey.amount(Color(0.8, 0.8, 0.82), red, tol) == 0.0, "chrome is not paint")
	_check(PaintKey.amount(Color(0.98, 0.97, 0.96), red, tol) == 0.0, "a blown-out highlight is left alone")
	_check(PaintKey.amount(Color(0.6, 0.35, 0.05), red, tol) < 0.1, "an orange badge is not paint")
	_check(PaintKey.amount(Color(0.6, 0.35, 0.05), red, 0.6) > 0.5, "…unless the tolerance is opened right up")
	# recolour keeps light and shade
	var blue := Color(0.12, 0.2, 0.45)
	var lit := PaintKey.recolor(Color(0.62, 0.06, 0.05), red, tol, blue)
	var shade := PaintKey.recolor(Color(0.25, 0.025, 0.02), red, tol, blue)
	_check(lit.b > lit.r and shade.b > shade.r, "recoloured red paint comes out blue, lit and shaded")
	var ly := lit.r * 0.299 + lit.g * 0.587 + lit.b * 0.114
	var sy := shade.r * 0.299 + shade.g * 0.587 + shade.b * 0.114
	_check(absf(sy / ly - 0.4) < 0.03, "shading is kept (shadow stays 40%% of the lit paint: %.2f)" % (sy / ly))
	var glass := Color(0.1, 0.15, 0.5)
	_check(PaintKey.recolor(glass, red, tol, Color.WHITE).is_equal_approx(glass), "non-paint pixels keep their photo colour")
	# touch-ups
	_check(PaintKey.amount(red, red, tol, 0.0) == 0.0, "touch-up 'Not paint' wins over a match (a red sticker)")
	_check(PaintKey.amount(glass, red, tol, 1.0) == 1.0, "touch-up 'Paint' wins over a miss")
	_check(PaintKey.amount(red, red, tol, 0.5) > 0.99, "touch-up 'Automatic' leaves the match alone")
	var mk := PaintKey.blank_mask(100, 60)
	PaintKey.brush(mk, Vector2(50, 30), 10.0, 0.0)
	_check(mk.get_pixel(50, 30).r < 0.01 and mk.get_pixel(50, 39).r < 0.01 and absf(mk.get_pixel(50, 42).r - 0.5) < 0.01 and absf(mk.get_pixel(5, 5).r - 0.5) < 0.01, "the brush paints a round dab and nothing else")
	PaintKey.brush(mk, Vector2(98, 58), 10.0, 1.0)
	_check(mk.get_pixel(99, 59).r > 0.99, "brushing at the photo's edge is clamped safely")
	# white / black / silver cars
	var white := Color(0.88, 0.88, 0.86)
	_check(PaintKey.is_grey(white) and not PaintKey.is_grey(red), "white paint is flagged as having no hue")
	_check(PaintKey.amount(Color(0.8, 0.8, 0.79), white, tol) > 0.9, "white paint matches white paint")
	_check(PaintKey.amount(Color(0.05, 0.05, 0.05), white, tol) == 0.0, "black trim isn't white paint")
	# sampling
	var img := Image.create(40, 40, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.2, 0.2))
	img.fill_rect(Rect2i(10, 10, 20, 20), red)
	var smp := PaintKey.sample(img, Vector2i(20, 20), 4)
	_check(Vector3(smp.r - red.r, smp.g - red.g, smp.b - red.b).length() < 0.005, "sampling averages a patch of the paint")
	var smc := PaintKey.sample(img, Vector2i(0, 0), 4)
	_check(absf(smc.r - 0.2) < 0.005, "sampling at a corner stays on the photo")
	# project storage
	var p := PorterProject.create("paint test")
	_check(not p.has_paint_key(), "new projects have no paint colour picked")
	p.set_paint_key(red)
	p.paint_key["tolerance"] = 0.3
	p.import_image("side", img)
	var m2 := PaintKey.blank_mask(40, 40)
	PaintKey.brush(m2, Vector2(20, 20), 5.0, 0.0)
	p.save_paint_mask("side", m2)
	p.save()
	var p2 := PorterProject.load_project(p.id)
	_check(p2.has_paint_key() and p2.paint_key_color().is_equal_approx(Color(0.62, 0.06, 0.05)) and is_equal_approx(p2.paint_tolerance(), 0.3), "paint colour and tolerance save and load")
	var m3 := p2.load_paint_mask("side")
	_check(m3 != null and m3.get_pixel(20, 20).r < 0.01 and absf(m3.get_pixel(2, 2).r - 0.5) < 0.01, "touch-ups save and load")
	p2.import_image("side", img)
	_check(p2.load_paint_mask("side") == null, "loading a new photo drops the old photo's touch-ups")
	# the shaders compile
	for path in ["res://assets/shaders/photo_recolor.gdshader", "res://assets/shaders/photo_recolor_2d.gdshader"]:
		var sh: Shader = load(path)
		_check(sh != null and sh.get_shader_uniform_list().size() >= 6, "%s loads with its settings" % path.get_file())
	for f in DirAccess.get_files_at(p.dir()):
		DirAccess.remove_absolute(p.dir() + f)
	DirAccess.remove_absolute(p.dir())
	print("ALL PASSED (0 failed)" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails > 0 else 0)
