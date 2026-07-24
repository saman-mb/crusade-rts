shader_type canvas_item;
// Terrain tint (#233): multiplies the terrain by a smooth, low-frequency value-
// noise sampled in WORLD space, so brightness and hue drift gently across the map
// like a natural meadow -- lighter and darker patches, faint warm/cool zones --
// with NO tile boundary (the variation is continuous, unlike a per-tile modulate,
// which would re-trace the grid). Deterministic: pure hash noise, no textures, no
// time. Applied to each elevation TileMapLayer; it multiplies UNDER the DayNight
// CanvasModulate and the per-tier elevation shade, so those still read normally.

uniform float tint_amp : hint_range(0.0, 0.4) = 0.16;   // brightness swing (+/-)
uniform float tint_freq = 0.0016;                        // cycles per world pixel (low = broad patches)
uniform float hue_amp : hint_range(0.0, 0.2) = 0.05;    // warm/cool swing
uniform vec3 warm = vec3(1.04, 1.0, 0.90);
uniform vec3 cool = vec3(0.94, 1.0, 1.05);

varying vec2 v_world;

void vertex() {
	// Local vertex -> world space, so the noise is continuous across every tile
	// and every layer rather than restarting per tile.
	v_world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Two-octave fractal noise for broad patches with a little detail.
float fbm(vec2 p) {
	return 0.65 * vnoise(p) + 0.35 * vnoise(p * 2.13 + vec2(11.7, 4.3));
}

void fragment() {
	float n = fbm(v_world * tint_freq);
	float bright = 1.0 + (n - 0.5) * 2.0 * tint_amp;
	// A second, offset noise chooses a warm<->cool bias; hue_amp scales how far
	// from neutral white that bias is allowed to push.
	float h = fbm(v_world * tint_freq * 0.7 + vec2(50.0, 20.0));   // 0..1
	vec3 hue = mix(vec3(1.0), mix(cool, warm, h), hue_amp * 4.0);
	COLOR.rgb *= bright * hue;
}
