extends GdTest
## Runtime tests for TilesetCatalog against REAL in-memory Godot 4.4 TileSets and
## live TileMapLayer nodes. Authored + statically checked now, executed once a
## binary is available: godot --headless --script <this file>.
##
## Proves the named-factory registry (register/has/names/build) and, crucially,
## the swap-and-revalidate deliverable: after swap_into assigns a NEW TileSet whose
## atlas lacks a tile some cells used, those orphaned cells are dropped + diagnosed
## while still-valid cells survive. Two TileSets are built: A has atlas tiles (0,0)
## AND (1,1); B has only (0,0) -- so a cell painted at atlas (1,1) orphans when the
## layer swaps from A to B.
##
## Godot 4.4 signatures (NO leading layer arg -- 4.4 dropped it):
##   set_cell(coords, source_id := -1, atlas_coords := Vector2i(-1,-1), alternative := 0)
##   erase_cell(coords); get_cell_source_id(coords); get_cell_atlas_coords(coords).


func _run() -> void:
	var a_tileset := _make_tileset(true)   ## has atlas (0,0) AND (1,1)
	var b_tileset := _make_tileset(false)  ## has only atlas (0,0)

	_test_registry(a_tileset, b_tileset)
	_test_orphan_drop(a_tileset, b_tileset)
	_test_no_orphan(a_tileset)
	_test_null_safety(a_tileset, b_tileset)


# --- helpers ---

## Builds a minimal isometric DIAMOND_DOWN TileSet with a single atlas source whose
## texture spans 2x2 regions (so atlas (1,1) can be created). Tile (0,0) always
## exists; tile (1,1) exists only when alt_tile is true. Backed by an in-memory
## ImageTexture (no GPU/atlas file dependency), mirroring the headless TileSet
## construction in test_brush_core_tilemap.gd + TileSetBuilder.
func _make_tileset(alt_tile: bool) -> TileSet:
	var ts := TileSet.new()
	ts.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	ts.tile_layout = TileSet.TILE_LAYOUT_DIAMOND_DOWN
	ts.tile_size = MapConstants.TILE_SIZE

	var img := Image.create(
		TileSetConstants.REGION_SIZE.x * 2, TileSetConstants.REGION_SIZE.y * 2,
		false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)

	var src := TileSetAtlasSource.new()
	src.texture = tex
	src.texture_region_size = TileSetConstants.REGION_SIZE
	ts.add_source(src)
	src.create_tile(Vector2i(0, 0))
	if alt_tile:
		src.create_tile(Vector2i(1, 1))

	return ts

# --- tests ---

## register/has/names/build: names are reported in insertion order and build
## invokes the factory (unknown names return null).
func _test_registry(a_tileset: TileSet, b_tileset: TileSet) -> void:
	var cat := TilesetCatalog.new()
	cat.register("A", func(): return a_tileset)
	cat.register("B", func(): return b_tileset)

	_ok(cat.has("A") == true, "registered 'A' -> has true")
	_ok(cat.has("nope") == false, "unregistered 'nope' -> has false")

	var registered := cat.names()
	_i_eq(registered.size(), 2, "names() size == 2")
	_ok(registered.has("A"), "names() contains 'A'")
	_ok(registered.has("B"), "names() contains 'B'")

	_ok(cat.build("A") is TileSet, "build('A') returns a TileSet")
	_ok(cat.build("A") == a_tileset, "build('A') returns the A factory's TileSet")
	_ok(cat.build("nope") == null, "build('nope') returns null")

## The deliverable proof: swapping A -> B drops the cell whose atlas (1,1) B lacks,
## keeps the atlas (0,0) cell, and reports the orphan.
func _test_orphan_drop(a_tileset: TileSet, b_tileset: TileSet) -> void:
	var sid := a_tileset.get_source_id(0)

	var layer := TileMapLayer.new()
	layer.tile_set = a_tileset
	root.add_child(layer)
	layer.set_cell(Vector2i(2, 2), sid, Vector2i(0, 0))  ## survives (B has (0,0))
	layer.set_cell(Vector2i(3, 3), sid, Vector2i(1, 1))  ## orphaned (B lacks (1,1))
	layer.update_internals()

	var res := TilesetCatalog.swap_into([layer], b_tileset)
	_ok(res["ok"] == true, "swap A->B -> ok true")
	_i_eq(res["orphaned"], 1, "one cell orphaned")
	_ok((res["diagnostics"] as Array).size() >= 1, "orphan produced a diagnostic")
	_ok(layer.tile_set == b_tileset, "layer.tile_set is now B")
	_i_eq(layer.get_cell_source_id(Vector2i(2, 2)), sid, "(0,0)-atlas cell survives")
	_i_eq(layer.get_cell_source_id(Vector2i(3, 3)), -1, "(1,1)-atlas cell erased")

	layer.queue_free()

## Swapping into the SAME TileSet (or any TileSet that still owns every cell)
## orphans nothing and leaves the cell intact.
func _test_no_orphan(a_tileset: TileSet) -> void:
	var sid := a_tileset.get_source_id(0)

	var layer2 := TileMapLayer.new()
	layer2.tile_set = a_tileset
	root.add_child(layer2)
	layer2.set_cell(Vector2i(4, 4), sid, Vector2i(0, 0))
	layer2.update_internals()

	var res := TilesetCatalog.swap_into([layer2], a_tileset)
	_ok(res["ok"] == true, "swap A->A -> ok true")
	_i_eq(res["orphaned"], 0, "no cell orphaned")
	_i_eq(layer2.get_cell_source_id(Vector2i(4, 4)), sid, "cell intact after no-orphan swap")

	layer2.queue_free()

## Null layer entries, an empty layer array, and a null TileSet must not crash.
func _test_null_safety(a_tileset: TileSet, b_tileset: TileSet) -> void:
	var null_layer := TilesetCatalog.swap_into([null], b_tileset)
	_ok(null_layer["ok"] == true, "swap_into([null]) -> ok true (no crash)")
	_i_eq(null_layer["orphaned"], 0, "swap_into([null]) -> 0 orphaned")

	var empty := TilesetCatalog.swap_into([], b_tileset)
	_ok(empty["ok"] == true, "swap_into([]) -> ok true")
	_i_eq(empty["orphaned"], 0, "swap_into([]) -> 0 orphaned")

	var sid := a_tileset.get_source_id(0)
	var layer := TileMapLayer.new()
	layer.tile_set = a_tileset
	root.add_child(layer)
	layer.set_cell(Vector2i(2, 2), sid, Vector2i(0, 0))
	layer.update_internals()

	var null_ts := TilesetCatalog.swap_into([layer], null)
	_ok(null_ts["ok"] == false, "swap_into(_, null) -> ok false")
	_i_eq(null_ts["orphaned"], 0, "swap_into(_, null) -> 0 orphaned")

	layer.queue_free()
