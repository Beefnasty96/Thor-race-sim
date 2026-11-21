// Body paint with the GMT400 two-tone drawn as a texture in model space, so the
// lines are crisp and need no extra geometry:
//   lower colour 0.00-0.58 m | chrome pinstripe | black molding band | chrome pinstripe |
//   lower colour 0.69-0.75 m | body colour above. Horizontal panels stay body colour.
shader_type spatial;

uniform vec3 body_color : source_color = vec3(0.2, 0.25, 0.45);
uniform vec3 lower_color : source_color = vec3(0.62, 0.52, 0.40);
uniform vec3 band_color : source_color = vec3(0.12, 0.12, 0.13);
uniform float body_metallic = 0.5;
uniform float lower_metallic = 0.5;
uniform bool two_tone = true;
uniform float y_lower_top = 0.58;
uniform float y_band_bot = 0.588;
uniform float y_band_top = 0.682;
uniform float y_upper_bot = 0.69;
uniform float y_upper_top = 0.75;

varying vec3 mpos;
varying vec3 mnrm;

void vertex() {
	mpos = VERTEX;
	mnrm = NORMAL;
}

// 0 -> 1 across an edge at h, anti-aliased by screen-space derivative
float edge(float y, float h) {
	float w = max(fwidth(y), 0.0005);
	return smoothstep(h - w, h + w, y);
}

void fragment() {
	vec3 col = body_color;
	float met = body_metallic;
	float rough = 0.28;
	float side = 1.0 - smoothstep(0.55, 0.7, abs(normalize(mnrm).y));
	if (two_tone && side > 0.0) {
		float y = mpos.y;
		// layers from bottom to top
		vec3 c = lower_color; float m = lower_metallic; float r = 0.30;
		float e1 = edge(y, y_lower_top);     // -> chrome
		c = mix(c, vec3(0.86), e1); m = mix(m, 1.0, e1); r = mix(r, 0.12, e1);
		float e2 = edge(y, y_band_bot);      // -> black band
		c = mix(c, band_color, e2); m = mix(m, 0.2, e2); r = mix(r, 0.45, e2);
		float e3 = edge(y, y_band_top);      // -> chrome
		c = mix(c, vec3(0.86), e3); m = mix(m, 1.0, e3); r = mix(r, 0.12, e3);
		float e4 = edge(y, y_upper_bot);     // -> lower colour strip
		c = mix(c, lower_color, e4); m = mix(m, lower_metallic, e4); r = mix(r, 0.30, e4);
		float e5 = edge(y, y_upper_top);     // -> body colour
		c = mix(c, body_color, e5); m = mix(m, body_metallic, e5); r = mix(r, 0.28, e5);
		col = mix(col, c, side);
		met = mix(met, m, side);
		rough = mix(rough, r, side);
	}
	ALBEDO = col;
	METALLIC = met;
	ROUGHNESS = rough;
	CLEARCOAT = 1.0;
	CLEARCOAT_ROUGHNESS = 0.06;
}
