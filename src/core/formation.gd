class_name Formation
extends RefCounted
## Pure group-formation core (#81, V3): turns a single goal cell + a unit count into
## N distinct WALKABLE target cells spread around the goal, then assigns each selected
## unit to a slot so a group ARRIVES spread out instead of stacking on the goal cell.
##
## Two independent, deterministic static helpers:
##   - slots():  N distinct in-region walkable cells spiralling outward from `goal` in
##               Chebyshev rings (goal is slot 0 when walkable), fixed (dy, dx) order.
##   - assign(): stable greedy nearest matching unit_index -> slot_index that minimizes
##               total squared distance without units crossing (the "peeling/oscillation"
##               the issue warns about); ties broken by (unit_index, slot_index).
##
## CRITICAL: pure logic only — no Node/scene deps, only Vector2i/Rect2i/Callable/arrays.
## Warnings-as-errors: a Callable.call() result and every array/Dictionary index is a
## Variant, so it lands in an explicitly typed local; every var + return type annotated.


## N distinct walkable cells spiralling outward from `goal` (goal itself is slot 0 when
## walkable). A cell is included only if region.has_point(cell) AND walkable.call(cell).
## Deterministic ring-by-ring (Chebyshev) + fixed (dy, dx) angular ordering. Returns as
## many as exist if the reachable area is smaller than `count`. The search radius is
## capped at the farthest in-region Chebyshev distance from `goal`, so it always
## terminates and never scans beyond the region.
static func slots(goal: Vector2i, count: int, walkable: Callable, region: Rect2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if count <= 0 or region.size.x <= 0 or region.size.y <= 0:
		return out

	# Cap the ring radius at the largest Chebyshev distance from `goal` to any region
	# corner: beyond that every ring is entirely off-region, so scanning is pointless.
	var min_x: int = region.position.x
	var min_y: int = region.position.y
	var max_x: int = region.position.x + region.size.x - 1
	var max_y: int = region.position.y + region.size.y - 1
	var dx_span: int = maxi(absi(goal.x - min_x), absi(goal.x - max_x))
	var dy_span: int = maxi(absi(goal.y - min_y), absi(goal.y - max_y))
	var max_radius: int = maxi(dx_span, dy_span)

	var r: int = 0
	while r <= max_radius and out.size() < count:
		# Iterate the ring (cells with Chebyshev distance == r) in fixed (dy, dx) order.
		# r == 0 collapses to the single `goal` cell. Rings never overlap, so every
		# appended cell is automatically distinct.
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var cell: Vector2i = goal + Vector2i(dx, dy)
				if not region.has_point(cell):
					continue
				var passable: bool = walkable.call(cell)
				if not passable:
					continue
				out.append(cell)
				if out.size() >= count:
					return out
		r += 1
	return out


## Deterministic stable nearest assignment: returns unit_index -> slot_index (an int per
## unit, indexing into `slot_cells`). Repeatedly claims the (unit, slot) pair with the
## smallest squared distance among still-unassigned units and slots, ties broken by
## (unit_index, slot_index), which minimizes crossing/total distance and is fully
## reproducible. Assumes slot_cells.size() >= unit_cells.size(); each slot used at most
## once. Element i of the result is the slot index assigned to unit i.
static func assign(unit_cells: Array[Vector2i], slot_cells: Array[Vector2i]) -> PackedInt32Array:
	var unit_count: int = unit_cells.size()
	var slot_count: int = slot_cells.size()
	var result: PackedInt32Array = PackedInt32Array()
	result.resize(unit_count)
	if unit_count == 0:
		return result

	# Build every (dist_sq, unit_index, slot_index) candidate pair, then sort by that
	# lexicographic key so the greedy sweep is a single ordered pass.
	var pairs: Array = []
	for u in range(unit_count):
		var up: Vector2i = unit_cells[u]
		for s in range(slot_count):
			var sp: Vector2i = slot_cells[s]
			var diff: Vector2i = sp - up
			var dist_sq: int = diff.x * diff.x + diff.y * diff.y
			pairs.append([dist_sq, u, s])

	pairs.sort_custom(_pair_less)

	var unit_taken: PackedInt32Array = PackedInt32Array()
	unit_taken.resize(unit_count)
	unit_taken.fill(0)
	var slot_taken: PackedInt32Array = PackedInt32Array()
	slot_taken.resize(slot_count)
	slot_taken.fill(0)

	var assigned: int = 0
	for entry in pairs:
		if assigned >= unit_count:
			break
		var pair: Array = entry
		var u: int = pair[1]
		var s: int = pair[2]
		if unit_taken[u] == 1 or slot_taken[s] == 1:
			continue
		result[u] = s
		unit_taken[u] = 1
		slot_taken[s] = 1
		assigned += 1
	return result


## Strict-weak ordering over [dist_sq, unit_index, slot_index] triples: smaller squared
## distance first, then smaller unit index, then smaller slot index. Fully deterministic
## so the greedy sweep in assign() is reproducible.
static func _pair_less(a: Array, b: Array) -> bool:
	var a0: int = a[0]
	var b0: int = b[0]
	if a0 != b0:
		return a0 < b0
	var a1: int = a[1]
	var b1: int = b[1]
	if a1 != b1:
		return a1 < b1
	var a2: int = a[2]
	var b2: int = b[2]
	return a2 < b2
