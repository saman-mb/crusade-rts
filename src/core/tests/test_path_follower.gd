extends GdTest
## Pure-math tests for PathFollower (#76): the continuous-steering integrator that
## slides a unit through NavGraph's { cell, tier } waypoints in LIFTED world space.
## Run: godot --headless --script res://src/core/tests/test_path_follower.gd
##
## These assert the four load-bearing guarantees with no live scene: straight-line
## interpolation between waypoint centers, arrival-and-stop (no drift past the end),
## the tier HANDOFF at a reached ramp-top waypoint (with the art rising along the
## lifted segment on the way up), large-delta no-overshoot, and re-pathing. All
## world targets are EntityPlacement.visual_position, so the expectations are built
## from that same source rather than re-deriving iso geometry inline.


func _run() -> void:
	_test_interpolation_half_segment()
	_test_arrival_and_stop()
	_test_ramp_tier_handoff()
	_test_ramp_segment_progress()
	_test_large_delta_no_overshoot()
	_test_no_path()
	_test_repath_resets()


# --- helpers ---

## Approximate Vector2 equality via distance (lifted iso math returns floats).
func _v_approx(a: Vector2, b: Vector2) -> bool:
	return a.distance_to(b) < 0.001


# --- tests ---

## One advance whose budget is exactly HALF the segment length lands the unit on
## the segment midpoint -- proving it steers straight toward the waypoint center
## in lifted world space, not by grid hops.
func _test_interpolation_half_segment() -> void:
	var start: Vector2 = EntityPlacement.visual_position(Vector2i(0, 0), 0)
	var goal: Vector2 = EntityPlacement.visual_position(Vector2i(4, 0), 0)
	var seg_len: float = start.distance_to(goal)

	var pf := PathFollower.new()
	pf.speed = seg_len       # with delta 0.5 the budget is exactly half the segment
	pf.set_path([
		{ "cell": Vector2i(0, 0), "tier": 0 },
		{ "cell": Vector2i(4, 0), "tier": 0 },
	])

	var out: Dictionary = pf.advance(start, 0.5)
	var pos: Vector2 = out["pos"]
	var mid: Vector2 = start.lerp(goal, 0.5)
	_ok(_v_approx(pos, mid), "half-budget advance lands on segment midpoint")
	_ok(not bool(out["done"]), "still mid-segment, not done")


## Iterating advance to completion parks the unit within `arrival_tolerance` of the
## final waypoint, flips is_done() true, and a further advance is a pure no-op
## (no drift past the endpoint).
func _test_arrival_and_stop() -> void:
	var goal: Vector2 = EntityPlacement.visual_position(Vector2i(4, 0), 0)

	var pf := PathFollower.new()
	pf.speed = 96.0
	pf.set_path([
		{ "cell": Vector2i(0, 0), "tier": 0 },
		{ "cell": Vector2i(4, 0), "tier": 0 },
	])

	var pos: Vector2 = EntityPlacement.visual_position(Vector2i(0, 0), 0)
	var guard: int = 0
	while not pf.is_done() and guard < 1000:
		var out: Dictionary = pf.advance(pos, 0.1)
		pos = out["pos"]
		guard += 1

	_ok(pf.is_done(), "follower reports done after arriving")
	_ok(pos.distance_to(goal) <= pf.arrival_tolerance, "final pos within arrival tolerance of goal")

	# A further advance must not move the unit (no drift).
	var again: Dictionary = pf.advance(pos, 0.1)
	var again_pos: Vector2 = again["pos"]
	_ok(_v_approx(again_pos, pos), "advance after done does not drift")
	_ok(bool(again["done"]), "advance after done still reports done")


## The tier HANDOFF: crossing a ramp from low (tier 0) to high (tier 1), the unit
## interpolates along the LIFTED line between the two targets and keeps tier 0 until
## it actually REACHES the high waypoint, at which instant the tier flips to 1.
func _test_ramp_tier_handoff() -> void:
	var low_cell := Vector2i(2, 2)
	var high_cell := Vector2i(2, 1)
	var low_target: Vector2 = EntityPlacement.visual_position(low_cell, 0)
	var high_target: Vector2 = EntityPlacement.visual_position(high_cell, 1)
	var seg_len: float = low_target.distance_to(high_target)

	var pf := PathFollower.new()
	pf.speed = seg_len       # delta 0.25 -> quarter of the way up the ramp
	pf.set_path([
		{ "cell": low_cell, "tier": 0 },
		{ "cell": high_cell, "tier": 1 },
	])

	# (a) Partway up: still tier 0, and the position lies on the lerp line between
	#     the two lifted targets (the visible RISE across the slope).
	var partway: Dictionary = pf.advance(low_target, 0.25)
	var partway_pos: Vector2 = partway["pos"]
	var partway_tier: int = partway["tier"]
	var expected_partway: Vector2 = low_target.lerp(high_target, 0.25)
	_ok(partway_tier == 0, "mid-ramp still reports the tier being left (0)")
	_ok(not bool(partway["done"]), "mid-ramp not done")
	_ok(_v_approx(partway_pos, expected_partway), "mid-ramp pos on the lifted lerp line")

	# (b) The advance that reaches the top hands off to tier 1 and finishes.
	var top: Dictionary = pf.advance(partway_pos, 1.0)
	var top_pos: Vector2 = top["pos"]
	var top_cell: Vector2i = top["cell"]
	var top_tier: int = top["tier"]
	_ok(top_tier == 1, "tier flips to 1 exactly when the high waypoint is reached")
	_ok(top_cell == high_cell, "cell handed off to the high waypoint")
	_ok(bool(top["done"]), "reaching the final (high) waypoint is done")
	_ok(_v_approx(top_pos, high_target), "snapped exactly onto the high target")


## The cross-tier RENDER segment fields (#79): climbing a ramp, advance reports
## from_tier == the tier being left, to_tier == the higher tier, and tier_progress
## sweeping 0->1 across the segment. At the top handoff the segment resets to flat
## (from == to, progress reflects the next flat segment), so a renderer feeding these
## to ElevationLerp gets a smooth rise then a clean hold -- no snap.
func _test_ramp_segment_progress() -> void:
	var low_cell := Vector2i(2, 2)
	var high_cell := Vector2i(2, 1)
	var low_target: Vector2 = EntityPlacement.visual_position(low_cell, 0)
	var high_target: Vector2 = EntityPlacement.visual_position(high_cell, 1)
	var seg_len: float = low_target.distance_to(high_target)

	var pf := PathFollower.new()
	pf.speed = seg_len       # delta 0.25 -> a quarter of the way up the ramp
	pf.set_path([
		{ "cell": low_cell, "tier": 0 },
		{ "cell": high_cell, "tier": 1 },
	])

	# Quarter of the way up: reports the low->high segment with ~0.25 progress.
	var q: Dictionary = pf.advance(low_target, 0.25)
	var q_from: int = q["from_tier"]
	var q_to: int = q["to_tier"]
	var q_prog: float = q["tier_progress"]
	_ok(q_from == 0, "mid-ramp from_tier is the tier being left (0)")
	_ok(q_to == 1, "mid-ramp to_tier is the higher tier (1)")
	_ok(absf(q_prog - 0.25) < 0.001, "mid-ramp tier_progress ~0.25")
	# The interpolated offset lies strictly between the two tier heights.
	var mid_off: Vector2 = ElevationLerp.offset(q_from, q_to, q_prog)
	_ok(mid_off.y < MapConstants.elevation_offset(0).y and mid_off.y > MapConstants.elevation_offset(1).y,
		"mid-ramp interpolated offset strictly between the tiers")

	# Reach the top: occupancy is tier 1 and, done, the segment is flat at tier 1 with
	# progress 1.0 -> ElevationLerp resolves to the exact tier-1 offset (clean hold).
	var top: Dictionary = pf.advance(q["pos"], 1.0)
	var t_from: int = top["from_tier"]
	var t_to: int = top["to_tier"]
	var t_prog: float = top["tier_progress"]
	_ok(t_from == 1 and t_to == 1, "after handoff the segment is flat at tier 1")
	_ok(absf(t_prog - 1.0) < 0.001, "settled segment progress is 1.0")
	_ok(ElevationLerp.offset(t_from, t_to, t_prog) == MapConstants.elevation_offset(1),
		"settled offset equals the exact tier-1 height")


## A single huge-delta advance across three CLOSE waypoints stops EXACTLY on the
## final one -- the loop consumes the intermediate waypoints without overshoot.
func _test_large_delta_no_overshoot() -> void:
	var final_cell := Vector2i(2, 0)
	var final_target: Vector2 = EntityPlacement.visual_position(final_cell, 0)

	var pf := PathFollower.new()
	pf.speed = 96.0
	pf.set_path([
		{ "cell": Vector2i(0, 0), "tier": 0 },
		{ "cell": Vector2i(1, 0), "tier": 0 },
		{ "cell": final_cell, "tier": 0 },
	])

	var start: Vector2 = EntityPlacement.visual_position(Vector2i(0, 0), 0)
	var out: Dictionary = pf.advance(start, 10000.0)   # budget dwarfs the whole path
	var pos: Vector2 = out["pos"]
	_ok(_v_approx(pos, final_target), "huge delta stops exactly on the final waypoint")
	_ok(bool(out["done"]), "huge delta across all waypoints is done")
	_ok(pf.is_done(), "follower reports done after consuming the whole path")


## An empty path is inert: has_path() is false and advance is a strict no-op that
## returns the caller's own position and done == true.
func _test_no_path() -> void:
	var pf := PathFollower.new()
	pf.set_path([])
	_ok(not pf.has_path(), "empty path has no path")
	_ok(pf.is_done(), "empty path is done")

	var p := Vector2(123.0, -45.0)
	var out: Dictionary = pf.advance(p, 0.5)
	var pos: Vector2 = out["pos"]
	_ok(_v_approx(pos, p), "advance with no path returns the input position")
	_ok(bool(out["done"]), "advance with no path reports done")


## Re-pathing mid-follow abandons the old route: is_done() clears, the index rewinds,
## and subsequent advances converge on the NEW path's final waypoint.
func _test_repath_resets() -> void:
	var pf := PathFollower.new()
	pf.speed = 96.0

	# Path A, walked partway.
	pf.set_path([
		{ "cell": Vector2i(0, 0), "tier": 0 },
		{ "cell": Vector2i(6, 0), "tier": 0 },
	])
	var pos: Vector2 = EntityPlacement.visual_position(Vector2i(0, 0), 0)
	var mid: Dictionary = pf.advance(pos, 0.1)
	pos = mid["pos"]
	_ok(not pf.is_done(), "still following path A partway")

	# Swap to path B (a different destination) before A finished.
	var b_goal_cell := Vector2i(0, 5)
	var b_goal: Vector2 = EntityPlacement.visual_position(b_goal_cell, 0)
	pf.set_path([
		{ "cell": Vector2i(0, 0), "tier": 0 },
		{ "cell": b_goal_cell, "tier": 0 },
	])
	_ok(not pf.is_done(), "re-path clears done")
	_ok(pf.has_path(), "re-path installs a fresh route")

	# Converge on B's final waypoint from the current (off-B) position.
	var guard: int = 0
	while not pf.is_done() and guard < 1000:
		var out: Dictionary = pf.advance(pos, 0.1)
		pos = out["pos"]
		guard += 1
	_ok(pf.is_done(), "converges on path B")
	_ok(pos.distance_to(b_goal) <= pf.arrival_tolerance, "settles on path B's final waypoint")
