// Recolour a photo-textured car body: pixels whose colour is close to the
// car's paint (sampled in Car Porter) are treated as paint and get a new
// colour, keeping the photo's light and shade (reflections, panel gaps,
// creases); everything else (badges, chrome, rubber, lights) keeps its photo
// colour. Matching is by hue angle (plus a softer saturation term), so
// shadows and highlights on the paint still match.
//   override_tex (R): 0.5 = automatic, 1 = always paint, 0 = never paint
//   (the touch-up brush)
// The same maths is in PaintKey (GDScript) for export / tests.
shader_type spatial;

uniform sampler2D photo : source_color, filter_linear_mipmap;
uniform sampler2D override_tex : filter_linear;
uniform bool has_override = false;
uniform vec3 key_color : source_color = vec3(0.6, 0.05, 0.05);
uniform float tolerance = 0.22;
uniform vec3 new_color : source_color = vec3(0.12, 0.2, 0.45);
uniform bool recolor = true;
uniform bool show_mask = false;       // tint paint pixels instead (to check the match)

// luma, Cb, Cr
vec3 ycc(vec3 c) {
	float y = dot(c, vec3(0.299, 0.587, 0.114));
	return vec3(y, (c.b - y) * 0.564, (c.r - y) * 0.713);
}

// hue angle (stable from shadow to sunlit) + softer saturation term; for
// white / black / silver paint (no hue) brightness instead
float paint_distance(vec3 c, vec3 key) {
	vec3 a = ycc(c);
	vec3 k = ycc(key);
	float sat_a = length(a.yz) / (a.x + 0.02);
	float sat_k = length(k.yz) / (k.x + 0.02);
	float grey = 1.0 - smoothstep(0.08, 0.2, sat_k);
	float dang = abs(mod(atan(a.z, a.y) - atan(k.z, k.y) + 3.14159265, 6.2831853) - 3.14159265);
	float d = (1.0 - grey) * (dang * 0.5 + abs(log((sat_a + 0.02) / (sat_k + 0.02))) * 0.15);
	d += grey * (1.6 * abs(a.x - k.x) + 0.8 * max(sat_a - 0.15, 0.0));
	return d;
}

float paint_amount(vec3 c, vec2 uv) {
	float y = dot(c, vec3(0.299, 0.587, 0.114));
	float m = 1.0 - smoothstep(tolerance * 0.7, tolerance, paint_distance(c, key_color));
	// near-black and blown-out pixels carry no paint hue: leave them alone
	m *= smoothstep(0.015, 0.05, y) * (1.0 - smoothstep(0.9, 0.98, y));
	if (has_override) {
		float o = texture(override_tex, uv).r;
		if (o > 0.75) { m = 1.0; }
		else if (o < 0.25) { m = 0.0; }
	}
	return m;
}

void fragment() {
	vec3 c = texture(photo, UV).rgb;
	float m = paint_amount(c, UV);
	vec3 outc = c;
	if (show_mask) {
		outc = mix(c * 0.35, vec3(0.2, 0.75, 1.0), m * 0.85);
	} else if (recolor) {
		float y = dot(c, vec3(0.299, 0.587, 0.114));
		float ky = max(dot(key_color, vec3(0.299, 0.587, 0.114)), 0.03);
		vec3 painted = new_color * clamp(y / ky, 0.0, 3.0);
		// keep bright specular highlights white-ish
		painted = mix(painted, vec3(y), smoothstep(0.75, 0.95, y) * 0.6);
		outc = mix(c, painted, m);
	}
	ALBEDO = outc;
	ROUGHNESS = 0.6;
}
