class_name Tire
extends RefCounted
## Physical tire model.
##
## Forces: normalized combined-slip "Magic Formula" (Pacejka-style) with load
## sensitivity, plus brush-style relaxation (contact-patch deflection) so the
## tire behaves correctly at walking pace and when parked.
## Thermal: three tread zones (inner/middle/outer) + carcass + inflation gas.
## Pressure follows the ideal gas law from carcass temperature.
## Wear: tread depth lost from sliding energy, faster when overheated.

# ---------- compound / construction parameters ----------
var mu_peak := 1.0              # peak friction at reference load & ideal temp
var load_ref := 6000.0          # N (light-truck tire)
var load_sensitivity := 0.12    # friction lost per +100% load
var shape_c := 1.4              # MF shape factor (sets slide/peak ratio ~0.81)
var slip_ratio_peak := 0.12
var slip_angle_peak := deg_to_rad(7.5)
var relax_lat := 0.55           # m, relaxation length (tall sidewall truck tire)
var relax_long := 0.25
var radius := 0.367
var width := 0.235
var temp_opt := 75.0            # °C, best grip for a 90s all-season
var temp_window := 60.0
var crr_base := 0.0105          # rolling resistance coefficient at placard pressure
var tread_new_mm := 9.5
var wear_rate := 4.8e-7         # mm per joule of sliding energy (tunable)
var wear_multiplier := 1.0

# ---------- state ----------
var cold_psi := 35.0
var psi := 35.0
var t_zone := [25.0, 25.0, 25.0]    # inner, middle, outer surface °C
var t_carcass := 25.0
var tread_mm := [9.5, 9.5, 9.5]     # per zone
var health := 1.0                    # permanent damage from overheating (blistering)
var defl_x := 0.0                    # contact patch deflection (m)
var defl_y := 0.0
var blown := false
var air := 1.0                       # fraction of the cold air charge still inside

# ---------- outputs (for telemetry) ----------
var fx := 0.0
var fy := 0.0
var slip_ratio := 0.0
var slip_angle := 0.0
var grip_factor := 1.0
var sliding := 0.0                   # 0..1+ how far past peak
var slide_power := 0.0
var load := 0.0

const AMBIENT := 25.0
const C_ZONE := 600.0       # J/K per tread zone
const C_CARCASS := 15000.0  # J/K
const H_ZONE_CARCASS := 55.0 # W/K per zone
const B_FACTOR := 2.077     # tan(pi / (2*C)) for C=1.4 -> peak at s=1

func setup(def: Dictionary, psi_cold: float, tread_state: float) -> void:
	radius = def.get("radius_m", radius)
	width = def.get("width_m", width)
	tread_new_mm = def.get("tread_depth_new_mm", tread_new_mm)
	cold_psi = psi_cold
	psi = psi_cold
	var tr: float = tread_new_mm if tread_state < 0.0 else minf(tread_state, tread_new_mm)
	tread_mm = [tr, tr, tr]

func avg_temp() -> float:
	return (t_zone[0] + t_zone[1] + t_zone[2]) / 3.0

func avg_tread() -> float:
	return (tread_mm[0] + tread_mm[1] + tread_mm[2]) / 3.0

func wear_fraction() -> float:
	return clampf(1.0 - avg_tread() / tread_new_mm, 0.0, 1.0)

func ideal_hot_psi() -> float:
	return cold_psi + 3.0

## Main update. vx/vy: contact-patch velocity in wheel frame (m/s, +x forward,
## +y right). omega: wheel spin (rad/s). camber: degrees relative to ground
## (negative = top leaning toward car centre). surface: Dictionary with mu, crr.
func update(fz: float, vx: float, vy: float, omega: float, camber_deg: float,
		surface: Dictionary, side_sign: float, dt: float) -> void:
	load = fz
	if fz <= 0.0:
		fx = 0.0; fy = 0.0; sliding = 0.0; slide_power = 0.0
		defl_x *= 0.5; defl_y *= 0.5
		_thermal(0.0, 0.0, 0.0, absf(vx), camber_deg, side_sign, dt)
		return

	var abs_vx := absf(vx)
	var slip_vx := omega * radius - vx      # longitudinal slip velocity

	# --- relaxation (implicit integration of patch deflection) ---
	defl_x = (defl_x + slip_vx * dt) / (1.0 + (abs_vx + absf(omega * radius) * 0.5) * dt / relax_long)
	defl_y = (defl_y + vy * dt) / (1.0 + abs_vx * dt / relax_lat)
	defl_x = clampf(defl_x, -relax_long * 1.5, relax_long * 1.5)
	defl_y = clampf(defl_y, -relax_lat * 0.9, relax_lat * 0.9)

	slip_ratio = defl_x / relax_long
	var tan_a := defl_y / relax_lat
	slip_angle = atan(tan_a)

	# --- pressure / camber / temperature / wear effects on grip ---
	var p_ideal := ideal_hot_psi()
	var p_err := absf(psi - p_ideal)
	var p_factor := 1.0 - 0.0055 * pow(p_err, 1.15)
	var stiff_scale := pow(clampf(p_ideal / maxf(psi, 5.0), 0.6, 1.6), 0.4)  # soft tire -> larger peak slip

	var t_eff := avg_temp() * 0.75 + t_carcass * 0.25
	var t_n := (t_eff - temp_opt) / temp_window
	var t_factor := clampf(1.0 - 0.12 * t_n * t_n, 0.72, 1.0)

	# a little negative camber (to the ground) is ideal; positive camber from
	# body roll on the outside wheel costs real grip
	var camber_factor := 1.0 - 0.014 * pow(absf(camber_deg + 0.8), 1.3)

	var tread := avg_tread()
	var wear_factor := 1.0
	if tread > 1.5:
		wear_factor = 0.97 + 0.03 * (1.0 - (tread - 1.5) / maxf(tread_new_mm - 1.5, 0.1))
	else:
		wear_factor = lerpf(0.72, 1.0, clampf(tread / 1.5, 0.0, 1.0))
	if blown:
		wear_factor = 0.35

	var load_factor := 1.0 - load_sensitivity * (fz / load_ref - 1.0)
	load_factor = clampf(load_factor, 0.6, 1.15)

	grip_factor = p_factor * t_factor * camber_factor * wear_factor * health
	var mu: float = mu_peak * grip_factor * load_factor * surface.get("mu", 1.0)
	var d := mu * fz

	# --- combined slip magic formula ---
	var kp := slip_ratio_peak * stiff_scale
	var ap := tan(slip_angle_peak * stiff_scale)
	var sx := slip_ratio / kp
	var sy := tan_a / ap
	var s := sqrt(sx * sx + sy * sy)
	sliding = s
	if s > 1e-5:
		var f := d * sin(shape_c * atan(B_FACTOR * s))
		fx = f * sx / s
		fy = -f * sy / s * 0.97
	else:
		fx = 0.0; fy = 0.0

	# low-speed damping keeps a parked car from jittering
	if abs_vx < 2.0:
		var k := (2.0 - abs_vx) / 2.0
		fy -= vy * fz * 0.08 * k
		fx += slip_vx * fz * 0.03 * k

	# sliding power at contact patch (only the part past adhesion heats strongly)
	var adhesion := clampf(s, 0.0, 1.5) / 1.5
	slide_power = (absf(fx * slip_vx) + absf(fy * vy)) * (0.15 + 0.55 * adhesion)

	var roll_power := crr() * fz * abs_vx
	_thermal(slide_power, roll_power, fy, abs_vx, camber_deg, side_sign, dt)
	_wear(slide_power, dt)

func crr() -> float:
	return crr_base * sqrt(ideal_hot_psi() / maxf(psi, 5.0))

func _thermal(p_slide: float, p_roll: float, lat_force: float, speed: float,
		camber_deg: float, side_sign: float, dt: float) -> void:
	# Distribute heat across zones: camber loads one shoulder, cornering force
	# loads the outer shoulder, under-inflation loads both shoulders.
	var w := [1.0, 1.0, 1.0]
	var cam := clampf(-camber_deg * 0.07, -0.5, 0.5)   # negative camber -> inner
	w[0] += cam
	w[2] -= cam
	if load > 0.0:
		var lat := clampf(-lat_force / maxf(load, 1.0) * side_sign, -1.0, 1.0) * 0.15
		w[2] += lat      # outer shoulder works harder in its cornering direction
		w[0] -= lat
	var p_dev := clampf((ideal_hot_psi() - psi) * 0.04, -0.4, 0.4)
	w[0] += p_dev; w[2] += p_dev; w[1] -= p_dev
	var wsum := 0.0
	for i in 3:
		w[i] = maxf(w[i], 0.1)
		wsum += w[i]

	var h_air := 1.5 + 0.55 * speed        # W/K per zone, forced convection
	var h_road := 9.0 if load > 0.0 else 0.0
	var road_t := AMBIENT + 8.0
	for i in 3:
		var q_in: float = p_slide * w[i] / wsum + p_roll * 0.25 / 3.0
		var q_out: float = h_air * (t_zone[i] - AMBIENT) + h_road * (t_zone[i] - road_t)
		var q_c: float = H_ZONE_CARCASS * (t_zone[i] - t_carcass)
		# lateral conduction between neighbouring tread zones
		var q_lat := 0.0
		if i > 0:
			q_lat += 18.0 * (t_zone[i] - t_zone[i - 1])
		if i < 2:
			q_lat += 18.0 * (t_zone[i] - t_zone[i + 1])
		t_zone[i] += (q_in - q_out - q_c - q_lat) / C_ZONE * dt
	var q_carc_in := p_roll * 0.75
	var q_from_zones: float = H_ZONE_CARCASS * ((t_zone[0] + t_zone[1] + t_zone[2]) - 3.0 * t_carcass)
	var q_carc_out := (4.0 + 0.9 * speed) * (t_carcass - AMBIENT)
	t_carcass += (q_carc_in + q_from_zones - q_carc_out) / C_CARCASS * dt
	# inflation gas follows carcass temperature
	if blown:                        # air escapes in a second or two
		air = move_toward(air, 14.7 / (cold_psi + 14.7), dt * 0.8)
	psi = maxf(0.0, (cold_psi + 14.7) * air * (t_carcass + 273.15) / (AMBIENT + 273.15) - 14.7)
	# overheating permanently damages the tread surface
	var hottest := maxf(t_zone[0], maxf(t_zone[1], t_zone[2]))
	if hottest > 125.0:
		health = maxf(0.8, health - (hottest - 125.0) * 2.0e-5 * dt)

func _wear(p_slide: float, dt: float) -> void:
	if p_slide <= 0.0:
		return
	for i in 3:
		var over := maxf(0.0, (t_zone[i] - temp_opt) / 30.0)
		var rate := wear_rate * wear_multiplier * (1.0 + 2.0 * over * over)
		tread_mm[i] = maxf(0.0, tread_mm[i] - rate * p_slide / 3.0 * dt)
	if avg_tread() <= 0.05 and not blown:
		blown = true

# ---------- vertical compliance (tyre squash) ----------
## Radial stiffness of an LT245/75R16: carcass ~45 kN/m plus ~6.6 kN/m per psi
## (about 275 kN/m at 35 psi -> ~2 cm static squash under a 5 kN corner).
func vertical_stiffness() -> float:
	return 45000.0 + 6600.0 * psi

## Raw (unclamped) deflection the load asks for.
func raw_deflection(fz: float) -> float:
	return maxf(fz, 0.0) / vertical_stiffness()

## Deflection after the sidewall bottoms out on the rim (flat tyre ~8 cm).
func deflection_for(fz: float) -> float:
	var d := raw_deflection(fz)
	if d > 0.075:
		d = 0.075 + (d - 0.075) * 0.2
	return minf(d, 0.11)

## Puncture / pinch flat: the tyre deflates over the next second or so.
func puncture() -> void:
	blown = true
