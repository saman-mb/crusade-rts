extends GdTest
## Pure-logic tests for ElevationShade (Story L4, #85): the per-tier modulate
## ramp that makes higher elevation tiers catch more light. No Node deps.
## Run: godot --headless --script res://src/core/tests/test_elevation_shade.gd


func _run() -> void:
	_test_ground_is_neutral()
	_test_negative_level_is_neutral()
	_test_higher_tiers_are_brighter()
	_test_lift_is_warm_biased()
	_test_alpha_always_opaque()
	_test_zero_step_is_flat()
	_test_custom_step_scales()
	_test_lift_is_clamped()


# --- helpers ---

## Approximate Color equality (per-channel), with an expected/got diagnostic.
func _c_eq(a: Color, b: Color, msg: String) -> void:
	var close := (absf(a.r - b.r) < 0.0001 and absf(a.g - b.g) < 0.0001
		and absf(a.b - b.b) < 0.0001 and absf(a.a - b.a) < 0.0001)
	_ok(close, "%s: expected %s got %s" % [msg, b, a])

## Perceptual-ish luminance so "brighter" is a single comparable number.
func _lum(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


# --- tests ---

## Tier 0 (ground) is EXACTLY neutral white, so existing flat single-tier maps
## render identically to pre-L4 (the modulate is a no-op there).
func _test_ground_is_neutral() -> void:
	_c_eq(ElevationShade.shade_at(0), Color(1, 1, 1, 1), "tier 0 modulate is neutral white")

## Defensive: a negative level clamps to the neutral baseline, never darkens.
func _test_negative_level_is_neutral() -> void:
	_c_eq(ElevationShade.shade_at(-1), Color(1, 1, 1, 1), "negative level clamps to neutral")

## The core contract: luminance rises strictly with elevation, so a higher tier
## always reads as catching more light than the one below it.
func _test_higher_tiers_are_brighter() -> void:
	var l0 := _lum(ElevationShade.shade_at(0))
	var l1 := _lum(ElevationShade.shade_at(1))
	var l2 := _lum(ElevationShade.shade_at(2))
	_ok(l1 > l0, "tier 1 brighter than tier 0 (%f > %f)" % [l1, l0])
	_ok(l2 > l1, "tier 2 brighter than tier 1 (%f > %f)" % [l2, l1])
	# The lift is above 1.0 (Forward+ overbright), not a darkening.
	_ok(ElevationShade.shade_at(1).r > 1.0, "tier 1 modulate is > 1.0 (brighten, not darken)")

## The added light is warm (sun-ward): red channel >= blue channel on raised
## tiers, so higher ground catches "more sun" rather than a flat grey lift.
func _test_lift_is_warm_biased() -> void:
	var c1 := ElevationShade.shade_at(1)
	var c2 := ElevationShade.shade_at(2)
	_ok(c1.r >= c1.b, "tier 1 lift is warm (r %f >= b %f)" % [c1.r, c1.b])
	_ok(c2.r >= c2.b, "tier 2 lift is warm (r %f >= b %f)" % [c2.r, c2.b])

## Modulate stays fully opaque at every tier — shading must never bleed alpha.
func _test_alpha_always_opaque() -> void:
	for level in [0, 1, 2, 5]:
		_ok(is_equal_approx(ElevationShade.shade_at(level).a, 1.0),
			"tier %d modulate alpha is 1.0" % level)

## step == 0 disables the height cue: every tier is neutral (opt-out path used by
## the exported `elevation_shade_step = 0`).
func _test_zero_step_is_flat() -> void:
	for level in [0, 1, 2, 3]:
		_c_eq(ElevationShade.shade_at(level, 0.0), Color(1, 1, 1, 1),
			"step 0 keeps tier %d neutral" % level)

## A custom step scales the lift linearly with level (before the clamp): tier 2
## at step s lifts exactly twice as much over white as tier 1 at step s.
func _test_custom_step_scales() -> void:
	var step := 0.05
	var tint := ElevationShade.DEFAULT_TINT
	var d1 := ElevationShade.shade_at(1, step, tint).r - 1.0
	var d2 := ElevationShade.shade_at(2, step, tint).r - 1.0
	_ok(absf(d2 - 2.0 * d1) < 0.0001, "tier 2 lift is 2x tier 1 lift (%f vs %f)" % [d2, d1])
	_ok(absf(d1 - tint.r * step) < 0.0001, "tier 1 red lift == tint.r * step")

## A deep stack / large step cannot drive the lift past MAX_LIFT, so the top
## tiers never clip arbitrarily bright.
func _test_lift_is_clamped() -> void:
	# step 0.2 * level 10 = 2.0 raw, clamped to MAX_LIFT.
	var c := ElevationShade.shade_at(10, 0.2, Color(1, 1, 1))
	var lift := c.r - 1.0
	_ok(absf(lift - ElevationShade.MAX_LIFT) < 0.0001,
		"lift clamps to MAX_LIFT (%f == %f)" % [lift, ElevationShade.MAX_LIFT])
