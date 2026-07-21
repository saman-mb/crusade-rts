extends SceneTree
## Runtime tests that drive BrushCore against REAL Godot 4.4 TileMapLayer nodes.
## Requires a Godot 4.4 runtime; authored + statically checked now, executed once a
## binary is available: godot --headless --script <this file>. Each assertion runs a
## resolve() -> apply cycle, proving BrushCore's decisions map onto the live TileSet
## API (set_cell / erase_cell / get_cell_source_id / get_cell_atlas_coords).
##
## Godot 4.4 signatures (NO leading layer arg -- 4.4 dropped it):
##   set_cell(coords, source_id := -1, atlas_coords := Vector2i(-1,-1), alternative := 0)
##   erase_cell(coords); get_cell_source_id(coords); get_cell_atlas_coords(coords).

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
	var ts := _build_tileset()
	var source_id := ts.get_source_id(0)
	var atlas := Vector2i(0, 0)  ## tile (0,0) is created on the source below, so it is a valid cell.

	var layer_a := TileMapLayer.new()
	layer_a.tile_set = ts
	root.add_child(layer_a)

	var layer_b := TileMapLayer.new()
	layer_b.tile_set = ts
	root.add_child(layer_b)

	_test_unpainted(layer_a)
	_test_paint_cycle(layer_a, source_id, atlas)
	_test_clear_cycle(layer_a, source_id, atlas)
	_test_set_cell_minus_one(layer_a, source_id, atlas)
	_test_layer_isolation(layer_a, layer_b, source_id, atlas)

	# Clean up the live nodes before exiting.
	layer_a.queue_free()
	layer_b.queue_free()

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

## Builds a minimal isometric DIAMOND_DOWN TileSet with a single atlas source whose
## tile (0,0) exists, so set_cell has a valid source_id + atlas coord. Backed by an
## in-memory ImageTexture (no GPU/atlas file dependency), mirroring the headless
## TileSet construction in test_iso_coord_tilemap.gd + TileSetBuilder.
func _build_tileset() -> TileSet:
	var ts := TileSet.new()
	ts.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	ts.tile_layout = TileSet.TILE_LAYOUT_DIAMOND_DOWN
	ts.tile_size = MapConstants.TILE_SIZE

	var img := Image.create(
		TileSetConstants.REGION_SIZE.x, TileSetConstants.REGION_SIZE.y, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)

	var src := TileSetAtlasSource.new()
	src.texture = tex
	src.texture_region_size = TileSetConstants.REGION_SIZE
	ts.add_source(src)
	src.create_tile(Vector2i(0, 0))

	return ts

# --- tests ---

## A never-touched cell reports the empty sentinel (-1) through the real API.
func _test_unpainted(layer: TileMapLayer) -> void:
	_i_eq(layer.get_cell_source_id(Vector2i(2, 2)), -1, "unpainted cell source_id == -1")

## resolve(PAINT) -> set_cell writes the tile; a second resolve on the now-identical
## cell is an idempotent NONE.
func _test_paint_cycle(layer: TileMapLayer, source_id: int, atlas: Vector2i) -> void:
	var cell := Vector2i(2, 2)

	var r := BrushCore.resolve(
		BrushCore.Mode.PAINT,
		layer.get_cell_source_id(cell), layer.get_cell_atlas_coords(cell),
		source_id, atlas)
	_ok(r["action"] == BrushCore.Action.WRITE, "PAINT unpainted cell -> WRITE")
	layer.set_cell(cell, r["source_id"], r["atlas_coords"])
	layer.update_internals()
	_i_eq(layer.get_cell_source_id(cell), source_id, "painted cell source_id == source_id")
	_v_eq(layer.get_cell_atlas_coords(cell), atlas, "painted cell atlas == atlas")

	# Resolve again with the cell now equal to the target -> idempotent NONE.
	var again := BrushCore.resolve(
		BrushCore.Mode.PAINT,
		layer.get_cell_source_id(cell), layer.get_cell_atlas_coords(cell),
		source_id, atlas)
	_ok(again["action"] == BrushCore.Action.NONE, "idempotent PAINT on identical cell -> NONE")

## resolve(ERASE) -> erase_cell clears a painted cell back to the -1 sentinel.
func _test_clear_cycle(layer: TileMapLayer, source_id: int, atlas: Vector2i) -> void:
	var cell := Vector2i(3, 3)
	layer.set_cell(cell, source_id, atlas)
	layer.update_internals()
	_i_eq(layer.get_cell_source_id(cell), source_id, "pre-clear cell is painted")

	var r := BrushCore.resolve(
		BrushCore.Mode.ERASE,
		layer.get_cell_source_id(cell), layer.get_cell_atlas_coords(cell),
		source_id, atlas)
	_ok(r["action"] == BrushCore.Action.CLEAR, "ERASE painted cell -> CLEAR")
	_i_eq(r["source_id"], BrushCore.EMPTY_SOURCE_ID, "ERASE result source_id == -1")
	layer.erase_cell(cell)
	layer.update_internals()
	_i_eq(layer.get_cell_source_id(cell), -1, "erased cell source_id == -1")

## The set_cell(cell, -1) form clears a cell -- proves the -1 sentinel clear path.
func _test_set_cell_minus_one(layer: TileMapLayer, source_id: int, atlas: Vector2i) -> void:
	var cell := Vector2i(5, 5)
	layer.set_cell(cell, source_id, atlas)
	layer.update_internals()
	_i_eq(layer.get_cell_source_id(cell), source_id, "pre-minus-one cell is painted")

	layer.set_cell(cell, -1)
	layer.update_internals()
	_i_eq(layer.get_cell_source_id(cell), -1, "set_cell(cell, -1) clears -> source_id == -1")

## Painting one layer must not bleed into a sibling layer sharing the same TileSet.
func _test_layer_isolation(layer_a: TileMapLayer, layer_b: TileMapLayer, source_id: int, atlas: Vector2i) -> void:
	var cell := Vector2i(4, 4)
	layer_a.set_cell(cell, source_id, atlas)
	layer_a.update_internals()
	_i_eq(layer_a.get_cell_source_id(cell), source_id, "layer_a (4,4) painted")
	_i_eq(layer_b.get_cell_source_id(cell), -1, "layer_b (4,4) untouched == -1")
