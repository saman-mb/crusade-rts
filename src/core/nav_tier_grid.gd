class_name NavTierGrid
extends RefCounted
## Per-elevation-tier A* pathfinding grid. Each elevation tier of the map owns
## ONE NavTierGrid wrapping a single AStarGrid2D; ramps/transitions between tiers
## are stitched together by a higher layer, not here. Cliffs and holes (cells the
## `walkable` Callable rejects) are marked SOLID so paths never cross them.
## CRITICAL: the AStarGrid2D is fully configured (region + every solid) and then
## update()d in _init BEFORE any query runs — a query before update() misbehaves.

var region: Rect2i  ## Read-only copy of the ctor region (grid bounds, in cells).

var _grid: AStarGrid2D

## Builds the tier grid over p_region. `walkable` takes (cell: Vector2i) -> bool
## (true = walkable ground; false = hole/cliff -> marked solid). diagonal_mode
## defaults to NEVER (4-connected). update() is called BEFORE the solid loop so
## the grid is query-ready the moment _init returns.
func _init(p_region: Rect2i, walkable: Callable, diagonal_mode: int = AStarGrid2D.DIAGONAL_MODE_NEVER) -> void:
	region = p_region
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

## True when `cell` is inside the region AND not solid (walkable ground).
func is_walkable(cell: Vector2i) -> bool:
	return region.has_point(cell) and not _grid.is_point_solid(cell)

## True when a path exists from `from` to `to` within this tier.
func reachable(from: Vector2i, to: Vector2i) -> bool:
	return not path_within(from, to).is_empty()

## Cell path from `from` to `to` within this tier, inclusive of both endpoints.
## Returns [] if either endpoint is out-of-region/solid, or if unreachable.
func path_within(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	if not (is_walkable(from) and is_walkable(to)):
		var empty: Array[Vector2i] = []
		return empty
	var p: Array[Vector2i] = _grid.get_id_path(from, to)
	return p
