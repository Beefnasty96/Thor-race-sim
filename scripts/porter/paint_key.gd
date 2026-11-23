class_name PaintKey
extends RefCounted
## Which photo pixels are the car's paint, and recolouring them: the same
## maths as assets/shaders/photo_recolor.gdshader (preview) for export and
## tests. A pixel is paint when its hue/chroma, relative to its brightness, is
## within `tolerance` of the sampled paint colour, so the shaded and lit parts
## of the paint match too. The touch-up mask (per photo, R channel) forces
## pixels: 1 = paint, 0 = not paint, 0.5 = automatic.

const DEFAULT_TOLERANCE := 0.22

## luma, Cb, Cr of a colour.
static func ycc(c: Color) -> Vector3:
	var y := c.r * 0.299 + c.g * 0.587 + c.b * 0.114
	return Vector3(y, (c.b - y) * 0.564, (c.r - y) * 0.713)

## How far a pixel's colour is from the paint: hue angle (stable from shadow
## to sunlit), plus a softer saturation term; for white / black / silver
## paint (no hue) brightness instead.
static func distance(c: Color, key: Color) -> float:
	var a := ycc(c)
	var k := ycc(key)
	var ca := Vector2(a.y, a.z)
	var ck := Vector2(k.y, k.z)
	var sat_a := ca.length() / (a.x + 0.02)
	var sat_k := ck.length() / (k.x + 0.02)
	var grey := 1.0 - _smooth(0.08, 0.2, sat_k)
	var dang := absf(wrapf(ca.angle() - ck.angle(), -PI, PI))
	var d := (1.0 - grey) * (dang * 0.5 + absf(log((sat_a + 0.02) / (sat_k + 0.02))) * 0.15)
	d += grey * (1.6 * absf(a.x - k.x) + 0.8 * maxf(sat_a - 0.15, 0.0))
	return d

static func _smooth(e0: float, e1: float, x: float) -> float:
	var t := clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

## 0..1 how much this pixel is paint. override: -1 = none, else the mask value.
static func amount(c: Color, key: Color, tolerance: float, override: float = -1.0) -> float:
	if override > 0.75:
		return 1.0
	if override >= 0.0 and override < 0.25:
		return 0.0
	var y := c.r * 0.299 + c.g * 0.587 + c.b * 0.114
	var m := 1.0 - _smooth(tolerance * 0.7, tolerance, distance(c, key))
	m *= _smooth(0.015, 0.05, y) * (1.0 - _smooth(0.9, 0.98, y))
	return m

## The pixel in the new paint colour (light and shade kept).
static func recolor(c: Color, key: Color, tolerance: float, new_color: Color, override: float = -1.0) -> Color:
	var m := amount(c, key, tolerance, override)
	var y := c.r * 0.299 + c.g * 0.587 + c.b * 0.114
	var ky := maxf(key.r * 0.299 + key.g * 0.587 + key.b * 0.114, 0.03)
	var k := clampf(y / ky, 0.0, 3.0)
	var painted := Color(new_color.r * k, new_color.g * k, new_color.b * k)
	painted = painted.lerp(Color(y, y, y), _smooth(0.75, 0.95, y) * 0.6)
	return c.lerp(painted, m)

## True when a paint colour has little hue (white, black, silver, grey):
## matching then leans on brightness and works less well.
static func is_grey(key: Color) -> bool:
	var k := ycc(key)
	return Vector2(k.y, k.z).length() / (k.x + 0.02) < 0.14

## Average colour of a (2r+1)² patch around pixel p (clamped to the image).
static func sample(img: Image, p: Vector2i, r: int = 4) -> Color:
	var acc := Vector3.ZERO
	var n := 0
	for y in range(p.y - r, p.y + r + 1):
		for x in range(p.x - r, p.x + r + 1):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var c := img.get_pixel(x, y)
			acc += Vector3(c.r, c.g, c.b)
			n += 1
	if n == 0:
		return Color.BLACK
	acc /= n
	return Color(acc.x, acc.y, acc.z)

## A blank touch-up mask for a photo (all automatic).
static func blank_mask(w: int, h: int) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_L8)
	img.fill(Color(0.5, 0.5, 0.5))
	return img

## Paint a round brush stroke into a mask: value 1 = paint, 0 = not paint,
## 0.5 = back to automatic.
static func brush(mask: Image, center: Vector2, radius: float, value: float) -> void:
	var r := int(ceil(radius))
	for y in range(int(center.y) - r, int(center.y) + r + 1):
		for x in range(int(center.x) - r, int(center.x) + r + 1):
			if x < 0 or y < 0 or x >= mask.get_width() or y >= mask.get_height():
				continue
			if Vector2(x, y).distance_to(center) <= radius:
				mask.set_pixel(x, y, Color(value, value, value))
