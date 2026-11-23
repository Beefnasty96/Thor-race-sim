class_name WheelBuilder
extends RefCounted
## Low-poly wheel built from the tire size, GT1 style: the rim is an N-sided
## disc on each side with the cut-out rim picture, set at the tire's bead.
## The tire around it is the same TireMesh the game builds (in the game it
## squashes and flexes with the simulation; this is the preview at rest).
## The axle runs along X; the outer face looks toward +X.
## Surfaces: 0 = rim faces (photo texture), 1 = tire (rubber).

const RUBBER := TireMesh.RUBBER

static func build(radius: float, width: float, rim_radius: float = -1.0, sides: int = 16) -> ArrayMesh:
	if rim_radius <= 0.0:
		rim_radius = radius * 0.525
	var hw := width * 0.5 * 0.80          # rim faces sit at the bead
	var am := ArrayMesh.new()
	var tire_r := radius
	radius = rim_radius
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
	# --- the tire
	var tr := SurfaceTool.new()
	tr.begin(Mesh.PRIMITIVE_TRIANGLES)
	TireMesh.add_to(tr, tire_r, width, rim_radius, sides)
	tr.commit(am)
	return am

## Materials for the two surfaces: the rim picture (or plain grey) and rubber.
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
