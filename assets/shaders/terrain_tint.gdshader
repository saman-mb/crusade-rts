shader_type canvas_item;
// Terrain tint + RELIEF (#233). The ground is drawn from 128x64 diamond tiles, and
// ANY relief authored per-tile (a normal map) creates a lit/shadowed crease at each
// diamond edge -> a visible grid. The fix (per lead-artist direction): compute BOTH
// the colour drift AND the relief shading from smooth noise sampled in WORLD space,
// so there is no frequency at the tile pitch for the eye to lock onto -- the grass
// reads as one continuous surface, like StarCraft terrain. The paired normal map is
// flattened to near-neutral so the DirectionalLight2D sun no longer creases tiles;
// this shader owns the terrain's undulation instead. Deterministic: pure hash noise.

// --- colour drift ---
uniform float tint_amp : hint_range(0.0, 0.4) = 0.10;    // brightness swing (+/-)
uniform float tint_freq = 0.0016;                         // cycles per world px (low = broad patches)
uniform float hue_amp : hint_range(0.0, 0.2) = 0.045;    // warm/cool swing
uniform vec3 warm = vec3(1.03, 1.0, 0.93);
uniform vec3 cool = vec3(0.95, 1.0, 1.04);
// --- world-space relief lighting (fake directional sun -> warm-lit / cool-shadow) ---
uniform float relief_slope = 26.0;                        // how steep the noise "hills" tilt normals
uniform vec3 sun_dir = vec3(-0.45, -0.35, 0.82);         // screen-space; sun from upper-left, +z up
uniform vec3 shadow_tone = vec3(0.46, 0.54, 0.76);       // cool + DIM: real shadow low-notes
uniform vec3 highlight_tone = vec3(1.30, 1.12, 0.80);    // bright warm-white sun-side
uniform vec3 rim_color = vec3(1.0, 0.81, 0.54);          // additive warm rim on the brightest facets
uniform float rim_strength : hint_range(0.0, 0.5) = 0.18;

varying vec2 v_world;

void vertex() {
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

float fbm(vec2 p) {
	return 0.65 * vnoise(p) + 0.35 * vnoise(p * 2.13 + vec2(11.7, 4.3));
}

// Continuous world-space "ground height": macro undulation + meso grain + micro
// tactile detail, periods in world px (~896 / ~160 / ~48). No tile-pitch frequency.
float height(vec2 w) {
	return 0.55 * vnoise(w / 896.0) + 0.30 * vnoise(w / 160.0) + 0.15 * vnoise(w / 48.0);
}

void fragment() {
	// Colour drift: smooth broad brightness + a gentle warm<->cool hue bias.
	float n = fbm(v_world * tint_freq);
	float bright = 1.0 + (n - 0.5) * 2.0 * tint_amp;
	float hsel = fbm(v_world * tint_freq * 0.7 + vec2(50.0, 20.0));
	vec3 hue = mix(vec3(1.0), mix(cool, warm, hsel), hue_amp * 4.0);

	// Relief: derive a normal from the world-space height gradient, Lambert-shade
	// it with the sun. Because height() is continuous, the shading crosses tile
	// boundaries with no seam.
	float e = 3.0;
	float hx = height(v_world + vec2(e, 0.0)) - height(v_world - vec2(e, 0.0));
	float hy = height(v_world + vec2(0.0, e)) - height(v_world - vec2(0.0, e));
	vec3 nrm = normalize(vec3(-hx * relief_slope, -hy * relief_slope, 1.0));
	float lam = clamp(dot(nrm, normalize(sun_dir)) * 0.5 + 0.5, 0.0, 1.0);
	// Gradient-map the relief to warm-lit / cool-shadow (the fake golden-hour sun the
	// terrain never receives from Light2D), plus an ADDITIVE warm rim on the brightest
	// facets so light reads as light, not tint.
	vec3 relief_col = mix(shadow_tone, highlight_tone, lam);
	vec3 rim = rim_color * pow(lam, 3.0) * rim_strength;

	COLOR.rgb = COLOR.rgb * bright * hue * relief_col + rim;
}
