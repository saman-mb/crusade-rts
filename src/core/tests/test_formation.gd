extends GdTest
## Pure-logic tests for Formation (#81, V3): group formation arrival.
## Self-contained SceneTree runner: godot --headless --script <this file>.
## Guards the "distinct + walkable + in-region" slot contract, obstacle/edge
## degradation, full determinism, and the stable no-crossing assignment.


func _run() -> void:
	_test_slots_distinct_and_walkable()
	_test_slots_obstacle_degradation()
	_test_slots_corner_stays_in_region()
	_test_slots_nonwalkable_goal()
	_test_slots_degrades_when_area_too_small()
	_test_determinism()
	_test_assign_identity()
	_test_assign_unique_and_valid()
	_test_assign_no_improving_swap()


# --- helpers ---

## Builds a walkability Callable that treats any cell in `blocked` as a hole/cliff.
func _rule(blocked: Dictionary) -> Callable:
	return func(cell: Vector2i) -> bool:
		return not blocked.has(cell)

## True when every cell in `cells` is unique (no repeats).
func _all_distinct(cells: Array[Vector2i]) -> bool:
	var seen: Dictionary = {}
	for c in cells:
		if seen.has(c):
			return false
		seen[c] = true
	return true

## Total squared distance of an assignment (unit i -> slot result[i]).
func _total_sq(units: Array[Vector2i], slots_arr: Array[Vector2i], mapping: PackedInt32Array) -> int:
	var total: int = 0
	for i in range(mapping.size()):
		var s: int = mapping[i]
		var diff: Vector2i = slots_arr[s] - units[i]
		total += diff.x * diff.x + diff.y * diff.y
	return total


# --- tests ---

## Distinct + walkable: an open region yields N unique cells, all walkable + in-region,
## with the goal itself as slot 0.
func _test_slots_distinct_and_walkable() -> void:
	var region := Rect2i(0, 0, 20, 20)
	var walkable: Callable = _rule({})
	var goal := Vector2i(10, 10)
	var cells: Array[Vector2i] = Formation.slots(goal, 9, walkable, region)
	_i_eq(cells.size(), 9, "open region: exactly N slots")
	_ok(_all_distinct(cells), "open region: slots are all distinct")
	_v_eq(cells[0], goal, "open region: goal is slot 0")
	for c in cells:
		_ok(region.has_point(c), "open region: slot in-region %s" % c)
		var passable: bool = walkable.call(c)
		_ok(passable, "open region: slot walkable %s" % c)

## Obstacle degradation: blocking the goal's whole first ring must not drop any of those
## cells into the result, yet the count is still met by spiralling further out.
func _test_slots_obstacle_degradation() -> void:
	var region := Rect2i(0, 0, 20, 20)
	var goal := Vector2i(10, 10)
	var blocked: Dictionary = {}
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			blocked[goal + Vector2i(dx, dy)] = true  # entire Chebyshev ring 1
	var walkable: Callable = _rule(blocked)
	var cells: Array[Vector2i] = Formation.slots(goal, 6, walkable, region)
	_i_eq(cells.size(), 6, "obstacle: count still met by spiralling out")
	_ok(_all_distinct(cells), "obstacle: slots distinct")
	for c in cells:
		_ok(not blocked.has(c), "obstacle: no blocked cell returned %s" % c)
		var passable: bool = walkable.call(c)
		_ok(passable, "obstacle: slot walkable %s" % c)
	# Ring 1 was fully blocked, so nothing at Chebyshev distance 1 may appear.
	for c in cells:
		var d: Vector2i = c - goal
		_ok(maxi(absi(d.x), absi(d.y)) != 1, "obstacle: no cell in blocked ring 1 %s" % c)

## Map edge/corner: a goal in the region corner keeps every slot in-region.
func _test_slots_corner_stays_in_region() -> void:
	var region := Rect2i(0, 0, 20, 20)
	var goal := Vector2i(0, 0)
	var walkable: Callable = _rule({})
	var cells: Array[Vector2i] = Formation.slots(goal, 8, walkable, region)
	_i_eq(cells.size(), 8, "corner: count met using the in-region quadrant")
	_v_eq(cells[0], goal, "corner: goal is slot 0")
	for c in cells:
		_ok(region.has_point(c), "corner: slot stays in-region %s" % c)

## A non-walkable goal is skipped: slot 0 becomes the nearest walkable ring cell,
## and the goal itself never appears.
func _test_slots_nonwalkable_goal() -> void:
	var region := Rect2i(0, 0, 20, 20)
	var goal := Vector2i(10, 10)
	var walkable: Callable = _rule({ goal: true })
	var cells: Array[Vector2i] = Formation.slots(goal, 5, walkable, region)
	_i_eq(cells.size(), 5, "nonwalkable goal: count still met")
	for c in cells:
		_ok(c != goal, "nonwalkable goal: goal never returned")
		var passable: bool = walkable.call(c)
		_ok(passable, "nonwalkable goal: slot walkable %s" % c)

## Degradation: a genuinely tiny walkable pocket returns only what exists, never a
## blocked or off-region cell, and never more than the pocket holds.
func _test_slots_degrades_when_area_too_small() -> void:
	# A 3x3 region; block all but the goal and one neighbour -> only 2 free cells.
	var region := Rect2i(0, 0, 3, 3)
	var goal := Vector2i(1, 1)
	var blocked: Dictionary = {}
	for y in range(0, 3):
		for x in range(0, 3):
			var cell := Vector2i(x, y)
			if cell == goal or cell == Vector2i(2, 1):
				continue
			blocked[cell] = true
	var walkable: Callable = _rule(blocked)
	var cells: Array[Vector2i] = Formation.slots(goal, 9, walkable, region)
	_i_eq(cells.size(), 2, "tiny pocket: returns only the free cells that exist")
	_ok(_all_distinct(cells), "tiny pocket: distinct")
	for c in cells:
		_ok(region.has_point(c) and not blocked.has(c), "tiny pocket: free + in-region %s" % c)

## Determinism: identical inputs give identical slots list AND identical assign result
## across repeated calls.
func _test_determinism() -> void:
	var region := Rect2i(-5, -5, 25, 25)
	var goal := Vector2i(3, 4)
	var blocked: Dictionary = { Vector2i(3, 5): true, Vector2i(4, 4): true }
	var walkable: Callable = _rule(blocked)
	var a: Array[Vector2i] = Formation.slots(goal, 12, walkable, region)
	var b: Array[Vector2i] = Formation.slots(goal, 12, walkable, region)
	_i_eq(a.size(), b.size(), "determinism: slots size stable")
	var slots_match: bool = true
	for i in range(a.size()):
		if a[i] != b[i]:
			slots_match = false
	_ok(slots_match, "determinism: slots list identical across calls")

	var units: Array[Vector2i] = [Vector2i(0, 0), Vector2i(8, 8), Vector2i(2, 6), Vector2i(9, 1)]
	var m1: PackedInt32Array = Formation.assign(units, a)
	var m2: PackedInt32Array = Formation.assign(units, a)
	_ok(m1 == m2, "determinism: assign result identical across calls")

## Assignment validity: units already sitting exactly on the slot cells map to identity.
func _test_assign_identity() -> void:
	var slots_arr: Array[Vector2i] = [Vector2i(0, 0), Vector2i(5, 5), Vector2i(2, 9), Vector2i(7, 1)]
	var units: Array[Vector2i] = [Vector2i(0, 0), Vector2i(5, 5), Vector2i(2, 9), Vector2i(7, 1)]
	var mapping: PackedInt32Array = Formation.assign(units, slots_arr)
	for i in range(units.size()):
		_i_eq(mapping[i], i, "identity: unit on its slot maps to itself")

## Assignment validity: every unit gets a distinct, in-range slot (more slots than units).
func _test_assign_unique_and_valid() -> void:
	var slots_arr: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 2),
	]
	var units: Array[Vector2i] = [Vector2i(0, 0), Vector2i(2, 2), Vector2i(1, 1)]
	var mapping: PackedInt32Array = Formation.assign(units, slots_arr)
	_i_eq(mapping.size(), units.size(), "valid: one slot per unit")
	var used: Dictionary = {}
	for i in range(mapping.size()):
		var s: int = mapping[i]
		_ok(s >= 0 and s < slots_arr.size(), "valid: slot index in range %d" % s)
		_ok(not used.has(s), "valid: slot used at most once %d" % s)
		used[s] = true

## Cohesion guarantee: on a small fixture no swap of any two unit->slot assignments
## reduces the total squared distance (a 2-opt-stable, no-crossing matching).
func _test_assign_no_improving_swap() -> void:
	var slots_arr: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(4, 0), Vector2i(0, 4), Vector2i(4, 4),
	]
	# Units placed near, but not on, each corner, in a scrambled order.
	var units: Array[Vector2i] = [Vector2i(3, 4), Vector2i(1, 0), Vector2i(4, 3), Vector2i(0, 1)]
	var mapping: PackedInt32Array = Formation.assign(units, slots_arr)
	var base: int = _total_sq(units, slots_arr, mapping)
	var improved: bool = false
	for i in range(mapping.size()):
		for j in range(i + 1, mapping.size()):
			var swapped: PackedInt32Array = mapping.duplicate()
			var tmp: int = swapped[i]
			swapped[i] = swapped[j]
			swapped[j] = tmp
			var alt: int = _total_sq(units, slots_arr, swapped)
			if alt < base:
				improved = true
	_ok(not improved, "cohesion: no pair swap reduces total squared distance")
