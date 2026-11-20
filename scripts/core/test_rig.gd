class_name TestRig
extends RefCounted
## Automatic performance testing, the way magazines do it. Works anywhere,
## with extra structure on the proving ground:
##   0-30 / 0-60 mph, 1/8 and 1/4 mile (+ trap speed): stop fully, then launch
##   60-0 mph braking distance: brake hard from 60+ mph to a stop
##   Skidpad: hold the 200 ft circle; average lateral g over 3 s
##   Top speed: highest speed this session

signal result(text: String)

const MPH := 0.44704

var car: Vehicle
var skidpad_center := Vector3.INF
var skidpad_radius := 30.48

# launch run
var _armed := false
var _running := false
var _t := 0.0
var _dist := 0.0
var _got := {}
# braking
var _braking := false
var _brake_dist := 0.0
var _prev_speed := 0.0
# skidpad
var _lat_hist: Array = []
var skidpad_live := 0.0

var last := {"0-30": 0.0, "0-60": 0.0, "1/8": 0.0, "1/4": 0.0, "trap": 0.0, "60-0": 0.0, "skidpad": 0.0}
var best := {"0-60": 0.0, "1/4": 0.0, "60-0": 0.0, "skidpad": 0.0}
var top_speed := 0.0

func setup(c: Vehicle, zones: Dictionary) -> void:
	car = c
	var sp: Dictionary = zones.get("skidpad", {})
	if not sp.is_empty():
		skidpad_center = Vector3(sp["center"][0], sp["center"][1], sp["center"][2])
		skidpad_radius = sp.get("radius", 30.48)

func reset_run() -> void:
	_armed = false
	_running = false
	_braking = false

func update(dt: float) -> void:
	if car == null:
		return
	var v := absf(car.speed_ms)
	top_speed = maxf(top_speed, v)
	_launch(v, dt)
	_brake(v, dt)
	_skidpad(dt)
	_prev_speed = v

func _launch(v: float, dt: float) -> void:
	if v < 0.15 and car.trans.gear >= 1:
		_armed = true
		_running = false
		_t = 0.0
		_dist = 0.0
		_got.clear()
		return
	if _armed and not _running and v > 0.3:
		_running = true
		_armed = false
	if not _running:
		return
	# a run ends if the driver lifts or brakes
	if car.in_brake > 0.2 or car.in_throttle < 0.6:
		if _got.has("0-60") or _got.has("1/4"):
			pass
		_running = false
		return
	_t += dt
	_dist += v * dt
	if v >= 30.0 * MPH and not _got.has("0-30"):
		_got["0-30"] = _t
		last["0-30"] = _t
	if v >= 60.0 * MPH and not _got.has("0-60"):
		_got["0-60"] = _t
		last["0-60"] = _t
		best["0-60"] = _t if best["0-60"] == 0.0 else minf(best["0-60"], _t)
		result.emit("0-60 mph  %.2f s" % _t)
	if _dist >= 201.17 and not _got.has("1/8"):
		_got["1/8"] = _t
		last["1/8"] = _t
	if _dist >= 402.34 and not _got.has("1/4"):
		_got["1/4"] = _t
		last["1/4"] = _t
		last["trap"] = v
		best["1/4"] = _t if best["1/4"] == 0.0 else minf(best["1/4"], _t)
		result.emit("1/4 MILE  %.2f s @ %d mph" % [_t, roundi(v / MPH)])
		_running = false

func _brake(v: float, dt: float) -> void:
	if not _braking:
		if _prev_speed >= 60.0 * MPH and v < 60.0 * MPH and car.in_brake > 0.6:
			_braking = true
			_brake_dist = 0.0
		return
	if car.in_throttle > 0.1 or car.in_brake < 0.3:
		_braking = false
		return
	_brake_dist += v * dt
	if v < 0.2:
		_braking = false
		var ft := _brake_dist * 3.28084
		last["60-0"] = ft
		best["60-0"] = ft if best["60-0"] == 0.0 else minf(best["60-0"], ft)
		result.emit("60-0 mph  %d ft" % roundi(ft))

func _skidpad(dt: float) -> void:
	skidpad_live = 0.0
	if skidpad_center == Vector3.INF:
		return
	var p := car.global_position
	var r := Vector2(p.x - skidpad_center.x, p.z - skidpad_center.z).length()
	if absf(r - skidpad_radius) > 5.0 or absf(car.speed_ms) < 5.0:
		_lat_hist.clear()
		return
	_lat_hist.append(absf(car.g_lat))
	var n := int(3.0 / dt)
	while _lat_hist.size() > n:
		_lat_hist.pop_front()
	if _lat_hist.size() >= n:
		var s := 0.0
		for g in _lat_hist:
			s += g
		skidpad_live = s / _lat_hist.size()
		if skidpad_live > best["skidpad"] + 0.005:
			best["skidpad"] = skidpad_live
			last["skidpad"] = skidpad_live
