extends GdTest
## Pure-logic tests for FlowField (#80; headless, RefCounted only — no servers).
## Self-contained SceneTree runner: godot --headless --script <this file>.
## Guards the integration-field (BFS cost) contract, the 8-neighbour downhill flow,
## unreachable/off-region ZERO-flow behaviour, and bounded recompute().


func _run() -> void:
	_test_goal_is_zero()
	_test_monotonic_open_grid()
	_test_flow_reaches_goal()
	_test_full_wall_isolates()
	_test_wall_with_gap()
	_test_off_region()
	_test_recompute()


# --- helpers ---

## Walkability Callable that treats any cell in `blocked` as a hole/cliff/solid.
func _rule(blocked: Dictionary) -> Callable:
	return func(cell: Vector2i) -> bool:
		return not blocked.has(cell)

## Approximate Vector2 equality (flow vectors are normalized floats).
func _v2_eq(a: Vector2, b: Vector2, msg: String) -> void:
	_ok(a.is_equal_approx(b), "%s: expected %s got %s" % [msg, b, a])


# --- tests ---

## 1: the goal cell has cost 0 and no flow (it is the destination).
func _test_goal_is_zero() -> void:
	var goal := Vector2i(5, 5)
	var ff := FlowField.new(Rect2i(0, 0, 10, 10), _rule({}), goal)
	_i_eq(ff.cost_at(goal), 0, "goal cost == 0")
	_ok(ff.is_reachable(goal), "goal is reachable")
	_v2_eq(ff.flow_at(goal), Vector2.ZERO, "flow_at(goal) == ZERO")
	_ok(ff.goal == goal, "goal stored")
	_ok(ff.region == Rect2i(0, 0, 10, 10), "region stored")

## 2: on a fully-open 10x10 grid every walkable non-goal cell has a strictly-lower-cost
## neighbour, and flow_at points at a strictly-lower-cost neighbour (downhill).
func _test_monotonic_open_grid() -> void:
	var goal := Vector2i(0, 0)
	var ff := FlowField.new(Rect2i(0, 0, 10, 10), _rule({}), goal)
	var mono_ok: bool = true
	var flow_ok: bool = true
	for y in range(0, 10):
		for x in range(0, 10):
			var cell := Vector2i(x, y)
			if cell == goal:
				continue
			var here: int = ff.cost_at(cell)
			_ok(here != FlowField.UNREACHABLE, "open cell %s reachable" % cell)
			# There exists a strictly-lower-cost 8-neighbour.
			var has_lower: bool = false
			for d: Vector2i in [
				Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
				Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
			]:
				var nc: int = ff.cost_at(cell + d)
				if nc != FlowField.UNREACHABLE and nc < here:
					has_lower = true
			if not has_lower:
				mono_ok = false
			# flow_at points to a strictly-lower-cost neighbour.
			var f: Vector2 = ff.flow_at(cell)
			if f == Vector2.ZERO:
				flow_ok = false
			else:
				var step := Vector2i(roundi(f.x), roundi(f.y))
				var target_cost: int = ff.cost_at(cell + step)
				if target_cost == FlowField.UNREACHABLE or target_cost >= here:
					flow_ok = false
	_ok(mono_ok, "every non-goal cell has a strictly-lower-cost neighbour")
	_ok(flow_ok, "flow_at points downhill for every non-goal cell")

## 2b: following the flow from any cell reaches the goal in finite steps (loop-guarded).
func _test_flow_reaches_goal() -> void:
	var goal := Vector2i(9, 9)
	var ff := FlowField.new(Rect2i(0, 0, 10, 10), _rule({}), goal)
	var all_reached: bool = true
	for y in range(0, 10):
		for x in range(0, 10):
			var cell := Vector2i(x, y)
			var cur := cell
			var steps: int = 0
			var limit: int = 200  # generous loop guard: > any possible path length
			while cur != goal and steps < limit:
				var f: Vector2 = ff.flow_at(cur)
				if f == Vector2.ZERO:
					break
				cur += Vector2i(roundi(f.x), roundi(f.y))
				steps += 1
			if cur != goal:
				all_reached = false
	_ok(all_reached, "walking the flow from every cell reaches the goal")

## 3: a full vertical wall isolates the far side — those cells are UNREACHABLE with
## ZERO flow, and the solid wall cells themselves are UNREACHABLE.
func _test_full_wall_isolates() -> void:
	var blocked: Dictionary = {}
	for y in range(0, 10):
		blocked[Vector2i(5, y)] = true  # solid wall at x=5, all rows
	var goal := Vector2i(0, 5)  # left of the wall
	var ff := FlowField.new(Rect2i(0, 0, 10, 10), _rule(blocked), goal)
	# Far side (right of the wall) is unreachable.
	_i_eq(ff.cost_at(Vector2i(9, 5)), FlowField.UNREACHABLE, "far-side cell UNREACHABLE")
	_ok(not ff.is_reachable(Vector2i(9, 5)), "far-side cell not reachable")
	_v2_eq(ff.flow_at(Vector2i(9, 5)), Vector2.ZERO, "far-side cell ZERO flow")
	# A solid wall cell is itself unreachable with no flow.
	_i_eq(ff.cost_at(Vector2i(5, 5)), FlowField.UNREACHABLE, "solid cell UNREACHABLE")
	_v2_eq(ff.flow_at(Vector2i(5, 5)), Vector2.ZERO, "solid cell ZERO flow")
	# Near side is fine.
	_ok(ff.is_reachable(Vector2i(4, 5)), "near-side cell reachable")

## 4: a wall with a single-cell gap lets cost/flow thread through — far-side cells
## have finite cost and their flow eventually routes through the gap.
func _test_wall_with_gap() -> void:
	var blocked: Dictionary = {}
	for y in range(0, 9):
		blocked[Vector2i(5, y)] = true  # wall at x=5 for y 0..8, gap at (5,9)
	var goal := Vector2i(0, 0)  # left of the wall
	var ff := FlowField.new(Rect2i(0, 0, 10, 10), _rule(blocked), goal)
	var far := Vector2i(9, 0)  # top-right, behind the wall
	_ok(ff.is_reachable(far), "behind-wall cell reachable via gap")
	_ok(ff.cost_at(far) > 0, "behind-wall cell has positive cost")
	# The gap itself is the only crossing point and must be reachable.
	_ok(ff.is_reachable(Vector2i(5, 9)), "gap cell reachable")
	# Walking the flow from the far cell must pass through the gap column crossing.
	var cur := far
	var crossed_gap: bool = false
	var steps: int = 0
	while cur != goal and steps < 200:
		if cur == Vector2i(5, 9):
			crossed_gap = true
		var f: Vector2 = ff.flow_at(cur)
		if f == Vector2.ZERO:
			break
		cur += Vector2i(roundi(f.x), roundi(f.y))
		steps += 1
	_ok(cur == goal, "flow from behind the wall reaches the goal")
	_ok(crossed_gap, "flow threads through the gap at (5,9)")

## 5: an off-region cell reports UNREACHABLE and ZERO flow.
func _test_off_region() -> void:
	var ff := FlowField.new(Rect2i(0, 0, 10, 10), _rule({}), Vector2i(5, 5))
	_i_eq(ff.cost_at(Vector2i(-1, 0)), FlowField.UNREACHABLE, "off-region (neg) UNREACHABLE")
	_i_eq(ff.cost_at(Vector2i(10, 10)), FlowField.UNREACHABLE, "off-region (past) UNREACHABLE")
	_ok(not ff.is_reachable(Vector2i(-1, 0)), "off-region not reachable")
	_v2_eq(ff.flow_at(Vector2i(10, 10)), Vector2.ZERO, "off-region ZERO flow")

## 6: recompute(new_goal) re-targets the field — new goal cost 0, an old-goal cell now
## has positive cost, and re-running with the same goal is idempotent.
func _test_recompute() -> void:
	var old_goal := Vector2i(0, 0)
	var new_goal := Vector2i(9, 9)
	var ff := FlowField.new(Rect2i(0, 0, 10, 10), _rule({}), old_goal)
	_i_eq(ff.cost_at(old_goal), 0, "recompute: old goal cost 0 pre-recompute")
	var old_cost_at_new: int = ff.cost_at(new_goal)

	ff.recompute(new_goal)
	_ok(ff.goal == new_goal, "recompute: goal updated")
	_i_eq(ff.cost_at(new_goal), 0, "recompute: new goal cost 0")
	_ok(ff.cost_at(old_goal) > 0, "recompute: old-goal cell now positive cost")
	_v2_eq(ff.flow_at(new_goal), Vector2.ZERO, "recompute: new goal ZERO flow")

	# Idempotent under the same goal: recomputing again yields identical costs.
	var cost_before: int = ff.cost_at(old_goal)
	ff.recompute(new_goal)
	_i_eq(ff.cost_at(old_goal), cost_before, "recompute: idempotent under same goal")
	_i_eq(ff.cost_at(new_goal), 0, "recompute: new goal still 0 after re-run")
	# Sanity: the old field's cost-to-new-goal matches the recomputed new-goal-to-old
	# symmetric distance on an open grid (both are Manhattan-ish BFS distances).
	_ok(old_cost_at_new == cost_before, "recompute: open-grid distance is symmetric")
