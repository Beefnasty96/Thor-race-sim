// GT3-style baked body: a low-poly shell whose detail lives in textures.
//   detail_tex : baked albedo of everything that isn't paint (paint = white)
//   mask_tex   : R paint, G chrome/bright metal, B tail lamp, A ambient occlusion
// Paint colour + GMT400 two-tone (lower colour, black band, chrome pinstripes)
// are applied here so any paint scheme works with the same bake.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D detail_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D mask_tex : filter_linear_mipmap, repeat_disable;
uniform vec3 body_color : source_color = vec3(0.2, 0.25, 0.45);
uniform vec3 lower_color : source_color = vec3(0.62, 0.52, 0.40);
uniform vec3 band_color : source_color = vec3(0.12, 0.12, 0.13);
uniform float body_metallic = 0.5;
uniform float lower_metallic = 0.5;
uniform bool two_tone = true;
uniform float brake = 0.0;
uniform float ao_strength = 0.85;

varying vec3 mpos;
varying vec3 mnrm;

void vertex() {
	mpos = VERTEX;
	mnrm = NORMAL;
}

float edge(float y, float h) {
	float w = max(fwidth(y), 0.0005);
	return smoothstep(h - w, h + w, y);
}

void fragment() {
	vec3 detail = texture(detail_tex, UV).rgb;
	vec4 mk = texture(mask_tex, UV);
	// paint, with the two-tone on the sides
	vec3 pc = body_color; float pm = body_metallic; float pr = 0.28;
	float side = 1.0 - smoothstep(0.55, 0.7, abs(normalize(mnrm).y));
	if (two_tone && side > 0.0) {
		float y = mpos.y;
		vec3 c = lower_color; float m = lower_metallic; float r = 0.30;
		float e1 = edge(y, 0.58);  c = mix(c, vec3(0.86), e1); m = mix(m, 1.0, e1); r = mix(r, 0.12, e1);
		float e2 = edge(y, 0.588); c = mix(c, band_color, e2); m = mix(m, 0.2, e2); r = mix(r, 0.45, e2);
		float e3 = edge(y, 0.682); c = mix(c, vec3(0.86), e3); m = mix(m, 1.0, e3); r = mix(r, 0.12, e3);
		float e4 = edge(y, 0.69);  c = mix(c, lower_color, e4); m = mix(m, lower_metallic, e4); r = mix(r, 0.30, e4);
		float e5 = edge(y, 0.75);  c = mix(c, body_color, e5); m = mix(m, body_metallic, e5); r = mix(r, 0.28, e5);
		pc = mix(pc, c, side); pm = mix(pm, m, side); pr = mix(pr, r, side);
	}
	float paint = mk.r;
	float chrome = mk.g * (1.0 - paint);
	float ao = mix(1.0, mk.a, ao_strength);
	vec3 col = mix(detail, pc, paint);
	ALBEDO = col * ao;
	METALLIC = mix(mix(0.0, 1.0, chrome), pm, paint);
	ROUGHNESS = mix(mix(0.55, 0.12, chrome), pr, paint);
	CLEARCOAT = paint;
	CLEARCOAT_ROUGHNESS = 0.06;
	EMISSION = vec3(1.0, 0.06, 0.02) * mk.b * (0.25 + 2.5 * brake) * ao;
}
