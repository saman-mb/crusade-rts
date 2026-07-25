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
uniform float tint_amp : hint_range(0.0, 0.4) = 0.08;    // brightness swing (+/-) -- trimmed (#241 nit 4: mid-field read a touch blotchy)
uniform float tint_freq = 0.0016;                         // cycles per world px (low = broad patches)
uniform float hue_amp : hint_range(0.0, 0.2) = 0.036;    // warm/cool swing -- trimmed 20% (#241 nit 4: the BROWN drift read patchy-dirt in the mid-field)
uniform vec3 warm = vec3(1.03, 1.0, 0.93);
uniform vec3 cool = vec3(0.95, 1.0, 1.04);
// --- world-space relief lighting (fake directional sun -> warm-lit / cool-shadow) ---
// Lead-artist contrast rebalance: shadow end multiplies toward a DIM cool tone
// (~#4A5570 at 0.45 value) while highlights push a bright warm-white -- roughly a
// 2.7:1 light ratio, where the flat look was ~1.5:1. Contrast lives HERE (in the
// lighting), not in the albedo, which stays within a narrow luminance band.
uniform float relief_slope = 26.0;                        // how steep the noise "hills" tilt normals
uniform vec3 sun_dir = vec3(-0.45, -0.35, 0.82);         // screen-space; sun from upper-left, +z up
uniform vec3 shadow_tone = vec3(0.34, 0.43, 0.26);       // deep JUNGLE-green shadow (SC1 anchor #4a5a28)
uniform vec3 highlight_tone = vec3(1.30, 1.18, 0.82);    // warm ochre sun side (SC1 anchor #b3a34e)
uniform vec3 rim_color = vec3(1.0, 0.81, 0.54);          // additive warm rim on the brightest facets
uniform float rim_strength : hint_range(0.0, 0.5) = 0.16;
// --- point firelight (#252) -----------------------------------------------------
// Warm pools of firelight that live in the SAME continuous world-space pass as the
// relief above -- so the glow has NO tile-pitch frequency and reads as light lying
// on the ground, not a sprite clipped to a diamond. fire_count defaults to 0, so the
// real game pays nothing and looks unchanged; only the showcase turns these on.
const int FIRE_MAX = 8;
uniform int fire_count = 0;
uniform vec2 fire_pos[FIRE_MAX];                          // world-space fire centres
uniform vec3 fire_color = vec3(1.0, 0.58, 0.24);          // warm ember tone
uniform float fire_radius = 260.0;                        // pool reach in world px
uniform float fire_strength : hint_range(0.0, 3.0) = 1.15;

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
// tactile detail. No tile-pitch frequency. The macro octave is sampled in a
// frame STRETCHED 2:1 along the NW->SE sun axis at a long ~1200px period, so the
// shading reads as raking light across long swells -- small round macro spots
// read as leopard-print dirt blotches (lead-artist note), long swells read as
// terrain under a low sun.
float height(vec2 w) {
	vec2 axis = normalize(vec2(2.0, 1.0));                 // NW->SE sun sweep on screen
	vec2 perp = vec2(-axis.y, axis.x);
	vec2 sw = vec2(dot(w, axis) * 0.4, dot(w, perp));      // 2.5:1 stretch along the axis
	// Long raking swells + a whisper of fine tooth. NO mid octave: mid-frequency
	// blobs at high amplitude read as camo mottle, not terrain (lead-artist note).
	return 0.85 * vnoise(sw / 1500.0) + 0.15 * vnoise(w / 72.0);
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

	// Land takes the full grass relief tint; WATER must NOT. The green/ochre relief
	// greens the blue surface, and its world-space height swells land a different
	// average value in each tile-window crop -> a hard stepped chevron at every water
	// tile edge. Detect water by its blue-dominant albedo and give it a flat, hue-
	// preserving directional sheen instead (the ripple crests + sun glint baked into
	// the albedo carry the surface interest).
	float wness = smoothstep(0.0, 0.10, COLOR.b - COLOR.r) * smoothstep(0.20, 0.35, COLOR.b);
	vec3 land_c = COLOR.rgb * bright * hue * relief_col + rim;
	vec3 water_c = COLOR.rgb * (0.94 + 0.10 * clamp(lam, 0.0, 1.0));   // flatter sheen -> softens the residual mid-lake value band
	COLOR.rgb = mix(land_c, water_c, wness);

	// Firelight pools: additive warm glow, distance measured on the GROUND plane
	// (y stretched 2:1 to match the dimetric tiles) so each pool is a soft ellipse
	// lying flat on the terrain. Quadratic falloff = a bright core, gentle skirt.
	vec3 fire = vec3(0.0);
	for (int i = 0; i < fire_count; i++) {
		if (i >= FIRE_MAX) { break; }
		vec2 dv = v_world - fire_pos[i];
		dv.y *= 2.0;                                       // undo iso foreshorten
		float f = 1.0 - smoothstep(0.0, fire_radius, length(dv));
		fire += fire_color * (f * f) * fire_strength;
	}
	COLOR.rgb += fire;
}
