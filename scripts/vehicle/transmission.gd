class_name Transmission
extends RefCounted
## 4L60-E style automatic: hydrodynamic torque converter with lock-up clutch,
## planetary gearset with timed shifts, and a shift schedule driven by
## throttle and road speed. Manual mode lets the driver pick gears with
## shoulder buttons (the computer still refuses a ruinous downshift).

var ratios: PackedFloat32Array = [3.059, 1.625, 1.0, 0.696]
var reverse_ratio := 2.29
var final_drive := 3.42
var range_ratio := 1.0              # transfer case low range (4L) multiplies this
var stall_rpm := 2000.0
var stall_tr := 2.0
var lockup_min_gear := 3
var lockup_min_ms := 18.8
var shift_time := 0.45
var wot_upshift_mph := [42.0, 78.0, 300.0]   # full-throttle 1-2, 2-3, 3-4 on the base axle
var manual := false

# state: gear 1..4 forward, 0 neutral/park, -1 reverse
var gear := 1
var target_gear := 1
var shifting := 0.0
var locked := false
var lock_amount := 0.0               # 0..1 lock-up clutch engagement
var fluid_c := 70.0                  # transmission fluid temperature
var _shift_cooldown := 0.0

# outputs
var impeller_torque := 0.0
var turbine_torque := 0.0
var speed_ratio := 0.0

const AMBIENT := 25.0

func setup(def: Dictionary, fd: float, manual_mode: bool) -> void:
	ratios = PackedFloat32Array(def["gear_ratios"])
	reverse_ratio = def["reverse_ratio"]
	final_drive = fd
	stall_rpm = def["converter_stall_rpm"]
	stall_tr = def["converter_stall_torque_ratio"]
	lockup_min_gear = def["lockup_min_gear"]
	lockup_min_ms = def["lockup_min_mph"] / 2.23694
	shift_time = def["shift_time_s"]
	if def.has("wot_upshift_mph"):
		wot_upshift_mph = def["wot_upshift_mph"].duplicate()
	manual = manual_mode

func gear_ratio(g: int = -99) -> float:
	if g == -99:
		g = gear
	if g == 0:
		return 0.0
	if g < 0:
		return -reverse_ratio * final_drive * range_ratio
	return ratios[g - 1] * final_drive * range_ratio

func total_ratio() -> float:
	return gear_ratio()

func gear_label() -> String:
	if gear < 0:
		return "R"
	if gear == 0:
		return "N"
	return str(gear)

## Converter: capacity factor K = rpm / sqrt(torque). Chosen so a stalled
## converter at full throttle holds the engine at stall_rpm.
## Returns [impeller torque load on engine, turbine torque out].
func converter(engine_omega: float, turbine_omega: float, peak_torque_at_stall: float) -> Array:
	var we := maxf(engine_omega, 1.0)
	var sr := clampf(turbine_omega / we, -1.0, 1.2)
	speed_ratio = sr
	var stall_w := stall_rpm * TAU / 60.0
	var k_stall := stall_w / sqrt(peak_torque_at_stall)
	# capacity rises as speed ratio approaches coupling
	var k := k_stall * (1.0 + 0.45 * pow(clampf(sr, 0.0, 1.0), 3.0))
	var t_imp := (we / k) * (we / k)
	var tr := 1.0
	if sr < 0.85:
		tr = lerpf(stall_tr, 1.0, clampf(sr / 0.85, 0.0, 1.0))
	elif sr > 1.0:
		# overrun: turbine drives engine (engine braking through the fluid)
		t_imp = -pow((turbine_omega - we) / k, 2.0) * 1.6
		tr = 1.0
	else:
		# coupling region: torque falls to zero at sr = 1
		t_imp *= clampf((1.0 - sr) / 0.15, 0.0, 1.0)
	impeller_torque = t_imp
	turbine_torque = t_imp * tr
	return [t_imp, turbine_torque]

## Automatic shift schedule (mph thresholds scale with throttle).
func update_auto(speed_ms: float, throttle: float, engine_rpm: float, redline: float, dt: float) -> void:
	_shift_cooldown = maxf(0.0, _shift_cooldown - dt)
	if shifting > 0.0:
		shifting -= dt
		if shifting <= 0.0:
			gear = target_gear
		return
	if gear <= 0:
		return
	var mph := speed_ms * 2.23694
	if manual:
		# protect against bouncing off the limiter only in auto; manual holds gear
		return
	var thr := clampf(throttle, 0.0, 1.0)
	# up-shift points (mph) for 1->2, 2->3, 3->4 at light and full throttle,
	# based on the factory 3.42 axle; scaled for other axles and range
	var axle_scale := 3.42 / (final_drive * range_ratio)
	var up_light := [13.0, 24.0, 38.0]
	var up_full: Array = wot_upshift_mph       # WOT holds 3rd to ~governed speed
	var down_light := [8.0, 16.0, 28.0]
	var down_full := [28.0, 52.0, 78.0]
	if _shift_cooldown > 0.0:
		return
	if gear < 4:
		var up: float = lerpf(up_light[gear - 1], up_full[gear - 1], pow(thr, 1.3)) * axle_scale
		if mph > up or engine_rpm > redline + 50.0:
			request_shift(gear + 1)
			return
	if gear > 1:
		var dn: float = lerpf(down_light[gear - 2], down_full[gear - 2], pow(thr, 1.5)) * axle_scale
		if mph < dn:
			# kickdown only if the lower gear won't over-rev
			var next_rpm := engine_rpm * gear_ratio(gear - 1) / gear_ratio(gear)
			if next_rpm < redline - 200.0:
				request_shift(gear - 1)

func request_shift(g: int) -> void:
	if g == gear or shifting > 0.0:
		return
	target_gear = clampi(g, -1, ratios.size())
	shifting = shift_time if (gear > 0 and target_gear > 0) else 0.6
	_shift_cooldown = shift_time + 0.6
	locked = false
	lock_amount = 0.0

## Manual request with over-rev protection.
func manual_shift(dir: int, wheel_rpm_equiv: float, limiter: float) -> void:
	var g := gear + dir
	if g < 1 or g > ratios.size():
		return
	var predicted := wheel_rpm_equiv * gear_ratio(g)
	if dir < 0 and predicted > limiter + 200.0:
		return   # TCM refuses the downshift
	request_shift(g)

func update_lockup(speed_ms: float, throttle: float, dt: float) -> void:
	var want := gear >= lockup_min_gear and speed_ms > lockup_min_ms and throttle < 0.85 and shifting <= 0.0
	lock_amount = move_toward(lock_amount, 1.0 if want else 0.0, dt * (1.5 if want else 6.0))
	locked = lock_amount > 0.99

func update_thermal(slip_power_w: float, speed_ms: float, dt: float) -> void:
	var c := 9.0 * 1800.0 + 40.0 * 460.0
	var cooling := (18.0 + 6.0 * speed_ms) * (fluid_c - AMBIENT)
	fluid_c += (slip_power_w * 0.9 + 600.0 - cooling) / c * dt
