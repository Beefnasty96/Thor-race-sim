// Tinted glass drawn only where the GT1 body texture marks a window (alpha < 0.5).
shader_type spatial;
render_mode cull_back, depth_draw_never;

uniform sampler2D detail_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 tint : source_color = vec3(0.04, 0.06, 0.07);
uniform float opacity = 0.42;

void fragment() {
	if (texture(detail_tex, UV).a > 0.5) {
		discard;
	}
	ALBEDO = tint;
	ALPHA = opacity;
	METALLIC = 0.3;
	ROUGHNESS = 0.05;
}
