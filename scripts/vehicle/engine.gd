class_name CarEngine
extends RefCounted
## Combustion engine: torque from a measured-style curve, pumping/friction
## losses, a lumped thermal model of the cooling system (thermostat, radiator,
## fan) and oil, plus long-term wear that costs power.

var curve_rpm: PackedFloat32Array
var curve_nm: PackedFloat32Array
var idle_rpm := 650.0
var redline := 5000.0
var limiter := 5200.0
var inertia := 0.28
var fric_base := 18.0
var fric_per_krpm := 9.0
var displacement_l := 5.7
var thermostat_open := 90.5
var thermostat_full := 101.0
var overheat := 118.0

# state
var omega := 68.0                 # rad/s (≈650 rpm)
var coolant_c := 82.0             # starts warm-ish (pit lane warm-up)
var oil_c := 80.0
var health := 1.0                 # carried between sessions
var stalled := false
var limiter_cut := false
var _cut_timer := 0.0

# outputs
var throttle := 0.0
var torque_out := 0.0             # net crank torque this step (Nm)
var power_kw := 0.0
var damage_events := 0

const AMBIENT := 25.0
const C_COOLANT := 16.0 * 3600.0 + 180.0 * 460.0   # water+glycol mix plus iron block (J/K)
const C_OIL := 5.5 * 1900.0 + 15.0 * 460.0

func setup(def: Dictionary, engine_health: float) -> void:
	curve_rpm = PackedFloat32Array(def["torque_curve_rpm"])
	curve_nm = PackedFloat32Array(def["torque_curve_nm"])
	idle_rpm = def["idle_rpm"]
	redline = def["redline_rpm"]
	limiter = def["limiter_rpm"]
	inertia = def["inertia_kgm2"]
	fric_base = def["friction_nm_base"]
	fric_per_krpm = def["friction_nm_per_krpm"]
	displacement_l = def["displacement_l"]
	thermostat_open = def["thermostat_open_c"]
	thermostat_full = def["thermostat_full_c"]
	overheat = def["overheat_c"]
	health = engine_health
	omega = idle_rpm * TAU / 60.0

func rpm() -> float:
	return omega * 60.0 / TAU

func curve_torque(r: float) -> float:
	var n := curve_rpm.size()
	if r <= curve_rpm[0]:
		return curve_nm[0] * clampf(0.4 + 0.6 * r / curve_rpm[0], 0.0, 1.0)
	for i in range(1, n):
		if r <= curve_rpm[i]:
			var t := (r - curve_rpm[i - 1]) / (curve_rpm[i] - curve_rpm[i - 1])
			return lerpf(curve_nm[i - 1], curve_nm[i], t)
	return curve_nm[n - 1]

## Friction + pumping torque (always resists rotation). Engine braking at
## closed throttle comes from pumping losses rising with rpm.
func loss_torque(r: float, thr: float) -> float:
	var k := r / 1000.0
	var oil_visc := 1.0 + clampf((70.0 - oil_c) / 70.0, 0.0, 1.0) * 0.6   # cold oil drags
	var fric := (fric_base + fric_per_krpm * k) * oil_visc
	var pumping := (1.0 - thr) * (10.0 + 7.0 * k)
	var wear_drag := (1.0 - health) * 25.0
	return fric + pumping + wear_drag

## Effective throttle including idle control (IAC valve) and limiter.
func effective_throttle(driver: float, dt: float) -> float:
	var r := rpm()
	var idle_need := clampf((idle_rpm + 60.0 - r) / 160.0, 0.0, 1.0) * 0.35 + 0.04
	var thr := maxf(driver, idle_need if r < idle_rpm + 300.0 else 0.0)
	if r > limiter:
		_cut_timer = 0.08
	if _cut_timer > 0.0:
		_cut_timer -= dt
		limiter_cut = true
		thr = 0.0
	else:
		limiter_cut = false
	return thr

## Friction of a warm, healthy engine. The torque curve in the car file is the
## published SAE net (flywheel) rating, which already has this subtracted.
func warm_friction(r: float) -> float:
	return fric_base + fric_per_krpm * r / 1000.0

## Combustion torque available at the crank before losses. Adding the warm
## friction back means a warm engine at full throttle delivers exactly the
## rated curve at the flywheel; cold oil, wear and pumping still cost extra.
func combustion_torque(r: float, thr: float) -> float:
	if stalled:
		return 0.0
	var tq := (curve_torque(r) + warm_friction(r)) * thr
	# heat soak and overheating rob power (detonation / timing pull)
	var heat_loss := clampf((coolant_c - 108.0) / 25.0, 0.0, 0.4)
	var health_loss := (1.0 - health) * 0.6
	return tq * (1.0 - heat_loss) * (1.0 - health_loss)

## Advance crank speed given load torque from the converter/clutch.
func integrate(driver_throttle: float, load_torque: float, dt: float) -> void:
	var thr := effective_throttle(driver_throttle, dt)
	throttle = thr
	var r := rpm()
	var t_comb := combustion_torque(r, thr)
	var t_loss := loss_torque(r, thr) * signf(omega)
	torque_out = t_comb - t_loss
	omega += (torque_out - load_torque) / inertia * dt
	if omega < 0.0:
		omega = 0.0
	if not stalled and rpm() < 250.0:
		stalled = true
	power_kw = t_comb * omega / 1000.0
	_thermal(t_comb, dt)
	_wear(dt)

func restart() -> void:
	stalled = false
	omega = idle_rpm * TAU / 60.0

func _thermal(t_comb: float, dt: float) -> void:
	# fuel energy ≈ brake power / efficiency; ~30% of fuel energy goes to coolant
	var brake_w := maxf(t_comb, 0.0) * omega
	var fuel_w := brake_w / 0.30 + omega * 35.0          # idle burn baseline
	var to_coolant := fuel_w * 0.30
	var to_oil := fuel_w * 0.035 + omega * 5.0
	# thermostat opening
	var open := clampf((coolant_c - thermostat_open) / (thermostat_full - thermostat_open), 0.0, 1.0)
	open = maxf(open, 0.03)
	var air := _airflow_ms + (6.0 if coolant_c > 98.0 else 2.5)   # clutch fan engages hot
	var radiator := open * (150.0 + 70.0 * air) * (coolant_c - AMBIENT)
	var block_loss := 25.0 * (coolant_c - AMBIENT)
	var oil_to_coolant := 650.0 * (oil_c - coolant_c)
	coolant_c += (to_coolant - radiator - block_loss + oil_to_coolant) / C_COOLANT * dt
	oil_c += (to_oil - oil_to_coolant - (10.0 + 1.2 * _airflow_ms) * (oil_c - AMBIENT)) / C_OIL * dt

var _airflow_ms := 0.0
func set_airflow(speed_ms: float) -> void:
	_airflow_ms = speed_ms

func _wear(dt: float) -> void:
	var r := rpm()
	var rate := 0.0
	if r > redline:                       # over-rev stress grows quickly
		var o := (r - redline) / 500.0
		rate += 2.0e-5 * o * o * o
		if r > limiter + 400.0:           # mechanical over-rev (forced by a downshift)
			rate += 4.0e-3
			damage_events += 1
	if coolant_c > overheat:
		rate += 1.2e-4 * (coolant_c - overheat)
	if oil_c > 140.0:
		rate += 6.0e-5 * (oil_c - 140.0)
	if oil_c < 50.0 and r > 3500.0:       # revving it cold
		rate += 4.0e-6
	rate += 2.0e-10 * r                    # normal running wear
	health = maxf(0.0, health - rate * dt)
	if health <= 0.02 and not stalled:
		stalled = true                     # seized
