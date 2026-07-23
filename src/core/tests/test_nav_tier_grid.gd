extends GdTest
## Pure-logic tests for NavTierGrid (headless; AStarGrid2D is RefCounted, no servers).
## Self-contained SceneTree runner: godot --headless --script <this file>.
## Guards the "solids block / update() before query" contract and the []-on-invalid rule.


func _run() -> void:
	_test_open_region_has_path()
	_test_wall_blocks()
	_test_is_walkable()
	_test_path_endpoints()
	_test_path_around_partial_obstacle()
	_test_solid_endpoint_returns_empty()
	_test_update_post_construction()
	_test_components_partition_walkable()
	_test_component_of_and_walkable_contract()
	_test_walkable_cells_iteration()
	_test_reachable_matches_astar_ground_truth()


# --- helpers ---

## Builds a walkability Callable that treats any cell in `blocked` as a hole/cliff.
func _rule(blocked: Dictionary) -> Callable:
	return func(cell: Vector2i) -> bool:
		return not blocked.has(cell)

# --- tests ---

## 1 & 7: a fully-walkable region yields a non-empty path post-construction
## (construction calls update(), so the grid is immediately query-ready).
func _test_open_region_has_path() -> void:
	var grid := NavTierGrid.new(Rect2i(0, 0, 10, 10), _rule({}))
	var path: Array[Vector2i] = grid.path_within(Vector2i(0, 0), Vector2i(9, 9))
	_ok(not path.is_empty(), "open region: path non-empty")
	_ok(grid.reachable(Vector2i(0, 0), Vector2i(9, 9)), "open region: reachable true")
	_ok(grid.region == Rect2i(0, 0, 10, 10), "region stored read-only")

## 2: a full vertical wall splitting the region makes the two halves unreachable.
func _test_wall_blocks() -> void:
	var blocked: Dictionary = {}
	for y in range(0, 10):
		blocked[Vector2i(5, y)] = true  # solid wall at x=5, all rows
	var grid := NavTierGrid.new(Rect2i(0, 0, 10, 10), _rule(blocked))
	var path: Array[Vector2i] = grid.path_within(Vector2i(0, 5), Vector2i(9, 5))
	_ok(path.is_empty(), "full wall: path_within == []")
	_ok(not grid.reachable(Vector2i(0, 5), Vector2i(9, 5)), "full wall: reachable false")
	# Both halves are internally still fine.
	_ok(not grid.path_within(Vector2i(0, 0), Vector2i(4, 9)).is_empty(), "left half still connected")

## 3: is_walkable matches the underlying rule (open true, hole false, off-region false).
func _test_is_walkable() -> void:
	var blocked: Dictionary = { Vector2i(3, 3): true }
	var grid := NavTierGrid.new(Rect2i(0, 0, 10, 10), _rule(blocked))
	_ok(grid.is_walkable(Vector2i(2, 2)) == true, "is_walkable open cell true")
	_ok(grid.is_walkable(Vector2i(3, 3)) == false, "is_walkable hole false")
	_ok(grid.is_walkable(Vector2i(-1, 0)) == false, "is_walkable out-of-region (neg) false")
	_ok(grid.is_walkable(Vector2i(10, 10)) == false, "is_walkable out-of-region (past) false")

## 4: on a reachable pair, path first == from and last == to.
func _test_path_endpoints() -> void:
	var grid := NavTierGrid.new(Rect2i(0, 0, 10, 10), _rule({}))
	var from := Vector2i(1, 8)
	var to := Vector2i(7, 2)
	var path: Array[Vector2i] = grid.path_within(from, to)
	_ok(not path.is_empty(), "endpoints: path exists")
	_v_eq(path[0], from, "endpoints: first == from")
	_v_eq(path[path.size() - 1], to, "endpoints: last == to")

## 5: a partial obstacle (wall with a gap) is routed AROUND, not blocked.
func _test_path_around_partial_obstacle() -> void:
	var blocked: Dictionary = {}
	for y in range(0, 9):
		blocked[Vector2i(5, y)] = true  # wall at x=5 for y 0..8, row 9 left open
	var grid := NavTierGrid.new(Rect2i(0, 0, 10, 10), _rule(blocked))
	var path: Array[Vector2i] = grid.path_within(Vector2i(0, 0), Vector2i(9, 0))
	_ok(not path.is_empty(), "partial obstacle: path found around")
	_ok(grid.reachable(Vector2i(0, 0), Vector2i(9, 0)), "partial obstacle: reachable true")
	# The route must dip to the open row 9 to cross.
	_ok(path.has(Vector2i(5, 9)), "partial obstacle: path uses the open gap at (5,9)")

## 6: a solid `from` or `to` yields [] (guard fires before get_id_path).
func _test_solid_endpoint_returns_empty() -> void:
	var blocked: Dictionary = { Vector2i(0, 0): true, Vector2i(9, 9): true }
	var grid := NavTierGrid.new(Rect2i(0, 0, 10, 10), _rule(blocked))
	_ok(grid.path_within(Vector2i(0, 0), Vector2i(5, 5)).is_empty(), "solid from -> []")
	_ok(grid.path_within(Vector2i(5, 5), Vector2i(9, 9)).is_empty(), "solid to -> []")
	_ok(not grid.reachable(Vector2i(0, 0), Vector2i(5, 5)), "solid from -> reachable false")

## 7: explicit sanity that update() ran during construction — a known-open, adjacent
## pair paths immediately with no manual update() call by the caller.
func _test_update_post_construction() -> void:
	var grid := NavTierGrid.new(Rect2i(0, 0, 4, 4), _rule({}))
	var path: Array[Vector2i] = grid.path_within(Vector2i(0, 0), Vector2i(0, 1))
	_ok(not path.is_empty(), "post-update: adjacent open pair paths without manual update()")
	_i_eq(path.size(), 2, "post-update: adjacent path is exactly 2 cells")

## 8 (#104): component labels partition walkable cells. A full wall at x=5 splits
## the region into two walkable halves -> exactly 2 components; every cell in the
## left half shares one label, every cell in the right half shares another, and
## the two labels differ.
func _test_components_partition_walkable() -> void:
	var blocked: Dictionary = {}
	for y in range(0, 10):
		blocked[Vector2i(5, y)] = true
	var grid := NavTierGrid.new(Rect2i(0, 0, 10, 10), _rule(blocked))
	_i_eq(grid.component_count(), 2, "wall-split: exactly two walkable components")

	var left_label: int = grid.component_of(Vector2i(0, 0))
	var right_label: int = grid.component_of(Vector2i(9, 0))
	_ok(left_label != NavTierGrid.NO_COMPONENT, "wall-split: left half has a real label")
	_ok(right_label != NavTierGrid.NO_COMPONENT, "wall-split: right half has a real label")
	_ok(left_label != right_label, "wall-split: the two halves have DIFFERENT labels")

	# Every walkable left cell shares left_label; every walkable right cell shares right_label.
	var left_uniform: bool = true
	var right_uniform: bool = true
	for y in range(0, 10):
		for x in range(0, 5):
			if grid.component_of(Vector2i(x, y)) != left_label:
				left_uniform = false
		for x in range(6, 10):
			if grid.component_of(Vector2i(x, y)) != right_label:
				right_uniform = false
	_ok(left_uniform, "wall-split: whole left half shares one label")
	_ok(right_uniform, "wall-split: whole right half shares one label")

	# A fully-open region is a single component.
	var open_grid := NavTierGrid.new(Rect2i(0, 0, 8, 8), _rule({}))
	_i_eq(open_grid.component_count(), 1, "open region: exactly one component")
	_ok(open_grid.component_of(Vector2i(0, 0)) == open_grid.component_of(Vector2i(7, 7)),
		"open region: distant cells share the single label")

## 9 (#104): component_of / is_walkable contract for solid & off-region cells.
func _test_component_of_and_walkable_contract() -> void:
	var blocked: Dictionary = { Vector2i(3, 3): true }
	var grid := NavTierGrid.new(Rect2i(0, 0, 10, 10), _rule(blocked))
	# Solid cell -> NO_COMPONENT and not walkable.
	_ok(grid.component_of(Vector2i(3, 3)) == NavTierGrid.NO_COMPONENT, "solid cell -> NO_COMPONENT")
	_ok(not grid.is_walkable(Vector2i(3, 3)), "solid cell -> not walkable")
	# Off-region cells -> NO_COMPONENT (no out-of-bounds index).
	_ok(grid.component_of(Vector2i(-1, 0)) == NavTierGrid.NO_COMPONENT, "off-region (neg) -> NO_COMPONENT")
	_ok(grid.component_of(Vector2i(10, 10)) == NavTierGrid.NO_COMPONENT, "off-region (past) -> NO_COMPONENT")
	# A walkable cell has a valid (non-sentinel) label.
	_ok(grid.component_of(Vector2i(0, 0)) != NavTierGrid.NO_COMPONENT, "walkable cell -> real label")

## 10 (#104): walkable_cells() returns exactly the region's walkable cells and
## every one of them has a real component label (region-bounds iteration contract).
func _test_walkable_cells_iteration() -> void:
	var blocked: Dictionary = { Vector2i(2, 2): true, Vector2i(3, 3): true }
	var region := Rect2i(0, 0, 6, 6)
	var grid := NavTierGrid.new(region, _rule(blocked))
	var cells: Array[Vector2i] = grid.walkable_cells()
	# 36 cells minus 2 holes.
	_i_eq(cells.size(), 34, "walkable_cells: count is region area minus holes")
	var all_walkable_labelled: bool = true
	for c: Vector2i in cells:
		if not grid.is_walkable(c):
			all_walkable_labelled = false
		if grid.component_of(c) == NavTierGrid.NO_COMPONENT:
			all_walkable_labelled = false
	_ok(all_walkable_labelled, "walkable_cells: every listed cell is walkable with a real label")
	_ok(not cells.has(Vector2i(2, 2)) and not cells.has(Vector2i(3, 3)),
		"walkable_cells: excludes the holes")

## 11 (#104): the O(1) reachable() agrees with the A* ground truth
## (not path_within(a,b).is_empty()) across MANY pairs on a maze-like grid --
## connected, wall-split, non-walkable-endpoint and off-region cases all covered.
func _test_reachable_matches_astar_ground_truth() -> void:
	# A grid with a full internal wall at x=4 pierced by a single gap at y=7, plus
	# a lone hole -- yields both connected and (endpoint-)invalid pairs to compare.
	var blocked: Dictionary = {}
	for y in range(0, 10):
		if y != 7:
			blocked[Vector2i(4, y)] = true
	blocked[Vector2i(8, 1)] = true  # isolated hole for solid-endpoint cases
	var region := Rect2i(0, 0, 10, 10)
	var grid := NavTierGrid.new(region, _rule(blocked))

	# Probe a spread of cells: corners, both sides of the wall, the gap, the hole,
	# and two off-region cells -- every ordered pair is checked both ways.
	var probes: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(3, 9), Vector2i(4, 7), Vector2i(5, 0),
		Vector2i(9, 9), Vector2i(8, 1), Vector2i(4, 3), Vector2i(-1, 5),
		Vector2i(10, 2),
	]
	var mismatches: int = 0
	for a: Vector2i in probes:
		for b: Vector2i in probes:
			var fast: bool = grid.reachable(a, b)
			var truth: bool = not grid.path_within(a, b).is_empty()
			if fast != truth:
				mismatches += 1
	_i_eq(mismatches, 0, "reachable() O(1) agrees with A* ground truth over all probe pairs")
	# Spot-check the interesting split: same side reachable, across-wall NOT.
	_ok(grid.reachable(Vector2i(0, 0), Vector2i(3, 9)), "left side internally reachable")
	_ok(grid.reachable(Vector2i(0, 0), Vector2i(9, 9)), "reachable across the single gap at y=7")
	# Wall the gap too -> the two sides become genuinely disconnected.
	blocked[Vector2i(4, 7)] = true
	var split := NavTierGrid.new(region, _rule(blocked))
	_ok(not split.reachable(Vector2i(0, 0), Vector2i(9, 9)), "sealed wall: sides NOT reachable")
	_ok(split.reachable(Vector2i(0, 0), Vector2i(9, 9)) == (not split.path_within(Vector2i(0, 0), Vector2i(9, 9)).is_empty()),
		"sealed wall: reachable still matches A* ground truth")
