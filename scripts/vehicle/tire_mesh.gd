class_name TireMesh
extends RefCounted
## Low-poly tire built from its size (GT1 style, flat-shaded), so cars only
## need a wheel (rim) model and the game renders the rubber itself. The tire
## squash shader then flattens the contact patch, bulges the sidewalls and
## rolls the tread sideways from the simulation (load, pressure, cornering).
##
## The axle runs along X, centred on the origin. The cross-section goes
## bead -> sidewall bulge -> shoulder -> tread edge, mirrored (224 triangles at 16 sides)
## to the other side. The rim face covers the hole inside the beads.
## UV: u = around the tire (0..1), v = across the profile (0 = outer bead,
## 1 = inner bead), for sidewall lettering later.

const RUBBER := Color(0.06, 0.06, 0.065)

## radius: tire outer radius (m). width: section width (m). rim_radius: bead
## seat radius (m), i.e. rim diameter / 2. Material resource name is "Tire".
static func build(radius: float, width: float, rim_radius: float, sides: int = 16) -> ArrayMesh:
	var am := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	add_to(st, radius, width, rim_radius, sides)
	st.commit(am)
	var m := StandardMaterial3D.new()
	m.resource_name = "Tire"
	m.albedo_color = RUBBER
	m.roughness = 0.9
	am.surface_set_material(0, m)
	am.surface_set_name(0, "Tire")
	return am

## The profile as (x, r) points from the outer bead (x > 0) to the inner bead.
static func profile(radius: float, width: float, rim_radius: float) -> PackedVector2Array:
	var hw := width * 0.5
	var rr := clampf(rim_radius, radius * 0.3, radius * 0.92)
	var sh := radius - rr
	var half := [
		Vector2(hw * 0.80, rr),                                  # bead (on the rim flange)
		Vector2(hw * 1.00, rr + sh * 0.55),                      # sidewall, widest point
		Vector2(hw * 0.94, radius - minf(0.016, sh * 0.15)),     # shoulder
		Vector2(hw * 0.80, radius),                              # tread edge
	]
	var out := PackedVector2Array()
	for p in half:
		out.append(p)
	for i in range(half.size() - 1, -1, -1):
		out.append(Vector2(-half[i].x, half[i].y))
	return out

## Append the tire triangles to an open SurfaceTool (flat normals, outward).
static func add_to(st: SurfaceTool, radius: float, width: float, rim_radius: float, sides: int = 16) -> void:
	var prof := profile(radius, width, rim_radius)
	var n_p := prof.size()
	for j in n_p - 1:
		var a := prof[j]
		var b := prof[j + 1]
		# outward normal of this profile segment in (x, r): direction rotated
		var d := (b - a).normalized()
		var n2 := Vector2(d.y, -d.x)
		for i in sides:
			var t0 := TAU * i / sides
			var t1 := TAU * (i + 1) / sides
			var tm := (t0 + t1) * 0.5
			var n := Vector3(n2.x, n2.y * cos(tm), n2.y * sin(tm)).normalized()
			var q := [_pt(a, t0), _pt(a, t1), _pt(b, t1), _pt(b, t0)]
			var uv := [Vector2(float(i) / sides, float(j) / (n_p - 1)), Vector2(float(i + 1) / sides, float(j) / (n_p - 1)),
				Vector2(float(i + 1) / sides, float(j + 1) / (n_p - 1)), Vector2(float(i) / sides, float(j + 1) / (n_p - 1))]
			# Godot front faces: (b - a) x (c - a) points away from the viewer
			var order := [0, 1, 2, 0, 2, 3]
			if (q[1] - q[0]).cross(q[2] - q[0]).dot(n) > 0.0:
				order = [0, 2, 1, 0, 3, 2]
			for k in order:
				st.set_normal(n)
				st.set_uv(uv[k])
				st.add_vertex(q[k])

static func _pt(p: Vector2, ang: float) -> Vector3:
	return Vector3(p.x, cos(ang) * p.y, sin(ang) * p.y)

static func triangle_count(sides: int = 16) -> int:
	return sides * 7 * 2
