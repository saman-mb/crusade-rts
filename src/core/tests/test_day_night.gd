extends GdTest
## Pure-logic tests for DayNight (Story L2, #83): ramp interpolation, cyclic
## wrap, keyframe-exactness, and clock advance/scrub. No Node deps.
## Run: godot --headless --script res://src/core/tests/test_day_night.gd


func _run() -> void:
	_test_keyframes_exact()
	_test_midpoint_interpolates()
	_test_wraps_at_one()
	_test_wrap_segment_blends_dusk_to_night()
	_test_noon_bright_night_dim()
	_test_advance_wraps()
	_test_advance_frozen_is_noop()
	_test_scrub_wraps()
	_test_custom_ramp()


# --- helpers ---

## Approximate Color equality (per-channel), with an expected/got diagnostic.
func _c_eq(a: Color, b: Color, msg: String) -> void:
	var close := (absf(a.r - b.r) < 0.001 and absf(a.g - b.g) < 0.001
		and absf(a.b - b.b) < 0.001 and absf(a.a - b.a) < 0.001)
	_ok(close, "%s: expected %s got %s" % [msg, b, a])


# --- tests ---

## Every keyframe time returns that keyframe's color exactly.
func _test_keyframes_exact() -> void:
	var dn := DayNight.new()
	_c_eq(dn.color_at(0.00), Color(0.16, 0.20, 0.38), "midnight keyframe exact")
	_c_eq(dn.color_at(0.25), Color(0.95, 0.70, 0.55), "dawn keyframe exact")
	_c_eq(dn.color_at(0.50), Color(1.00, 1.00, 1.00), "noon keyframe exact")
	_c_eq(dn.color_at(0.75), Color(0.98, 0.62, 0.42), "dusk keyframe exact")

## Halfway between midnight (0.0) and dawn (0.25) is the channel average.
func _test_midpoint_interpolates() -> void:
	var dn := DayNight.new()
	var mid := dn.color_at(0.125)
	var expect := Color(0.16, 0.20, 0.38).lerp(Color(0.95, 0.70, 0.55), 0.5)
	_c_eq(mid, expect, "0.125 is midnight/dawn midpoint")

## color_at wraps at 1.0: color_at(1.0) == color_at(0.0); >1 and <0 wrap too.
func _test_wraps_at_one() -> void:
	var dn := DayNight.new()
	_c_eq(dn.color_at(1.0), dn.color_at(0.0), "color_at(1.0) == color_at(0.0)")
	_c_eq(dn.color_at(1.25), dn.color_at(0.25), "color_at(1.25) == color_at(0.25)")
	_c_eq(dn.color_at(-0.25), dn.color_at(0.75), "color_at(-0.25) == color_at(0.75)")

## The closing segment blends dusk(0.75) -> midnight(0.0 as 1.0); the midpoint
## (t=0.875) is the average of those two stops, proving the seam is continuous.
func _test_wrap_segment_blends_dusk_to_night() -> void:
	var dn := DayNight.new()
	var mid := dn.color_at(0.875)
	var expect := Color(0.98, 0.62, 0.42).lerp(Color(0.16, 0.20, 0.38), 0.5)
	_c_eq(mid, expect, "0.875 blends dusk->midnight across the seam")

## Sanity on the design intent: noon is bright (near white), night is dim & blue.
func _test_noon_bright_night_dim() -> void:
	var dn := DayNight.new()
	var noon := dn.color_at(0.5)
	var night := dn.color_at(0.0)
	_ok(noon.r > 0.9 and noon.g > 0.9 and noon.b > 0.9, "noon is bright")
	_ok(night.r < 0.5 and night.g < 0.5, "night is dim")
	_ok(night.b > night.r and night.b > night.g, "night is blue-dominant")

## advance() moves t forward and wraps past 1.0.
func _test_advance_wraps() -> void:
	var dn := DayNight.new(DayNight.DEFAULT_RAMP, 0.0, 10.0)  # 10s cycle
	dn.advance(2.5)
	_ok(absf(dn.t - 0.25) < 0.0001, "advance 2.5s of 10s -> t=0.25")
	dn.advance(10.0)  # a full cycle returns to the same t
	_ok(absf(dn.t - 0.25) < 0.0001, "advancing a full cycle wraps to same t")

## A frozen cycle (cycle_seconds <= 0) does not advance.
func _test_advance_frozen_is_noop() -> void:
	var dn := DayNight.new(DayNight.DEFAULT_RAMP, 0.4, 0.0)
	dn.advance(5.0)
	_ok(absf(dn.t - 0.4) < 0.0001, "frozen cycle ignores advance")

## scrub nudges t directly and wraps negative.
func _test_scrub_wraps() -> void:
	var dn := DayNight.new(DayNight.DEFAULT_RAMP, 0.1, 120.0)
	dn.scrub(-0.2)
	_ok(absf(dn.t - 0.9) < 0.0001, "scrub -0.2 from 0.1 wraps to 0.9")

## A custom two-stop ramp interpolates between the supplied colors.
func _test_custom_ramp() -> void:
	var ramp: Array = [[0.0, Color(0, 0, 0)], [0.5, Color(1, 1, 1)]]
	var dn := DayNight.new(ramp, 0.0, 60.0)
	_c_eq(dn.color_at(0.25), Color(0.5, 0.5, 0.5), "custom ramp midpoint is grey")
	_c_eq(dn.color_at(0.75), Color(0.5, 0.5, 0.5), "custom ramp wrap midpoint is grey")
