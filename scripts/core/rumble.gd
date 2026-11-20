class_name Rumble
extends RefCounted
## Force feedback through XInput's two vibration motors:
##   strong (low-frequency, left motor):  road impacts, curbs, whoops,
##       bottoming out, collisions, engine shake at idle and the rev limiter
##   weak (high-frequency, right motor):  tire scrub past the grip limit,
##       wheelspin, ABS pulsing, rough surfaces (gravel/dirt)
## Values come straight from the physics model, so what you feel matches
## what the tires and suspension are doing.

var strength := 1.0
var _prev_comp: Array = [0.0, 0.0, 0.0, 0.0]
var _impact := 0.0
var _abs_phase := 0.0
var _send_t := 0.0
var _prev_vel := Vector3.ZERO
var strong := 0.0
var weak := 0.0
var _mute := 0.0

## Silence briefly (spawn / reset drops the truck onto its springs).
func mute(secs: float = 1.0) -> void:
	_mute = secs
	_impact = 0.0

func update(car: Vehicle, dt: float) -> void:
	if car == null or car.wheels.is_empty():
		return
	var spd := absf(car.speed_ms)
	if _mute > 0.0:
		_mute -= dt
		for i in 4:
			_prev_comp[i] = car.wheels[i].compression
		_prev_vel = car.linear_velocity
		strong = 0.0
		weak = 0.0
		return
	# ---- strong motor: suspension velocity spikes = impacts
	var hit := 0.0
	for i in 4:
		var w: Vehicle.Wheel = car.wheels[i]
		var dv := absf(w.compression - float(_prev_comp[i])) / maxf(dt, 0.001)
		_prev_comp[i] = w.compression
		hit = maxf(hit, clampf((dv - 0.25) / 2.0, 0.0, 1.0))
		if w.compression > w.travel * 0.9 and w.comp_vel > 0.4:
			hit = maxf(hit, 0.8)        # slamming into the bump stop
	var dvel := (car.linear_velocity - _prev_vel).length() / maxf(dt, 0.001)
	_prev_vel = car.linear_velocity
	if dvel > 25.0:                      # >2.5 g jolt: collision
		hit = 1.0
	_impact = maxf(_impact * exp(-dt * 9.0), hit)
	var engine := 0.0
	if car.engine.limiter_cut:
		engine = 0.35
	elif not car.engine.stalled and car.engine.rpm() < 900.0:
		engine = 0.06                    # V8 idle shake
	strong = clampf(_impact + engine, 0.0, 1.0)

	# ---- weak motor: tire scrub, wheelspin, ABS, surface texture
	var scrub := 0.0
	var abs_on := false
	var rough := 0.0
	for w in car.wheels:
		if not w.contact:
			continue
		scrub = maxf(scrub, clampf((w.tire.sliding - 0.85) * 1.2, 0.0, 0.7))
		if w.abs_factor < 0.95:
			abs_on = true
		var sname: String = w.surface.get("name", "asphalt")
		if sname in ["gravel", "dirt", "grass"]:
			rough = maxf(rough, clampf(spd / 25.0, 0.0, 1.0) * (0.35 if sname == "gravel" else 0.2))
		elif sname == "curb":
			rough = maxf(rough, clampf(spd / 20.0, 0.0, 1.0) * 0.6)
	if abs_on:
		_abs_phase += dt * 14.0           # ~14 Hz pedal pulse
		scrub = maxf(scrub, 0.5 if fmod(_abs_phase, 1.0) < 0.5 else 0.1)
	weak = clampf(scrub + rough, 0.0, 1.0)

	# ---- send to every connected pad (XInput motors), ~20 Hz
	_send_t -= dt
	if _send_t <= 0.0:
		_send_t = 0.05
		for id in Input.get_connected_joypads():
			if strength <= 0.0 or (strong < 0.02 and weak < 0.02):
				Input.stop_joy_vibration(id)
			else:
				Input.start_joy_vibration(id, weak * strength, strong * strength, 0.12)

func stop() -> void:
	for id in Input.get_connected_joypads():
		Input.stop_joy_vibration(id)
