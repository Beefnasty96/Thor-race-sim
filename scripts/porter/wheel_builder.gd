class_name WheelBuilder
extends RefCounted
## Low-poly wheel + tire built from the tire size, GT1 style: an N-sided
## drum with the cut-out wheel picture on both faces and dark rubber on the
## tread. The axle runs along X; the outer face looks toward +X.
## Surfaces: 0 = faces (photo texture), 1 = tread and shoulders (rubber).

const RUBBER := Color(0.07, 0.07, 0.075)

static func build(radius: float, width: float, sides: int = 16) -> ArrayMesh:
	var hw := width * 0.5
	var am := ArrayMesh.new()
	# --- faces: a disc on each side, UVs map the circular crop
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [1.0, -1.0]:
		var x: float = hw * side
		var n := Vector3(side, 0, 0)
		var c := Vector3(x, 0, 0)
		for i in sides:
			var a0 := TAU * i / sides
			var a1 := TAU * (i + 1) / sides
			var p0 := Vector3(x, cos(a0) * radius, sin(a0) * radius)
			var p1 := Vector3(x, cos(a1) * radius, sin(a1) * radius)
			# the picture's right edge points to -Z in wheel space (toward the
			# car's rear once a left wheel is turned to face outward)
			var uv0 := Vector2(0.5 - 0.5 * sin(a0), 0.5 - 0.5 * cos(a0))
			var uv1 := Vector2(0.5 - 0.5 * sin(a1), 0.5 - 0.5 * cos(a1))
			# angle grows counter-clockwise seen from +X, clockwise from -X;
			# Godot draws clockwise triangles as front faces
			var order := [[c, Vector2(0.5, 0.5)], [p1, uv1], [p0, uv0]] if side > 0.0 \
				else [[c, Vector2(0.5, 0.5)], [p0, uv0], [p1, uv1]]
			for v in order:
				st.set_normal(n)
				st.set_uv(v[1])
				st.add_vertex(v[0])
	st.commit(am)
	# --- tread band (flat-shaded quads)
	var tr := SurfaceTool.new()
	tr.begin(Mesh.PRIMITIVE_TRIANGLES)
	tr.set_color(RUBBER)
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var am_ := (a0 + a1) * 0.5
		var n := Vector3(0, cos(am_), sin(am_))
		var q := [Vector3(hw, cos(a0) * radius, sin(a0) * radius), Vector3(hw, cos(a1) * radius, sin(a1) * radius),
			Vector3(-hw, cos(a1) * radius, sin(a1) * radius), Vector3(-hw, cos(a0) * radius, sin(a0) * radius)]
		for k in [0, 1, 2, 0, 2, 3]:
			tr.set_normal(n)
			tr.add_vertex(q[k])
	tr.commit(am)
	return am

## Materials for the two surfaces: the wheel picture (or plain dark grey) and rubber.
static func materials(tex: Texture2D) -> Array:
	var face := StandardMaterial3D.new()
	face.roughness = 0.5
	if tex:
		face.albedo_texture = tex
	else:
		face.albedo_color = Color(0.35, 0.36, 0.38)
	var rubber := StandardMaterial3D.new()
	rubber.albedo_color = RUBBER
	rubber.roughness = 0.9
	return [face, rubber]
