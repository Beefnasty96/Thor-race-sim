// Tyre squash: flattens the tread against the ground plane and bulges the
// sidewalls near the contact patch. Per-wheel uniforms are set every frame by
// CarModel from the physics (tyre deflection + ground normal in mesh space).
shader_type spatial;

uniform vec4 albedo : source_color = vec4(0.05, 0.05, 0.05, 1.0);
uniform float roughness = 0.9;
uniform vec3 down_dir = vec3(0.0, -1.0, 0.0);   // ground direction, mesh space
uniform float radius = 0.387;                    // undeformed tyre radius
uniform float squash = 0.0;                      // m flattened at the contact patch
uniform float bead_r = 0.21;                     // rim seat: never moves
uniform float bulge = 3.2;                       // sidewall bulge per m of squash

void vertex() {
	vec3 p = VERTEX;
	vec3 dn = normalize(down_dir);
	float lim = radius - squash;
	float d = dot(p, dn);
	float rr = length(p.yz);
	// sidewall bulge, strongest right at the contact patch, none at the bead
	float near = smoothstep(lim - 0.16, lim, d);
	float wall = smoothstep(bead_r, bead_r + 0.07, rr);
	p.x *= 1.0 + bulge * squash * near * wall;
	// flatten anything below the ground plane
	if (d > lim) {
		p -= dn * (d - lim);
		NORMAL = normalize(mix(NORMAL, dn, 0.75));
	}
	VERTEX = p;
}

void fragment() {
	ALBEDO = albedo.rgb;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
}
