extends SceneTree
## Pure-logic tests for FloodFill (no Node deps; drives only the static iterative compute).
## Self-contained SceneTree runner: godot --headless --script <this file>.
## Backs compute() with an in-memory grid (Dictionary Vector2i -> {src,atlas}) plus a
## read lambda (absent cell -> {src:-1, atlas:(-1,-1)}) and a 4-neighbor (N/E/S/W) lambda,
## so the whole thing is headless. Proves: contiguous fill, seed-identity boundaries,
## diagonal non-connectivity under 4-neighbor topology, bounds + max_cells termination,
## empty-space termination (no recursion blowup / hang), and out-of-bounds/single-cell edges.

var _pass: int = 0
var _fail: int = 0

## Shared 4-neighbor topology (N/E/S/W). Offsets live ONLY here, never in FloodFill.
var _neighbors: Callable = func(c: Vector2i) -> Array[Vector2i]:
	return [
		c + Vector2i(0, -1),
		c + Vector2i(1, 0),
		c + Vector2i(0, 1),
		c + Vector2i(-1, 0),
	]

func _initialize() -> void:
	_test_contiguous_region()
	_test_identity_boundary()
	_test_diagonal_not_connected()
	_test_bounds_exclusion()
	_test_max_cells_cap()
	_test_empty_space_termination()
	_test_out_of_bounds_seed()
	_test_single_isolated_cell()

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

## Builds a read Callable over an in-memory grid; absent cells default to the empty sentinel.
func _make_read(grid: Dictionary) -> Callable:
	return func(c: Vector2i) -> Dictionary:
		return grid.get(c, { "src": -1, "atlas": Vector2i(-1, -1) })

## Convenience: does `cells` contain `cell`? (membership assert for corners etc.)
func _has(cells: Array[Vector2i], cell: Vector2i) -> bool:
	return cells.has(cell)

# --- tests ---

## 1. A solid rectangle of identical tiles fills to exactly those cells (count + corners).
func _test_contiguous_region() -> void:
	var atlas := Vector2i(0, 0)
	var grid: Dictionary = {}
	# 4x3 block (x 0..3, y 0..2) of src 1 / atlas (0,0) = 12 cells.
	for y in range(0, 3):
		for x in range(0, 4):
			grid[Vector2i(x, y)] = { "src": 1, "atlas": atlas }
	var bounds := Rect2i(-5, -5, 20, 20)
	var out := FloodFill.compute(Vector2i(1, 1), 1, atlas, bounds, _make_read(grid), _neighbors, 10000)

	_i_eq(out.size(), 12, "contiguous 4x3 block -> 12 cells")
	_ok(_has(out, Vector2i(0, 0)), "contiguous includes corner (0,0)")
	_ok(_has(out, Vector2i(3, 0)), "contiguous includes corner (3,0)")
	_ok(_has(out, Vector2i(0, 2)), "contiguous includes corner (0,2)")
	_ok(_has(out, Vector2i(3, 2)), "contiguous includes corner (3,2)")
	_ok(out[0] == Vector2i(1, 1), "BFS order: seed is first result")

## 2. A region bordered by DIFFERENT tiles: the fill stops at the identity boundary.
func _test_identity_boundary() -> void:
	var atlas := Vector2i(0, 0)
	var grid: Dictionary = {}
	# Center cross of src 1; the four cardinal neighbors are src 2 (different) -> a wall.
	grid[Vector2i(0, 0)] = { "src": 1, "atlas": atlas }
	grid[Vector2i(0, -1)] = { "src": 2, "atlas": atlas }
	grid[Vector2i(1, 0)] = { "src": 2, "atlas": atlas }
	grid[Vector2i(0, 1)] = { "src": 2, "atlas": atlas }
	grid[Vector2i(-1, 0)] = { "src": 2, "atlas": atlas }
	var bounds := Rect2i(-5, -5, 20, 20)
	var out := FloodFill.compute(Vector2i(0, 0), 1, atlas, bounds, _make_read(grid), _neighbors, 10000)

	_i_eq(out.size(), 1, "identity boundary: fill does not cross into src 2 -> only seed")
	_ok(_has(out, Vector2i(0, 0)), "identity boundary includes seed")
	_ok(not _has(out, Vector2i(1, 0)), "identity boundary excludes differing neighbor (1,0)")
	_ok(not _has(out, Vector2i(0, -1)), "identity boundary excludes differing neighbor (0,-1)")

	# Same-source but DIFFERENT ATLAS neighbor must also be excluded (identity = src AND atlas).
	var grid2: Dictionary = {}
	grid2[Vector2i(0, 0)] = { "src": 1, "atlas": Vector2i(0, 0) }
	grid2[Vector2i(1, 0)] = { "src": 1, "atlas": Vector2i(2, 2) }  # same src, diff atlas
	var out2 := FloodFill.compute(Vector2i(0, 0), 1, Vector2i(0, 0), bounds, _make_read(grid2), _neighbors, 10000)
	_i_eq(out2.size(), 1, "atlas boundary: same src diff atlas is NOT part of region")
	_ok(not _has(out2, Vector2i(1, 0)), "atlas boundary excludes same-src diff-atlas neighbor")

## 3. Two same-tile cells touching only DIAGONALLY are not connected under 4-neighbor topology.
func _test_diagonal_not_connected() -> void:
	var atlas := Vector2i(0, 0)
	var grid: Dictionary = {}
	grid[Vector2i(0, 0)] = { "src": 1, "atlas": atlas }
	grid[Vector2i(1, 1)] = { "src": 1, "atlas": atlas }  # diagonal to seed, same identity
	var bounds := Rect2i(-5, -5, 20, 20)
	var out := FloodFill.compute(Vector2i(0, 0), 1, atlas, bounds, _make_read(grid), _neighbors, 10000)

	_i_eq(out.size(), 1, "diagonal-only touch -> not connected (4-neighbor)")
	_ok(_has(out, Vector2i(0, 0)), "diagonal test includes seed")
	_ok(not _has(out, Vector2i(1, 1)), "diagonal cell (1,1) excluded under 4-neighbor topology")

## 4. Matching cells OUTSIDE bounds are never included, even when contiguous.
func _test_bounds_exclusion() -> void:
	var atlas := Vector2i(0, 0)
	var grid: Dictionary = {}
	# Horizontal run x 0..4 all src 1; bounds only admits x 0..2.
	for x in range(0, 5):
		grid[Vector2i(x, 0)] = { "src": 1, "atlas": atlas }
	var bounds := Rect2i(0, 0, 3, 1)  # cells (0,0),(1,0),(2,0) only
	var out := FloodFill.compute(Vector2i(0, 0), 1, atlas, bounds, _make_read(grid), _neighbors, 10000)

	_i_eq(out.size(), 3, "bounds exclusion: only in-bounds matching cells")
	_ok(_has(out, Vector2i(2, 0)), "bounds includes last in-bounds cell (2,0)")
	_ok(not _has(out, Vector2i(3, 0)), "bounds excludes out-of-bounds matching cell (3,0)")
	_ok(not _has(out, Vector2i(4, 0)), "bounds excludes out-of-bounds matching cell (4,0)")

## 5. A large matching region with a small max_cells returns <= cap and TERMINATES.
func _test_max_cells_cap() -> void:
	var atlas := Vector2i(0, 0)
	var grid: Dictionary = {}
	# 10x10 = 100 matching cells.
	for y in range(0, 10):
		for x in range(0, 10):
			grid[Vector2i(x, y)] = { "src": 1, "atlas": atlas }
	var bounds := Rect2i(0, 0, 10, 10)
	var out := FloodFill.compute(Vector2i(0, 0), 1, atlas, bounds, _make_read(grid), _neighbors, 5)

	_i_eq(out.size(), 5, "max_cells cap: returns exactly the cap (5) on a 100-cell region")
	_ok(out.size() <= 5, "max_cells cap: never exceeds the cap")

## 6. Seed on empty space (src -1) within small bounds returns the bounded empty cells and
##    terminates -- proves no hang / no recursion blowup on unbounded-looking empty fills.
func _test_empty_space_termination() -> void:
	var grid: Dictionary = {}  # entirely empty; every read defaults to src -1
	var bounds := Rect2i(0, 0, 5, 5)  # 25 empty cells
	var read := _make_read(grid)
	# Caller captures the seed's identity: empty cell -> src -1, atlas (-1,-1).
	var seed_id: Dictionary = read.call(Vector2i(2, 2))
	var out := FloodFill.compute(
		Vector2i(2, 2), seed_id["src"], seed_id["atlas"], bounds, read, _neighbors, 10000)

	_i_eq(out.size(), 25, "empty-space fill covers the whole 5x5 bounded empty region")
	_ok(_has(out, Vector2i(0, 0)), "empty-space fill reaches corner (0,0)")
	_ok(_has(out, Vector2i(4, 4)), "empty-space fill reaches corner (4,4)")

## 7. An out-of-bounds seed returns empty.
func _test_out_of_bounds_seed() -> void:
	var atlas := Vector2i(0, 0)
	var grid: Dictionary = {}
	grid[Vector2i(0, 0)] = { "src": 1, "atlas": atlas }
	var bounds := Rect2i(0, 0, 3, 3)
	var out := FloodFill.compute(Vector2i(10, 10), 1, atlas, bounds, _make_read(grid), _neighbors, 10000)

	_i_eq(out.size(), 0, "out-of-bounds seed -> empty result")

## 8. A single isolated matching cell (no matching neighbors) -> region of size 1.
func _test_single_isolated_cell() -> void:
	var atlas := Vector2i(0, 0)
	var grid: Dictionary = {}
	grid[Vector2i(2, 2)] = { "src": 7, "atlas": atlas }  # lone cell, everything else empty
	var bounds := Rect2i(-5, -5, 20, 20)
	var out := FloodFill.compute(Vector2i(2, 2), 7, atlas, bounds, _make_read(grid), _neighbors, 10000)

	_i_eq(out.size(), 1, "single isolated cell -> region of size 1")
	_ok(_has(out, Vector2i(2, 2)), "single isolated region contains the seed")
