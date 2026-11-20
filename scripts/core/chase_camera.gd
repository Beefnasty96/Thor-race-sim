class_name ChaseCamera
extends Camera3D
## Racing cameras: far chase, near chase, hood, bumper. Plus an orbit mode
## for menus (slow turntable around the car, GT-style).

enum Mode { CHASE_FAR, CHASE_NEAR, COCKPIT, HOOD, BUMPER, ORBIT }
const MODE_NAMES := ["Chase", "Near chase", "Driver", "Hood", "Bumper"]
const DRIVEN_MODES := 5

var target: Vehicle
var mode := Mode.CHASE_FAR
var look_yaw := 0.0
var look_back := false
var _pos := Vector3.ZERO
var _yaw_vel_dir := Vector3.FORWARD
var _orbit := 2.4
var _initialised := false
var cockpit_eye := Vector3(-0.38, 1.46, 0.38)
var _head := Vector3.ZERO

func cycle() -> void:
	mode = ((mode + 1) % DRIVEN_MODES) as Mode
	_initialised = false

func snap() -> void:
	_initialised = false

func _physics_process(dt: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	var xf := target.global_transform
	var b := xf.basis.orthonormalized()
	var fwd := -b.z
	var up := Vector3.UP
	var body_len: float = target.body_def.get("length_m", 5.0)
	near = 0.05
	match mode:
		Mode.ORBIT:
			_orbit += dt * 0.18
			var c := xf.origin + Vector3.UP * 0.9
			var off := Vector3(sin(_orbit), 0, cos(_orbit)) * 7.5 + Vector3.UP * 1.6
			global_position = c + off
			look_at(c, Vector3.UP)
			fov = 42.0
			return
		Mode.CHASE_FAR, Mode.CHASE_NEAR:
			var dist := 8.5 if mode == Mode.CHASE_FAR else 6.2
			var height := 2.9 if mode == Mode.CHASE_FAR else 2.2
			# follow velocity direction when moving so slides are visible
			var vel := target.linear_velocity
			var dir := fwd
			if vel.length() > 3.0:
				dir = fwd.lerp(vel.normalized(), 0.35).normalized()
			_yaw_vel_dir = _yaw_vel_dir.slerp(Vector3(dir.x, 0, dir.z).normalized(), clampf(dt * 4.0, 0, 1)) if _initialised else Vector3(dir.x, 0, dir.z).normalized()
			var d := _yaw_vel_dir.rotated(Vector3.UP, look_yaw + (PI if look_back else 0.0))
			var want := xf.origin - d * dist + up * height
			if not _initialised:
				_pos = want
				_initialised = true
			_pos = _pos.lerp(want, clampf(dt * 9.0, 0, 1))
			global_position = _pos
			look_at(xf.origin + up * 1.1 + d * 2.0, Vector3.UP)
			fov = 62.0 + clampf(target.speed_ms * 0.12, 0.0, 8.0)
		Mode.COCKPIT:
			# driver's eye; head leans against g-forces, turns with the right stick
			var want_head := Vector3(-target.g_lat * 0.035, 0.0, target.g_long * 0.03)
			_head = _head.lerp(want_head, clampf(dt * 6.0, 0, 1))
			var eye := xf * (cockpit_eye + _head)
			global_position = eye
			var yaw := look_yaw + (PI if look_back else 0.0)
			global_transform.basis = b * Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, deg_to_rad(-7.0))
			fov = 70.0
			near = 0.03
			return
		Mode.HOOD:
			var p := xf * Vector3(0.0, 1.55, -body_len * 0.5 + 1.6)
			global_position = p
			var d2 := fwd.rotated(up, look_yaw + (PI if look_back else 0.0))
			look_at(p + d2 * 10.0 + up * -0.6, b.y)
			fov = 70.0
		Mode.BUMPER:
			var p2 := xf * Vector3(0.0, 0.75, -body_len * 0.5 - 0.15)
			global_position = p2
			var d3 := fwd.rotated(up, look_yaw + (PI if look_back else 0.0))
			look_at(p2 + d3 * 10.0, b.y)
			fov = 72.0
