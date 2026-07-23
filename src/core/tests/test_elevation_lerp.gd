extends GdTest
## Pure-math tests for ElevationLerp (#79): the smooth vertical interpolation of a
## unit's rendered elevation offset across a ramp, so a tier change no longer snaps
## the drawn height. Run: godot --headless --script res://src/core/tests/test_elevation_lerp.gd
##
## These fix the load-bearing guarantees with no live scene: the endpoints equal the
## EXACT discrete tier offsets (so it hands off seamlessly to the discrete rendering),
## progress is clamped so it never overshoots either tier height, the mid-ramp value
## lies strictly between the two, the traversal is monotonic, and a same-tier segment
## is a no-op. All expectations are built from MapConstants.elevation_offset -- the
## same source the core interpolates between -- rather than hard-coding the 32 px step.


func _run() -> void:
	_test_endpoints_exact()
	_test_clamp_no_overshoot()
	_test_midpoint_between()
	_test_monotonic_climb()
	_test_same_tier_is_noop()
	_test_descent_symmetric()
	_test_offset_y_matches()


# --- helpers ---

## Approximate float equality (lifted vector math returns floats).
func _f_approx(a: float, b: float) -> bool:
	return absf(a - b) < 0.0001


## Approximate Vector2 equality via distance.
func _v_approx(a: Vector2, b: Vector2) -> bool:
	return a.distance_to(b) < 0.0001


# --- tests ---

## progress 0 -> exactly the FROM tier's offset; progress 1 -> exactly the TO tier's.
func _test_endpoints_exact() -> void:
	var low: Vector2 = MapConstants.elevation_offset(0)
	var high: Vector2 = MapConstants.elevation_offset(1)
	_ok(_v_approx(ElevationLerp.offset(0, 1, 0.0), low), "progress 0 == from-tier offset")
	_ok(_v_approx(ElevationLerp.offset(0, 1, 1.0), high), "progress 1 == to-tier offset")
	# A 2-tier climb hits both exact ends too.
	var t0: Vector2 = MapConstants.elevation_offset(0)
	var t2: Vector2 = MapConstants.elevation_offset(2)
	_ok(_v_approx(ElevationLerp.offset(0, 2, 0.0), t0), "progress 0 == from over a 2-tier climb")
	_ok(_v_approx(ElevationLerp.offset(0, 2, 1.0), t2), "progress 1 == to over a 2-tier climb")


## progress below 0 or above 1 is clamped to the nearer endpoint -- no overshoot past
## either tier height.
func _test_clamp_no_overshoot() -> void:
	var low: Vector2 = MapConstants.elevation_offset(0)
	var high: Vector2 = MapConstants.elevation_offset(1)
	_ok(_v_approx(ElevationLerp.offset(0, 1, -5.0), low), "negative progress clamps to from-tier")
	_ok(_v_approx(ElevationLerp.offset(0, 1, 5.0), high), "over-1 progress clamps to to-tier")
	# Sweep well outside [0,1]: every sample stays within the two tier heights (no y
	# more extreme than either endpoint).
	var lo_y: float = min(low.y, high.y)
	var hi_y: float = max(low.y, high.y)
	var overshot: bool = false
	for k in range(-10, 21):
		var p: float = k / 10.0
		var y: float = ElevationLerp.offset(0, 1, p).y
		if y < lo_y - 0.0001 or y > hi_y + 0.0001:
			overshot = true
	_ok(not overshot, "no sampled offset overshoots the tier band")


## The midpoint of a climb lies STRICTLY between the two tier heights (a real
## in-between value, not snapped to either end).
func _test_midpoint_between() -> void:
	var low_y: float = MapConstants.elevation_offset(0).y
	var high_y: float = MapConstants.elevation_offset(1).y
	var mid_y: float = ElevationLerp.offset(0, 1, 0.5).y
	_ok(_f_approx(mid_y, (low_y + high_y) / 2.0), "midpoint is the exact average height")
	# high_y is more negative (higher on screen), so mid sits strictly between.
	_ok(mid_y < low_y and mid_y > high_y, "midpoint strictly between the two tier heights")


## Climbing tier 0 -> 1, the vertical offset is monotonically non-increasing (rises on
## screen: y grows more negative) as progress increases -- no wobble.
func _test_monotonic_climb() -> void:
	var prev_y: float = ElevationLerp.offset(0, 1, 0.0).y
	var monotonic: bool = true
	for k in range(1, 21):
		var p: float = k / 20.0
		var y: float = ElevationLerp.offset(0, 1, p).y
		if y > prev_y + 0.0001:   # y must not increase (must rise / go more negative)
			monotonic = false
		prev_y = y
	_ok(monotonic, "climb offset is monotonic (never dips back down)")
	# End strictly higher than start (net climb).
	_ok(ElevationLerp.offset(0, 1, 1.0).y < ElevationLerp.offset(0, 1, 0.0).y, "net rise across the climb")


## A flat segment (from_tier == to_tier) returns that tier's offset for every progress
## -- the interpolation never perturbs a unit on level ground.
func _test_same_tier_is_noop() -> void:
	var t1: Vector2 = MapConstants.elevation_offset(1)
	var noop: bool = true
	for k in range(0, 11):
		var p: float = k / 10.0
		if not _v_approx(ElevationLerp.offset(1, 1, p), t1):
			noop = false
	_ok(noop, "same-tier segment is a no-op for all progress")


## Descending (tier 1 -> 0) is the mirror of climbing: endpoints exact, and the
## offset falls monotonically (y grows less negative).
func _test_descent_symmetric() -> void:
	var high: Vector2 = MapConstants.elevation_offset(1)
	var low: Vector2 = MapConstants.elevation_offset(0)
	_ok(_v_approx(ElevationLerp.offset(1, 0, 0.0), high), "descent progress 0 == high tier")
	_ok(_v_approx(ElevationLerp.offset(1, 0, 1.0), low), "descent progress 1 == low tier")
	var prev_y: float = ElevationLerp.offset(1, 0, 0.0).y
	var monotonic: bool = true
	for k in range(1, 21):
		var p: float = k / 20.0
		var y: float = ElevationLerp.offset(1, 0, p).y
		if y < prev_y - 0.0001:   # y must not decrease (must fall / go less negative)
			monotonic = false
		prev_y = y
	_ok(monotonic, "descent offset is monotonic (never rises back up)")


## offset_y is exactly the y component of offset.
func _test_offset_y_matches() -> void:
	var same: bool = true
	for k in range(0, 11):
		var p: float = k / 10.0
		if not _f_approx(ElevationLerp.offset_y(0, 2, p), ElevationLerp.offset(0, 2, p).y):
			same = false
	_ok(same, "offset_y == offset(...).y for all progress")
