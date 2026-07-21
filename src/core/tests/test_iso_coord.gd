extends SceneTree
## Pure-math tests for IsoCoord (no TileSet / Node deps required).
## Self-contained SceneTree runner: godot --headless --script <this file>.
## Geometry convention: W = TILE_SIZE.x / 2 = 64, H = TILE_SIZE.y / 2 = 32.

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
	_test_round_trip()
	_test_exact_values()
	_test_point_in_diamond()
	_test_pick_cell_edges()
	_test_elevation_single_source()

	print("PASS %d / FAIL %d" % [_pass, _fail])
	if _fail > 0:
		OS.set_exit_code(1)
	quit()

# --- helpers ---

## Increments counters; prints only on failure so passing runs stay quiet.
func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: %s" % msg)

## Approximate Vector2 equality via distance (iso math returns floats).
func _v_eq(a: Vector2, b: Vector2) -> bool:
	return a.distance_to(b) < 0.001

# --- tests ---

## Round-trip cart -> iso -> cart over a grid (with negatives + a large cell).
func _test_round_trip() -> void:
	var cells: Array[Vector2i] = []
	for x in range(-3, 4):
		for y in range(-3, 4):
			cells.append(Vector2i(x, y))
	cells.append(Vector2i(1000, -750))
	cells.append(Vector2i(-512, 999))

	for c in cells:
		var back := Vector2i(IsoCoord.iso_to_cart(IsoCoord.cart_to_iso(c)).round())
		_check(back == c, "round-trip iso_to_cart(cart_to_iso(%s)) == %s got %s" % [c, c, back])
		var picked := IsoCoord.pick_cell(IsoCoord.cart_to_iso(c))
		_check(picked == c, "pick_cell(cart_to_iso(%s)) == %s got %s" % [c, c, picked])

## The four canonical cart_to_iso values (W=64, H=32).
func _test_exact_values() -> void:
	_check(_v_eq(IsoCoord.cart_to_iso(Vector2i(0, 0)), Vector2(0, 0)), "cart_to_iso(0,0)=(0,0)")
	_check(_v_eq(IsoCoord.cart_to_iso(Vector2i(1, 0)), Vector2(64, 32)), "cart_to_iso(1,0)=(64,32)")
	_check(_v_eq(IsoCoord.cart_to_iso(Vector2i(0, 1)), Vector2(-64, 32)), "cart_to_iso(0,1)=(-64,32)")
	_check(_v_eq(IsoCoord.cart_to_iso(Vector2i(1, 1)), Vector2(0, 64)), "cart_to_iso(1,1)=(0,64)")

## Center inside, a point past a vertex outside, the four vertices on the boundary.
func _test_point_in_diamond() -> void:
	var h := MapConstants.TILE_SIZE.y / 2.0   # 32
	var w := MapConstants.TILE_SIZE.x / 2.0   # 64
	var cell := Vector2i(2, 2)
	var center := IsoCoord.cart_to_iso(cell)

	_check(IsoCoord.is_point_in_diamond(center, cell), "center inside diamond of %s" % cell)

	# Just past the bottom vertex (H + 2 px below center): outside.
	var outside := center + Vector2(0, h + 2.0)
	_check(not IsoCoord.is_point_in_diamond(outside, cell), "point past vertex is outside %s" % cell)

	# The four vertices sit ~on the boundary (containment is inclusive).
	var verts: Array[Vector2] = [
		center + Vector2(w, 0.0),
		center + Vector2(-w, 0.0),
		center + Vector2(0.0, h),
		center + Vector2(0.0, -h),
	]
	for v in verts:
		_check(IsoCoord.is_point_in_diamond(v, cell), "vertex %s on boundary of %s" % [v, cell])

## Hover points hugging a shared edge resolve to the expected cell (beats
## local_to_map edge inaccuracy, godot#89423).
func _test_pick_cell_edges() -> void:
	# Boundary between cell (0,0) [center (0,0)] and (1,0) [center (64,32)].
	# A point nudged onto the (1,0) side resolves to (1,0); onto the (0,0) side, (0,0).
	var toward_10 := Vector2(34, 17)
	var toward_00 := Vector2(30, 15)
	_check(IsoCoord.pick_cell(toward_10) == Vector2i(1, 0), "edge point %s -> (1,0) got %s" % [toward_10, IsoCoord.pick_cell(toward_10)])
	_check(IsoCoord.pick_cell(toward_00) == Vector2i(0, 0), "edge point %s -> (0,0) got %s" % [toward_00, IsoCoord.pick_cell(toward_00)])

	# A point one pixel inside the right vertex of (2,2) still resolves to (2,2).
	var near_vertex := IsoCoord.cart_to_iso(Vector2i(2, 2)) + Vector2(63, 0)
	_check(IsoCoord.pick_cell(near_vertex) == Vector2i(2, 2), "near-vertex %s -> (2,2) got %s" % [near_vertex, IsoCoord.pick_cell(near_vertex)])

## Elevation offsets come only from MapConstants: level -> Vector2(0, -32*level).
func _test_elevation_single_source() -> void:
	for level in range(0, 4):
		var off := MapConstants.elevation_offset(level)
		var want := Vector2(0, -32 * level)
		_check(off == want, "elevation_offset(%d) == %s got %s" % [level, want, off])
