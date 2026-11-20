class_name HUD
extends Control
## In-race display: tachometer, speed, gear, lap timing, minimap and the
## telemetry panel (tire temps per zone / pressure / wear, brakes, engine).

var car: Vehicle
var track: Track
var lap_time := 0.0
var last_lap := 0.0
var best_lap := 0.0
var lap := 1
var show_telemetry := true
var message := ""
var message_t := 0.0
var cam_name := ""
var _minimap: PackedVector2Array
var _mm_rect := Rect2()

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_track(t: Track) -> void:
	track = t
	var mn := Vector2(1e9, 1e9)
	var mx := Vector2(-1e9, -1e9)
	for p in t.pts:
		mn = mn.min(Vector2(p.x, p.z)); mx = mx.max(Vector2(p.x, p.z))
	_mm_rect = Rect2(mn, mx - mn)
	_minimap = PackedVector2Array()
	for i in range(0, t.pts.size(), 2):
		_minimap.append(_mm(t.pts[i]))
	_minimap.append(_minimap[0])

func _mm(p: Vector3) -> Vector2:
	var size := 230.0
	var s := size / maxf(_mm_rect.size.x, _mm_rect.size.y)
	var o := Vector2(get_viewport_rect().size.x - size - 40, 40)
	return o + (Vector2(p.x, p.z) - _mm_rect.position) * s

func flash(msg: String, secs: float = 2.0) -> void:
	message = msg
	message_t = secs

func _process(dt: float) -> void:
	message_t = maxf(0.0, message_t - dt)
	queue_redraw()

func _draw() -> void:
	if car == null or not is_instance_valid(car):
		return
	var vs := get_viewport_rect().size
	var font := get_theme_default_font()
	_draw_tach(Vector2(vs.x - 230, vs.y - 210), 165.0, font)
	_draw_timing(font)
	if track and _minimap.size() > 1:
		draw_polyline(_minimap, Color(0, 0, 0, 0.5), 9.0, true)
		draw_polyline(_minimap, Color(0.9, 0.93, 1.0, 0.85), 4.0, true)
		draw_circle(_mm(car.global_position), 8.0, UIKit.BAD)
		draw_circle(_mm(track.pts[track.start_index]), 4.0, Color.WHITE)
	if show_telemetry:
		_draw_telemetry(Vector2(30, vs.y - 345), font)
	if message_t > 0.0:
		var a := clampf(message_t, 0, 1)
		var w := font.get_string_size(message, HORIZONTAL_ALIGNMENT_LEFT, -1, 44).x
		draw_string(font, Vector2((vs.x - w) * 0.5 + 2, vs.y * 0.3 + 2), message, HORIZONTAL_ALIGNMENT_LEFT, -1, 44, Color(0, 0, 0, a * 0.7))
		draw_string(font, Vector2((vs.x - w) * 0.5, vs.y * 0.3), message, HORIZONTAL_ALIGNMENT_LEFT, -1, 44, Color(1, 1, 1, a))

func _draw_tach(c: Vector2, r: float, font: Font) -> void:
	var eng := car.engine
	var max_rpm := 6000.0
	var a0 := deg_to_rad(135.0)
	var a1 := deg_to_rad(405.0)
	draw_circle(c, r + 18, Color(0.02, 0.04, 0.08, 0.72))
	# red zone
	var red0 := lerpf(a0, a1, eng.redline / max_rpm)
	draw_arc(c, r - 6, red0, a1, 32, Color(0.9, 0.12, 0.1, 0.9), 12.0, true)
	for k in 7:
		var a := lerpf(a0, a1, k * 1000.0 / max_rpm)
		var d := Vector2(cos(a), sin(a))
		draw_line(c + d * (r - 22), c + d * r, Color.WHITE, 4.0, true)
		var s := str(k)
		draw_string(font, c + d * (r - 44) - Vector2(8, -10), s, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, UIKit.TEXT)
	for k in 13:
		var a := lerpf(a0, a1, k * 500.0 / max_rpm)
		var d := Vector2(cos(a), sin(a))
		draw_line(c + d * (r - 10), c + d * r, Color(1, 1, 1, 0.6), 2.0, true)
	var rpm := clampf(eng.rpm(), 0, max_rpm)
	var an := lerpf(a0, a1, rpm / max_rpm)
	draw_line(c, c + Vector2(cos(an), sin(an)) * (r - 8), UIKit.BAD if rpm > eng.redline else Color(1, 0.55, 0.15), 5.0, true)
	draw_circle(c, 12, Color(0.15, 0.15, 0.18))
	# speed + gear
	var spd := Game.speed_str(car.speed_ms) if Game else str(roundi(car.speed_ms * 2.237))
	draw_string(font, c + Vector2(-80, 108), spd, HORIZONTAL_ALIGNMENT_CENTER, 160, 54, Color.WHITE)
	draw_string(font, c + Vector2(-80, 134), Game.speed_unit() if Game else "mph", HORIZONTAL_ALIGNMENT_CENTER, 160, 20, UIKit.DIM)
	var g := car.trans.gear_label()
	if car.trans.shifting > 0.0:
		g = str(car.trans.target_gear) if car.trans.target_gear > 0 else g
	draw_rect(Rect2(c + Vector2(-32, -2), Vector2(64, 50)), Color(0, 0, 0, 0.6))
	draw_string(font, c + Vector2(-32, 40), g, HORIZONTAL_ALIGNMENT_CENTER, 64, 46, UIKit.ACCENT)
	var mode := ("M" if car.trans.manual else "D") + ("  " + car.transfer if car.drivetrain == "4wd" else "  2WD")
	draw_string(font, c + Vector2(-60, -50), mode, HORIZONTAL_ALIGNMENT_CENTER, 120, 22, UIKit.DIM)
	if car.trans.locked:
		draw_string(font, c + Vector2(-60, -26), "TCC", HORIZONTAL_ALIGNMENT_CENTER, 120, 18, UIKit.GOOD)
	if car.engine.stalled:
		draw_string(font, c + Vector2(-100, 30), "ENGINE OFF", HORIZONTAL_ALIGNMENT_CENTER, 200, 26, UIKit.BAD)

func _draw_timing(font: Font) -> void:
	var p := Vector2(36, 60)
	draw_rect(Rect2(p - Vector2(16, 44), Vector2(380, 170)), Color(0.02, 0.04, 0.08, 0.65))
	draw_string(font, p, "LAP %d" % lap, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, UIKit.DIM)
	draw_string(font, p + Vector2(0, 46), Game.fmt_time(lap_time), HORIZONTAL_ALIGNMENT_LEFT, -1, 44, Color.WHITE)
	draw_string(font, p + Vector2(0, 82), "LAST  " + Game.fmt_time(last_lap), HORIZONTAL_ALIGNMENT_LEFT, -1, 24, UIKit.TEXT)
	draw_string(font, p + Vector2(0, 112), "BEST  " + Game.fmt_time(best_lap), HORIZONTAL_ALIGNMENT_LEFT, -1, 24, UIKit.GOOD)
	if cam_name != "":
		draw_string(font, p + Vector2(200, 0), cam_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, UIKit.DIM)

func _draw_telemetry(o: Vector2, font: Font) -> void:
	draw_rect(Rect2(o - Vector2(12, 34), Vector2(640, 330)), Color(0.02, 0.04, 0.08, 0.68))
	draw_string(font, o, "TELEMETRY", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, UIKit.DIM)
	# tires: 2x2 grid, three zone bars each (inner/mid/outer ordered as seen from above)
	var cell := Vector2(130, 100)
	for i in 4:
		var w: Vehicle.Wheel = car.wheels[i]
		var col := i % 2
		var row := i / 2
		var p := o + Vector2(col * 170, 24 + row * 120)
		var zones := [w.tire.t_zone[2], w.tire.t_zone[1], w.tire.t_zone[0]] if w.left else [w.tire.t_zone[0], w.tire.t_zone[1], w.tire.t_zone[2]]
		for z in 3:
			var c := UIKit.temp_color(zones[z], 30.0, 75.0, 125.0)
			draw_rect(Rect2(p + Vector2(z * 22, 0), Vector2(20, 70)), c)
		# tread remaining bar
		var wear := 1.0 - w.tire.wear_fraction()
		draw_rect(Rect2(p + Vector2(72, 0), Vector2(8, 70)), Color(0.2, 0.2, 0.2))
		draw_rect(Rect2(p + Vector2(72, 70 * (1.0 - wear)), Vector2(8, 70 * wear)), UIKit.GOOD if wear > 0.3 else UIKit.BAD)
		draw_string(font, p + Vector2(86, 18), Game.temp_str(w.tire.avg_temp()), HORIZONTAL_ALIGNMENT_LEFT, -1, 17, UIKit.TEXT)
		draw_string(font, p + Vector2(86, 40), "%.1f psi" % w.tire.psi, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, UIKit.DIM)
		draw_string(font, p + Vector2(86, 62), "%d%%" % roundi(wear * 100.0), HORIZONTAL_ALIGNMENT_LEFT, -1, 17, UIKit.DIM)
		var bc := UIKit.temp_color(w.brake_c, 50.0, 250.0, w.brake_fade_start)
		draw_rect(Rect2(p + Vector2(0, 76), Vector2(80, 6)), bc)
		if w.tire.blown:
			draw_string(font, p + Vector2(0, 40), "FLAT", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, UIKit.BAD)
	# engine block
	var e := car.engine
	var q := o + Vector2(355, 40)
	var rows := [
		["Coolant", Game.temp_str(e.coolant_c), UIKit.temp_color(e.coolant_c, 60, 92, e.overheat)],
		["Oil", Game.temp_str(e.oil_c), UIKit.temp_color(e.oil_c, 60, 100, 140)],
		["Trans fluid", Game.temp_str(car.trans.fluid_c), UIKit.temp_color(car.trans.fluid_c, 50, 85, 130)],
		["Engine", "%d%%" % roundi(e.health * 100.0), UIKit.GOOD if e.health > 0.8 else (UIKit.WARN if e.health > 0.4 else UIKit.BAD)],
		["Power", "%d hp" % roundi(maxf(e.power_kw, 0.0) * 1.341), UIKit.TEXT],
		["Lat / Long", "%.2f / %.2f g" % [car.g_lat, car.g_long], UIKit.TEXT],
		["Surface", car.surface_name, UIKit.TEXT],
		["Assists", ("ABS " if car.abs_enabled else "") + ("TCS" if car.tcs_enabled else ""), UIKit.DIM],
	]
	for k in rows.size():
		var r: Array = rows[k]
		draw_string(font, q + Vector2(0, k * 36), r[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 19, UIKit.DIM)
		draw_string(font, q + Vector2(125, k * 36), r[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 19, r[2])
