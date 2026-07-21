extends SceneTree
## Runtime parity tests for IsoCoord against a live TileMapLayer / TileSet.
## Requires a Godot 4.4 runtime; authored + statically checked now, executed
## once a binary is available: godot --headless --script <this file>.
## Proves our pure iso math matches Godot's own DIAMOND_DOWN tile geometry,
## verifies isometric neighbor adjacency, and covers the tile_world_pos
## height-offset integration and the pick_cell_global world round-trip.

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
	var ts := TileSet.new()
	ts.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	ts.tile_layout = TileSet.TILE_LAYOUT_DIAMOND_DOWN
	ts.tile_size = MapConstants.TILE_SIZE

	var layer := TileMapLayer.new()
	layer.tile_set = ts
	get_root().add_child(layer)

	_test_godot_round_trip(layer)
	_test_parity(layer)
	_test_neighbor_delegates(layer)
	_test_tile_world_pos(layer)
	_test_pick_cell_global(layer)

	# Clean up the live node before exiting.
	layer.queue_free()

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

## cell -> local -> cell round-trips through the layer's real geometry.
func _test_godot_round_trip(layer: TileMapLayer) -> void:
	var cells: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1),
		Vector2i(3, 2), Vector2i(-2, 4), Vector2i(-5, -5), Vector2i(7, -3),
	]
	for c in cells:
		var back := IsoCoord.local_to_cell(layer, IsoCoord.cell_to_local(layer, c))
		_check(back == c, "layer round-trip %s got %s" % [c, back])

## Our pure cart_to_iso must equal Godot's map_to_local for the same cell.
func _test_parity(layer: TileMapLayer) -> void:
	var cells: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1),
		Vector2i(4, 6), Vector2i(-3, 2), Vector2i(-7, -1),
	]
	for c in cells:
		var ours := IsoCoord.cart_to_iso(c)
		var godot := layer.map_to_local(c)
		_check(_v_eq(ours, godot), "parity cart_to_iso(%s)=%s vs map_to_local=%s" % [c, ours, godot])

## neighbor() adjacency, tested via behavior rather than a re-call of the same
## method. These four side directions are the only ones valid for an isometric
## TileSet (the square-grid RIGHT/LEFT/TOP/BOTTOM_SIDE would hit
## get_neighbor_cell's error path and return the input cell). The assertions
## prove real adjacency: each neighbor differs from the source and its siblings,
## and stepping to the opposite side round-trips back to the original cell.
func _test_neighbor_delegates(layer: TileMapLayer) -> void:
	var c := Vector2i(3, 3)
	var dirs: Array[TileSet.CellNeighbor] = [
		TileSet.CELL_NEIGHBOR_TOP_RIGHT_SIDE,
		TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_SIDE,
		TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_SIDE,
		TileSet.CELL_NEIGHBOR_TOP_LEFT_SIDE,
	]
	var neighbors: Array[Vector2i] = []
	for dir in dirs:
		var n := IsoCoord.neighbor(layer, c, dir)
		_check(n != c, "neighbor(%s, %d)=%s must differ from source cell" % [c, dir, n])
		neighbors.append(n)

	# All four neighbors must be distinct from one another.
	for i in neighbors.size():
		for j in range(i + 1, neighbors.size()):
			_check(neighbors[i] != neighbors[j],
				"neighbors %d and %d coincide at %s" % [i, j, neighbors[i]])

	# Opposite-direction involution: stepping to a side then back returns c.
	var tr_bl := IsoCoord.neighbor(layer,
		IsoCoord.neighbor(layer, c, TileSet.CELL_NEIGHBOR_TOP_RIGHT_SIDE),
		TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_SIDE)
	_check(tr_bl == c, "TOP_RIGHT then BOTTOM_LEFT of %s got %s" % [c, tr_bl])
	var tl_br := IsoCoord.neighbor(layer,
		IsoCoord.neighbor(layer, c, TileSet.CELL_NEIGHBOR_TOP_LEFT_SIDE),
		TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_SIDE)
	_check(tl_br == c, "TOP_LEFT then BOTTOM_RIGHT of %s got %s" % [c, tl_br])

## tile_world_pos() must lift each elevation level by exactly the map's
## elevation_offset (AC#2). Level 0 is the un-lifted global world position.
func _test_tile_world_pos(layer: TileMapLayer) -> void:
	var c := Vector2i(2, 3)
	var base := IsoCoord.tile_world_pos(layer, c, 0)
	_check(_v_eq(base, layer.to_global(layer.map_to_local(c))),
		"tile_world_pos level 0 %s vs un-lifted world %s" % [base, layer.to_global(layer.map_to_local(c))])
	for level in range(0, 4):
		var lifted := IsoCoord.tile_world_pos(layer, c, level)
		var expected := MapConstants.elevation_offset(level)
		_check(_v_eq(lifted - base, expected),
			"tile_world_pos level %d shift %s vs elevation_offset %s" % [level, lifted - base, expected])

## pick_cell_global() must invert tile_world_pos: the global world position of a
## cell picks back to that same cell.
func _test_pick_cell_global(layer: TileMapLayer) -> void:
	var cells: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(2, 3), Vector2i(-4, 2),
	]
	for c in cells:
		var picked := IsoCoord.pick_cell_global(layer, IsoCoord.tile_world_pos(layer, c, 0))
		_check(picked == c, "pick_cell_global round-trip %s got %s" % [c, picked])
