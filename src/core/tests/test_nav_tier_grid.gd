extends SceneTree
## Pure-logic tests for NavTierGrid (headless; AStarGrid2D is RefCounted, no servers).
## Self-contained SceneTree runner: godot --headless --script <this file>.
## Guards the "solids block / update() before query" contract and the []-on-invalid rule.

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
	_test_open_region_has_path()
	_test_wall_blocks()
	_test_is_walkable()
	_test_path_endpoints()
	_test_path_around_partial_obstacle()
	_test_solid_endpoint_returns_empty()
	_test_update_post_construction()

	print("PASS %d / FAIL %d" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- helpers ---

## Increments counters; prints only on failure so passing runs stay quiet.
func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: %s" % msg)

## Exact int equality check with message.
func _i_eq(a: int, b: int, msg: String) -> void:
	_ok(a == b, "%s: expected %d got %d" % [msg, b, a])

## Exact Vector2i equality check with message.
func _v_eq(a: Vector2i, b: Vector2i, msg: String) -> void:
	_ok(a == b, "%s: expected %s got %s" % [msg, b, a])

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
