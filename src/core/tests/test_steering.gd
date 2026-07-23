extends GdTest
## Pure-math tests for Steering (#80): the local-avoidance vector core that blends
## a flow-field desired velocity with an inverse-distance separation push.
## Run: godot --headless --script res://src/core/tests/test_steering.gd
##
## These assert the load-bearing guarantees with no live scene: separation returns
## ZERO with nobody in range, pushes AWAY from a neighbour, is finite (never NaN)
## for coincident units, and lets the closer neighbour dominate the blend
## (inverse distance); combine preserves the pure-flow direction with zero
## separation, deflects under a real push, and clamps to max_speed; and
## desired_velocity scales a flow direction to speed (ZERO in -> ZERO out).


func _run() -> void:
	_test_separation_none_in_range()
	_test_separation_pushes_away()
	_test_separation_coincident_is_finite()
	_test_separation_inverse_distance_dominates()
	_test_desired_velocity_scales()
	_test_desired_velocity_zero()
	_test_combine_zero_separation_is_pure_flow()
	_test_combine_clamps_to_max_speed()
	_test_combine_deflects_under_separation()


# --- helpers ---

## Approximate Vector2 equality via distance (float vector math).
func _v_approx(a: Vector2, b: Vector2) -> bool:
	return a.distance_to(b) < 0.001


## Approximate float equality.
func _f_approx(a: float, b: float) -> bool:
	return absf(a - b) < 0.001


# --- separation ---

## Nobody within the radius -> no push at all.
func _test_separation_none_in_range() -> void:
	var neighbors := PackedVector2Array([Vector2(1000.0, 0.0)])
	var out: Vector2 = Steering.separation(Vector2.ZERO, neighbors, Steering.DEFAULT_SEPARATION_RADIUS)
	_ok(out == Vector2.ZERO, "no neighbour in range yields ZERO separation")


## A single neighbour to the RIGHT pushes the unit LEFT (negative x), on-axis.
func _test_separation_pushes_away() -> void:
	var neighbors := PackedVector2Array([Vector2(10.0, 0.0)])
	var out: Vector2 = Steering.separation(Vector2.ZERO, neighbors, 100.0)
	_ok(out.x < 0.0, "neighbour on the right pushes separation to negative x")
	_ok(_f_approx(out.y, 0.0), "on-axis neighbour produces no y push")
	_ok(_f_approx(out.length(), 1.0), "separation returns a unit direction")


## Coincident units (identical position, including a self-match) must NOT produce
## NaN/inf from the zero-vector normalize or the 1/0 inverse-distance weight.
func _test_separation_coincident_is_finite() -> void:
	var pos := Vector2(5.0, 5.0)
	var neighbors := PackedVector2Array([pos])
	var out: Vector2 = Steering.separation(pos, neighbors, 100.0)
	_ok(out.is_finite(), "coincident neighbour yields a finite (non-NaN) vector")
	_ok(_f_approx(out.length(), 1.0), "coincident push is a finite unit direction")


## Inverse distance: with a CLOSE neighbour on the x axis and a FARTHER one on the
## y axis, the closer neighbour's larger 1/dist weight dominates the blend, so the
## net separation leans more along x than y (|x| > |y|) -- the direct observable
## consequence of "closer => larger push" once the sum is normalized.
func _test_separation_inverse_distance_dominates() -> void:
	var near := Vector2(12.0, 0.0)   # close, to the right -> strong -x push
	var far := Vector2(0.0, 16.0)    # farther, below -> weaker -y push
	var neighbors := PackedVector2Array([near, far])
	var out: Vector2 = Steering.separation(Vector2.ZERO, neighbors, 100.0)
	_ok(out.x < 0.0, "push leans away from the near neighbour (negative x)")
	_ok(out.y < 0.0, "push also leans away from the far neighbour (negative y)")
	_ok(absf(out.x) > absf(out.y), "closer neighbour contributes the larger push (inverse distance)")


# --- desired_velocity ---

## A flow direction is scaled up to exactly max_speed, keeping its direction.
func _test_desired_velocity_scales() -> void:
	var out: Vector2 = Steering.desired_velocity(Vector2(3.0, 0.0), 96.0)
	_ok(_f_approx(out.length(), 96.0), "desired velocity magnitude == max_speed")
	_ok(_v_approx(out, Vector2(96.0, 0.0)), "desired velocity keeps the flow direction")


## A ZERO flow direction has nowhere to go -> ZERO.
func _test_desired_velocity_zero() -> void:
	var out: Vector2 = Steering.desired_velocity(Vector2.ZERO, 96.0)
	_ok(out == Vector2.ZERO, "zero flow direction yields zero desired velocity")


# --- combine ---

## With no separation the blend is the pure flow desired: same direction, and at
## max_speed (using unit flow_weight the flow desired passes through untouched).
func _test_combine_zero_separation_is_pure_flow() -> void:
	var flow_desired := Vector2(96.0, 0.0)   # already at max_speed
	var out: Vector2 = Steering.combine(flow_desired, Vector2.ZERO, 1.0, 1.0, 96.0)
	_ok(_v_approx(out, flow_desired), "zero separation equals the pure flow desired")
	_ok(_f_approx(out.length(), 96.0), "pure flow keeps magnitude == max_speed")


## An oversized blend is clamped down to max_speed (flow and separation stacking
## along the same axis would otherwise exceed it).
func _test_combine_clamps_to_max_speed() -> void:
	var flow_desired := Vector2(96.0, 0.0)   # +x at max_speed
	var sep := Vector2(1.0, 0.0)             # unit push, same axis -> stacks
	var out: Vector2 = Steering.combine(flow_desired, sep, 1.0, 1.0, 96.0)
	_ok(_f_approx(out.length(), 96.0), "combined magnitude is clamped to max_speed")
	_ok(out.x > 0.0, "clamped result still points along the stacked axis")


## A perpendicular separation visibly deflects the pure-flow direction.
func _test_combine_deflects_under_separation() -> void:
	var flow_desired := Vector2(96.0, 0.0)   # +x
	var sep := Vector2(0.0, 1.0)             # unit push straight up (+y)
	var out: Vector2 = Steering.combine(flow_desired, sep, 1.0, 1.0, 96.0)
	_ok(out.y > 0.0, "perpendicular separation deflects the flow toward +y")
	_ok(out.x > 0.0, "flow component survives the deflection")
	_ok(_f_approx(out.length(), 96.0), "deflected result stays clamped to max_speed")
