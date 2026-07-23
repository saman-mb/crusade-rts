class_name FlowField
extends RefCounted
## Pure flow field over a single elevation tier's walkable grid (#80, V3·C1).
## Two layers: (1) a uniform-cost, 4-connected BFS integration field measuring the
## step-distance from every reachable cell to `goal`, and (2) a per-cell flow vector
## pointing from each cell toward its lowest-cost 8-neighbour (diagonals allowed so
## the flow reads smoothly). Cost is stored in a PackedInt32Array indexed by
## (y - region.y) * region.size.x + (x - region.x) so recompute() can reset+refill
## the same buffer with no reallocation. Solid, off-region, and goal-unreachable
## cells all report UNREACHABLE (-1) cost and ZERO flow.
## CRITICAL: pure logic only — no Node/scene/TileMapLayer deps; every local is
## explicitly typed (warnings-as-errors: a Callable.call() / index result is Variant).

const UNREACHABLE := -1

var region: Rect2i  ## Read-only copy of the ctor region (grid bounds, in cells).
var goal: Vector2i  ## The current integration-field target (cost 0).

var _walkable: Callable  ## (cell: Vector2i) -> bool; true = passable ground.
var _cost: PackedInt32Array  ## Integration cost per cell, UNREACHABLE if not filled.

## 8-connected neighbour offsets used for flow direction (diagonals included).
const _DIRS_8: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

## 4-connected neighbour offsets used for the BFS integration wavefront.
const _DIRS_4: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]


## Builds the integration field over p_region via BFS from p_goal. `walkable` takes
## (cell: Vector2i) -> bool (true = passable). The predicate is stored so recompute()
## can rebuild without the caller re-supplying it.
func _init(p_region: Rect2i, walkable: Callable, p_goal: Vector2i) -> void:
	region = p_region
	_walkable = walkable
	var count: int = region.size.x * region.size.y
	_cost = PackedInt32Array()
	_cost.resize(count)
	_build(p_goal)


## Integration cost from `cell` to the goal (0 at the goal, positive elsewhere).
## Returns UNREACHABLE for solid, off-region, or goal-unreachable cells.
func cost_at(cell: Vector2i) -> int:
	if not region.has_point(cell):
		return UNREACHABLE
	var idx: int = _index(cell)
	return _cost[idx]


## True when `cell` is in-region and has a finite path to the goal.
func is_reachable(cell: Vector2i) -> bool:
	return cost_at(cell) != UNREACHABLE


## Cartesian unit direction from `cell` toward its lowest-cost 8-neighbour.
## Returns Vector2.ZERO at the goal, on unreachable/off-region cells, and whenever
## no strictly-lower-cost neighbour exists (local minima other than the goal cannot
## occur in a BFS field, but the guard keeps the result NaN-free regardless).
func flow_at(cell: Vector2i) -> Vector2:
	var here: int = cost_at(cell)
	if here == UNREACHABLE or here == 0:
		return Vector2.ZERO
	var best_cost: int = here
	var best_dir: Vector2i = Vector2i.ZERO
	for d: Vector2i in _DIRS_8:
		var nc: int = cost_at(cell + d)
		if nc == UNREACHABLE:
			continue
		if nc < best_cost:
			best_cost = nc
			best_dir = d
	if best_dir == Vector2i.ZERO:
		return Vector2.ZERO
	return Vector2(best_dir).normalized()


## Rebuilds the integration field toward p_goal, reusing the stored `walkable`
## predicate and the existing cost buffer (reset + refill, O(region area), no
## reallocation).
func recompute(p_goal: Vector2i) -> void:
	_build(p_goal)


# --- internals ---

## Flat buffer index for an in-region cell. Callers must have range-checked `cell`.
func _index(cell: Vector2i) -> int:
	return (cell.y - region.position.y) * region.size.x + (cell.x - region.position.x)


## Resets every cell to UNREACHABLE, then runs a uniform-cost 4-connected BFS
## wavefront outward from `p_goal`, writing step distances into `_cost`.
func _build(p_goal: Vector2i) -> void:
	goal = p_goal
	for i: int in range(_cost.size()):
		_cost[i] = UNREACHABLE
	# A goal that is off-region or on a solid cell seeds nothing: the whole field
	# stays UNREACHABLE, which is the correct answer for an invalid goal.
	if not region.has_point(p_goal):
		return
	var goal_ok: bool = _walkable.call(p_goal)
	if not goal_ok:
		return
	var frontier: Array[Vector2i] = [p_goal]
	_cost[_index(p_goal)] = 0
	while not frontier.is_empty():
		var next: Array[Vector2i] = []
		for cell: Vector2i in frontier:
			var base: int = _cost[_index(cell)]
			for d: Vector2i in _DIRS_4:
				var nb: Vector2i = cell + d
				if not region.has_point(nb):
					continue
				var nidx: int = _index(nb)
				if _cost[nidx] != UNREACHABLE:
					continue
				var passable: bool = _walkable.call(nb)
				if not passable:
					continue
				_cost[nidx] = base + 1
				next.append(nb)
		frontier = next
