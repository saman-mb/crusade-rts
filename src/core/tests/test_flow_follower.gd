extends GdTest
## Pure-behaviour tests for FlowFollower (#80): the flow-field + separation steering
## integrator that walks a crowd along ONE shared FlowField in lifted world space.
## Run: godot --headless --script res://src/core/tests/test_flow_follower.gd
##
## Built against the REAL FlowField + Steering cores in-process (no mocks): each test
## constructs a synthetic FlowField over a small grid via a walkability closure, then
## drives one or more FlowFollowers frame-by-frame with loop-guarded budgets (the
## convergence-loop style of test_path_follower.gd). All world targets/positions come
## from EntityPlacement.visual_position, so expectations are built from that same
## source rather than re-deriving iso geometry inline.
##
## CROSS-TIER IS DEFERRED (#80): FlowField is single-tier and every follower here is
## pinned to tier 0. A follower riding the field up a ramp onto tier 1 (a
## PathFollower-style tier handoff on reach) is future work; these tests fix tier 0.

const TIER := 0
const DELTA := 0.1          ## per-frame step (s); with speed 96 px/s -> ~9.6 px/frame.
const GUARD := 4000         ## hard frame cap so a non-converging follower fails fast.


func _run() -> void:
	_test_single_unit_convergence_open()
	_test_obstacle_routing_no_penetration()
	_test_separation_spreads_group()
	_test_no_wall_penetration_under_crowding()
	_test_group_convergence_from_back_row()


# --- helpers ---

## Approximate Vector2 equality via distance (lifted iso math returns floats).
func _v_approx(a: Vector2, b: Vector2, eps: float = 0.001) -> bool:
	return a.distance_to(b) < eps


## World position of a cell's art anchor on tier 0 (the space followers integrate in).
func _wpos(cell: Vector2i) -> Vector2:
	return EntityPlacement.visual_position(cell, TIER)


## The grid cell a world position sits in (mirrors FlowFollower's own derivation).
func _cell_of(world_pos: Vector2) -> Vector2i:
	return IsoCoord.pick_cell(world_pos - EntityPlacement.visual_offset(TIER))


## An open (everywhere-walkable within `region`) walkability closure.
func _open_walkable(region: Rect2i) -> Callable:
	return func(cell: Vector2i) -> bool:
		return region.has_point(cell)


## The positions of every follower EXCEPT `self_index`. FlowFollower is fed its
## neighbours, not itself: Steering.separation treats a coincident point (which a
## unit's own position would be) as a huge fixed push, so the caller excludes self --
## exactly as the harness feeds each unit the OTHER units' positions.
func _others(positions: PackedVector2Array, self_index: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in positions.size():
		if i != self_index:
			out.append(positions[i])
	return out


## Drives a single follower (empty neighbours) from `start` until done or the guard
## trips; returns { pos, frames, done }.
func _run_to_done(follower: FlowFollower, start: Vector2) -> Dictionary:
	var pos: Vector2 = start
	var done: bool = false
	var frames: int = 0
	var empty := PackedVector2Array()
	while not done and frames < GUARD:
		var out: Dictionary = follower.advance(pos, empty, DELTA)
		pos = out["pos"]
		done = out["done"]
		frames += 1
	return { "pos": pos, "frames": frames, "done": done }


# --- tests ---

## Single unit on an OPEN grid follows the flow home: it reaches the goal cell,
## reports done, and parks within arrival tolerance of the goal's world position.
func _test_single_unit_convergence_open() -> void:
	var region := Rect2i(0, 0, 12, 12)
	var goal := Vector2i(10, 6)
	var field := FlowField.new(region, _open_walkable(region), goal)

	var follower := FlowFollower.new(field, TIER)
	var start: Vector2 = _wpos(Vector2i(1, 6))
	var res: Dictionary = _run_to_done(follower, start)

	var pos: Vector2 = res["pos"]
	var done: bool = res["done"]
	_ok(done, "open-grid single unit reaches done")
	_v_eq(_cell_of(pos), goal, "settles on the goal cell")
	# It stops on ENTERING the goal cell (cost 0), so its world pos lies within that
	# cell's diamond -- at most a half-tile from the goal centre, never adrift.
	_ok(pos.distance_to(_wpos(goal)) <= MapConstants.TILE_SIZE.x / 2.0 + 1.0,
		"final pos inside the goal cell's diamond")


## A wall with a single gap forces a detour; the unit still converges AND never once
## ends a frame on a non-walkable cell (the field routes it through the gap).
func _test_obstacle_routing_no_penetration() -> void:
	var region := Rect2i(0, 0, 12, 12)
	var gap_y := 6
	var wall_x := 6
	# Solid vertical wall at x==wall_x except the single gap cell at y==gap_y.
	var walkable: Callable = func(cell: Vector2i) -> bool:
		if not region.has_point(cell):
			return false
		if cell.x == wall_x and cell.y != gap_y:
			return false
		return true
	var goal := Vector2i(10, 2)
	var field := FlowField.new(region, walkable, goal)

	# Start on the far side of the wall from the goal, on a DIFFERENT row than the
	# gap, so a straight line is blocked and the unit must route down to the gap.
	var follower := FlowFollower.new(field, TIER)
	var pos: Vector2 = _wpos(Vector2i(1, 2))
	var done: bool = false
	var frames: int = 0
	var penetrated: bool = false
	var empty := PackedVector2Array()
	while not done and frames < GUARD:
		var out: Dictionary = follower.advance(pos, empty, DELTA)
		pos = out["pos"]
		done = out["done"]
		if field.cost_at(_cell_of(pos)) == FlowField.UNREACHABLE:
			penetrated = true
		frames += 1

	_ok(done, "obstacle-routed unit still converges")
	_ok(not penetrated, "unit never ends a frame inside the wall")
	_v_eq(_cell_of(pos), goal, "obstacle-routed unit settles on the goal cell")


## Followers seeded on the SAME cell (only sub-cell jitter apart) push each other
## apart via separation: final pairwise spacing exceeds their initial spacing and a
## spread threshold, YET the group still makes net progress toward the goal.
func _test_separation_spreads_group() -> void:
	var region := Rect2i(0, 0, 16, 16)
	var goal := Vector2i(13, 7)
	var field := FlowField.new(region, _open_walkable(region), goal)

	var n := 3
	var followers: Array[FlowFollower] = []
	var positions := PackedVector2Array()
	var start_cell := Vector2i(2, 7)
	var base: Vector2 = _wpos(start_cell)
	for i in n:
		followers.append(FlowFollower.new(field, TIER))
		# Tiny deterministic offset within the one cell so separation has a non-zero
		# gradient to act on (identical positions produce no push).
		positions.append(base + Vector2((i - (n - 1) / 2.0) * 3.0, 0.0))

	var start_min_gap: float = _min_pairwise(positions)
	var start_centroid_dist: float = _centroid(positions).distance_to(_wpos(goal))

	# Step a fixed window, each follower fed the OTHER followers' current positions.
	for _frame in 60:
		var next := PackedVector2Array()
		for i in n:
			var out: Dictionary = followers[i].advance(positions[i], _others(positions, i), DELTA)
			var p: Vector2 = out["pos"]
			next.append(p)
		positions = next

	var end_min_gap: float = _min_pairwise(positions)
	var end_centroid_dist: float = _centroid(positions).distance_to(_wpos(goal))

	_ok(end_min_gap >= 12.0, "group spreads to a real spacing (min gap %.1f >= 12)" % end_min_gap)
	_ok(end_min_gap > start_min_gap, "group is more spread than it started (%.1f > %.1f)" % [end_min_gap, start_min_gap])
	_ok(end_centroid_dist < start_centroid_dist, "group still makes net progress toward the goal")


## A unit pinned beside a wall with a neighbour pushing it wall-ward never steps onto
## the non-walkable cell: the wall guard drops separation (and, if needed, the whole
## step) rather than penetrating.
func _test_no_wall_penetration_under_crowding() -> void:
	var region := Rect2i(0, 0, 12, 12)
	var wall_x := 5
	# Everything from x==wall_x rightward is solid; the unit lives just left of it.
	var walkable: Callable = func(cell: Vector2i) -> bool:
		if not region.has_point(cell):
			return false
		return cell.x < wall_x
	# Goal straight "up" (−y) so the flow pull itself never aims into the wall; only
	# the separation push is wall-ward, isolating the guard.
	var goal := Vector2i(4, 0)
	var field := FlowField.new(region, walkable, goal)

	var follower := FlowFollower.new(field, TIER)
	var pos: Vector2 = _wpos(Vector2i(4, 8))
	# Wall-ward world direction (toward +x cell). A neighbour placed OPPOSITE this,
	# close enough to be inside the separation radius, pushes the unit toward the wall.
	var wallward: Vector2 = (_wpos(Vector2i(5, 8)) - _wpos(Vector2i(4, 8))).normalized()
	var pushed_into_wall: bool = false
	for _frame in 30:
		var neighbours := PackedVector2Array([pos - wallward * 18.0])
		var out: Dictionary = follower.advance(pos, neighbours, DELTA)
		pos = out["pos"]
		if field.cost_at(_cell_of(pos)) == FlowField.UNREACHABLE:
			pushed_into_wall = true
	_ok(not pushed_into_wall, "crowded-against-wall unit never steps onto the solid cell")
	_ok(_cell_of(pos).x < wall_x, "unit stays on the walkable side of the wall")


## A back row of N followers sharing one field all reach a low-cost cell near the goal
## within a bounded frame budget (the crowd converges, not just a single unit).
func _test_group_convergence_from_back_row() -> void:
	var region := Rect2i(0, 0, 20, 12)
	var goal := Vector2i(16, 6)
	var field := FlowField.new(region, _open_walkable(region), goal)

	var n := 6
	var followers: Array[FlowFollower] = []
	var positions := PackedVector2Array()
	for i in n:
		followers.append(FlowFollower.new(field, TIER))
		positions.append(_wpos(Vector2i(2, 3 + i)))   # a back column spread across rows

	var budget := 3000
	var frames := 0
	var all_home := false
	while not all_home and frames < budget:
		var next := PackedVector2Array()
		for i in n:
			var out: Dictionary = followers[i].advance(positions[i], _others(positions, i), DELTA)
			var p: Vector2 = out["pos"]
			next.append(p)
		positions = next
		all_home = true
		for i in n:
			if field.cost_at(_cell_of(positions[i])) > 3:
				all_home = false
		frames += 1

	_ok(all_home, "every follower reaches a cell within cost 3 of the goal")
	_ok(frames < budget, "group converges inside the frame budget (used %d/%d)" % [frames, budget])


# --- small geometry helpers ---

## Smallest pairwise distance among a set of points (spread metric). Returns a large
## sentinel for < 2 points so callers never divide into an empty set.
func _min_pairwise(points: PackedVector2Array) -> float:
	var best: float = 1e20
	for i in points.size():
		for j in range(i + 1, points.size()):
			var d: float = points[i].distance_to(points[j])
			if d < best:
				best = d
	return best


## Arithmetic mean of a set of points.
func _centroid(points: PackedVector2Array) -> Vector2:
	var sum: Vector2 = Vector2.ZERO
	for p: Vector2 in points:
		sum += p
	if points.size() == 0:
		return sum
	return sum / float(points.size())
