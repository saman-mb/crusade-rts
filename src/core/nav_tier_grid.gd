class_name NavTierGrid
extends RefCounted
## Per-elevation-tier A* pathfinding grid. Each elevation tier of the map owns
## ONE NavTierGrid wrapping a single AStarGrid2D; ramps/transitions between tiers
## are stitched together by a higher layer, not here. Cliffs and holes (cells the
## `walkable` Callable rejects) are marked SOLID so paths never cross them.
## CRITICAL: the AStarGrid2D is fully configured (region + every solid) and then
## update()d in _init BEFORE any query runs — a query before update() misbehaves.
##
## Connectivity is precomputed ONCE at build (see _label_components): every
## walkable cell gets a connected-component label, so reachable() is O(1) instead
## of a full A* per call. The flood-fill uses the SAME connectivity model as
## path_within's AStarGrid2D (4-connected by default; diagonals honoured to match
## `diagonal_mode`), so reachable() agrees with the old A*-based answer in every
## case. component_of/walkable_cells expose that model to flow-field/portal builders.

const NO_COMPONENT: int = -1  ## component_of sentinel for non-walkable / off-region cells.

var region: Rect2i  ## Read-only copy of the ctor region (grid bounds, in cells).

var _grid: AStarGrid2D
var _diagonal_mode: int                              ## Connectivity model, mirrors the AStarGrid2D.
var _labels: PackedInt32Array = PackedInt32Array()   ## Per-cell component label, flat _index()-ed; NO_COMPONENT for solids.
var _component_count: int = 0                        ## Distinct walkable components; labels span [0, _component_count).

## Builds the tier grid over p_region. `walkable` takes (cell: Vector2i) -> bool
## (true = walkable ground; false = hole/cliff -> marked solid). diagonal_mode
## defaults to NEVER (4-connected). update() is called BEFORE the solid loop so
## the grid is query-ready the moment _init returns.
func _init(p_region: Rect2i, walkable: Callable, diagonal_mode: int = AStarGrid2D.DIAGONAL_MODE_NEVER) -> void:
	region = p_region
	_diagonal_mode = diagonal_mode
	_grid = AStarGrid2D.new()
	_grid.region = p_region
	_grid.cell_size = Vector2(MapConstants.TILE_SIZE)
	_grid.diagonal_mode = diagonal_mode
	_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	# CRITICAL ORDER (Godot 4.4): update() allocates the grid from region/cell_size
	# AND clears all solidity/weights, and set_point_solid() errors while the grid is
	# dirty. So update() FIRST, THEN mark solids. No trailing update() is needed —
	# solidity changes don't re-dirty the grid, and querying works immediately.
	_grid.update()
	for y in range(region.position.y, region.position.y + region.size.y):
		for x in range(region.position.x, region.position.x + region.size.x):
			var cell := Vector2i(x, y)
			var w: bool = walkable.call(cell)
			_grid.set_point_solid(cell, not w)
	# Connectivity is fixed now that every solid is marked: label components ONCE.
	_label_components()

## True when `cell` is inside the region AND not solid (walkable ground).
func is_walkable(cell: Vector2i) -> bool:
	return region.has_point(cell) and not _grid.is_point_solid(cell)

## Connected-component label of `cell`. Cells with the SAME label are mutually
## reachable within this tier; different labels are separated by solids. Returns
## NO_COMPONENT for non-walkable or off-region cells.
func component_of(cell: Vector2i) -> int:
	if not is_walkable(cell):
		return NO_COMPONENT
	return _labels[_index(cell)]

## Number of distinct walkable connected components (labels span [0, count)).
func component_count() -> int:
	return _component_count

## Every walkable cell in the region, in row-major order. For flow-field / portal
## builders that need to iterate walkable ground without holding the walkability
## Callable themselves.
func walkable_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(region.position.y, region.position.y + region.size.y):
		for x in range(region.position.x, region.position.x + region.size.x):
			var cell := Vector2i(x, y)
			if is_walkable(cell):
				out.append(cell)
	return out

## True when a path exists from `from` to `to` within this tier. O(1): both cells
## walkable AND in the same connected component. Agrees exactly with the old
## A*-based answer (== not path_within(from, to).is_empty()) in every case.
func reachable(from: Vector2i, to: Vector2i) -> bool:
	var a: int = component_of(from)
	if a == NO_COMPONENT:
		return false
	return a == component_of(to)

## Cell path from `from` to `to` within this tier, inclusive of both endpoints.
## Returns [] if either endpoint is out-of-region/solid, or if unreachable.
func path_within(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	if not (is_walkable(from) and is_walkable(to)):
		var empty: Array[Vector2i] = []
		return empty
	var p: Array[Vector2i] = _grid.get_id_path(from, to)
	return p

# --- connectivity labelling (build-time) ---

## Flat buffer index for an in-region cell, row-major within the region (same
## layout as FlowField). Callers must have range-checked `cell`.
func _index(cell: Vector2i) -> int:
	return (cell.y - region.position.y) * region.size.x + (cell.x - region.position.x)

## One flood-fill pass over all walkable cells: assigns each connected group a
## fresh label. Runs once in _init after every solid is set. Solids keep
## NO_COMPONENT. Same connectivity model as path_within (see _neighbors).
func _label_components() -> void:
	var count: int = region.size.x * region.size.y
	_labels = PackedInt32Array()
	_labels.resize(count)
	_labels.fill(NO_COMPONENT)
	_component_count = 0
	for y in range(region.position.y, region.position.y + region.size.y):
		for x in range(region.position.x, region.position.x + region.size.x):
			var cell := Vector2i(x, y)
			if not is_walkable(cell):
				continue
			if _labels[_index(cell)] != NO_COMPONENT:
				continue
			_flood(cell, _component_count)
			_component_count += 1

## BFS flood from `start`, stamping every walkable cell reachable under the
## connectivity model with `label`.
func _flood(start: Vector2i, label: int) -> void:
	var frontier: Array[Vector2i] = [start]
	_labels[_index(start)] = label
	while not frontier.is_empty():
		var cell: Vector2i = frontier.pop_back()
		for nb: Vector2i in _neighbors(cell):
			if _labels[_index(nb)] == NO_COMPONENT:
				_labels[_index(nb)] = label
				frontier.append(nb)

## Walkable neighbours of `cell` under the grid's diagonal_mode, mirroring
## AStarGrid2D's own traversal rules so component labels agree with path_within:
## 4 orthogonal always; diagonals only when the mode permits crossing the corner.
func _neighbors(cell: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var orth: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for d: Vector2i in orth:
		var nb: Vector2i = cell + d
		if is_walkable(nb):
			out.append(nb)
	if _diagonal_mode == AStarGrid2D.DIAGONAL_MODE_NEVER:
		return out
	var diags: Array[Vector2i] = [Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]
	for d: Vector2i in diags:
		var nb: Vector2i = cell + d
		if is_walkable(nb) and _diagonal_allowed(cell, d):
			out.append(nb)
	return out

## Whether a diagonal step from `cell` in direction `d` is allowed by the mode,
## checking the two shared orthogonal corner cells as AStarGrid2D does.
func _diagonal_allowed(cell: Vector2i, d: Vector2i) -> bool:
	if _diagonal_mode == AStarGrid2D.DIAGONAL_MODE_ALWAYS:
		return true
	var side_a: bool = is_walkable(cell + Vector2i(d.x, 0))
	var side_b: bool = is_walkable(cell + Vector2i(0, d.y))
	if _diagonal_mode == AStarGrid2D.DIAGONAL_MODE_AT_LEAST_ONE_WALKABLE:
		return side_a or side_b
	if _diagonal_mode == AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES:
		return side_a and side_b
	return false
