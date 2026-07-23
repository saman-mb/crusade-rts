extends GdTest
## Unit tests for MapChange (#95): the pure affected-cell -> bounding Rect2i math
## behind the map_changed hub's rect payload. No Node / TileMapLayer deps.


func _run() -> void:
	_test_empty()
	_test_single_cell()
	_test_multi_cell_bounds()
	_test_negative_cells()
	_test_bounds_of_changes()


## An empty cell set yields a zero-size rect at the origin (no spurious extent).
func _test_empty() -> void:
	var r := MapChange.bounds_of_cells([])
	_v_eq(r.position, Vector2i.ZERO, "empty -> zero position")
	_v_eq(r.size, Vector2i.ZERO, "empty -> zero size")


## A single cell yields a 1x1 rect anchored at that cell (inclusive footprint).
func _test_single_cell() -> void:
	var r := MapChange.bounds_of_cells([Vector2i(5, 7)])
	_v_eq(r.position, Vector2i(5, 7), "single -> position at cell")
	_v_eq(r.size, Vector2i(1, 1), "single -> 1x1 size")


## Several cells yield the inclusive bounding box (max cell included, +1 in size).
func _test_multi_cell_bounds() -> void:
	var r := MapChange.bounds_of_cells([Vector2i(2, 3), Vector2i(6, 3), Vector2i(4, 8)])
	_v_eq(r.position, Vector2i(2, 3), "multi -> min corner")
	_v_eq(r.size, Vector2i(5, 6), "multi -> spans min..max inclusive")


## Negative coordinates are handled without dragging in the origin.
func _test_negative_cells() -> void:
	var r := MapChange.bounds_of_cells([Vector2i(-4, -2), Vector2i(-1, 1)])
	_v_eq(r.position, Vector2i(-4, -2), "negative -> min corner")
	_v_eq(r.size, Vector2i(4, 4), "negative -> inclusive span")


## bounds_of_changes reads the "cell" field of StrokeRecorder.changes()-shaped dicts.
func _test_bounds_of_changes() -> void:
	var changes: Array = [
		{"cell": Vector2i(1, 1), "before_src": -1, "after_src": 0},
		{"cell": Vector2i(3, 4), "before_src": -1, "after_src": 0},
	]
	var r := MapChange.bounds_of_changes(changes)
	_v_eq(r.position, Vector2i(1, 1), "changes -> min corner")
	_v_eq(r.size, Vector2i(3, 4), "changes -> inclusive span")
