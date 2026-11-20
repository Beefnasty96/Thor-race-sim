extends Node
## Global game state: loaded car definitions, the player's vehicle setup
## (what the Vehicle Editor changes), persistent wear, and settings.

const SAVE_PATH := "user://save.json"
const CAR_DIR := "res://data/cars/"

var cars: Dictionary = {}          # id -> definition dictionary
var current_car_id := "chevrolet_tahoe_1996"

## Player-adjustable setup for the current car. Keys are read by VehicleConfig.
var setup: Dictionary = {}

## Persistent condition of the car (carried between sessions).
var condition: Dictionary = {
	"engine_health": 1.0,       # 1.0 = new, 0 = seized
	"odometer_km": 0.0,
	"tire_tread_mm": [-1.0, -1.0, -1.0, -1.0],   # -1 = new set
}

var settings: Dictionary = {
	"units": "imperial",         # imperial | metric
	"steer_sensitivity": 1.0,
	"steer_linearity": 1.6,      # >1 = finer control near center
	"camera": 0,
	"show_telemetry": true,
}

var best_laps: Dictionary = {}   # "track|car|body|drive" -> seconds

func _ready() -> void:
	_load_cars()
	setup = default_setup(current_car_id)
	load_game()

func _load_cars() -> void:
	var dir := DirAccess.open(CAR_DIR)
	if dir == null:
		push_error("Car directory missing")
		return
	for f in dir.get_files():
		if f.ends_with(".json"):
			var txt := FileAccess.get_file_as_string(CAR_DIR + f)
			var d = JSON.parse_string(txt)
			if d is Dictionary:
				cars[d["id"]] = d

func car_def(id: String = "") -> Dictionary:
	return cars.get(id if id != "" else current_car_id, {})

func default_setup(id: String) -> Dictionary:
	var d := car_def(id)
	if d.is_empty():
		return {}
	return {
		"body": "4door",
		"drivetrain": d["drivetrain"]["default"],
		"transfer": "2H",                       # 2H / 4H / 4L (4wd only)
		"rear_diff": d["drivetrain"]["rear_diff"],
		"final_drive": d["transmission"]["final_drive"],
		"trans_mode": "auto",                   # auto | manual
		"tire_psi_front": d["tires"]["cold_pressure_psi"],
		"tire_psi_rear": d["tires"]["cold_pressure_psi"],
		"spring_scale_front": 1.0,
		"spring_scale_rear": 1.0,
		"damper_scale": 1.0,
		"arb_scale_front": 1.0,
		"arb_scale_rear": 1.0,
		"ride_height_offset_mm": 0.0,
		"brake_bias_front": 0.69,
		"brake_power": 1.0,
		"abs": d["brakes"]["abs"],
		"tcs": false,
		"speed_limiter": d["limits"]["speed_limiter_default"],
		"paint": 1,
		"camber_front_deg": -0.3,
		"camber_rear_deg": 0.0,
	}

func setup_key() -> String:
	return "%s|%s|%s" % [current_car_id, setup.get("body", ""), setup.get("drivetrain", "")]

func save_game() -> void:
	var data := {
		"setup": setup, "condition": condition, "settings": settings,
		"best_laps": best_laps, "car": current_car_id,
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "  "))

func load_game() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if not (d is Dictionary):
		return
	for k in d.get("setup", {}):
		setup[k] = d["setup"][k]
	for k in d.get("condition", {}):
		condition[k] = d["condition"][k]
	for k in d.get("settings", {}):
		settings[k] = d["settings"][k]
	best_laps = d.get("best_laps", {})

func service_engine() -> void:
	condition["engine_health"] = 1.0
	save_game()

func new_tires() -> void:
	condition["tire_tread_mm"] = [-1.0, -1.0, -1.0, -1.0]
	save_game()

# ---------- unit helpers ----------
func speed_str(ms: float) -> String:
	if settings["units"] == "metric":
		return "%d" % roundi(ms * 3.6)
	return "%d" % roundi(ms * 2.23694)

func speed_unit() -> String:
	return "km/h" if settings["units"] == "metric" else "mph"

func temp_str(c: float) -> String:
	if settings["units"] == "metric":
		return "%d°C" % roundi(c)
	return "%d°F" % roundi(c * 1.8 + 32.0)

static func fmt_time(t: float) -> String:
	if t <= 0.0 or t > 3600.0:
		return "--:--.---"
	var m := int(t / 60.0)
	var s := t - m * 60.0
	return "%d:%06.3f" % [m, s]
