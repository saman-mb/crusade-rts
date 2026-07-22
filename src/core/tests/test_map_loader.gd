extends GdTest
## Runtime tests for MapLoader against REAL Godot 4.4 TileMapLayer nodes + an
## in-memory isometric TileSet. Authored + statically checked now, executed once a
## binary is available: godot --headless --script <this file>. Proves that parse
## reports JSON/root errors without crashing, that load_into_layers clears every
## target layer first (no stale cells), migrates a legacy v0 doc up before painting,
## drops validate-rejected cells, casts JSON floats through int() with an alt default
## of 0, keeps layers isolated by elevation, and skips out-of-range elevations.
##
## Godot 4.4 signatures (NO leading layer arg -- 4.4 dropped it):
##   set_cell(coords, source_id := -1, atlas_coords := Vector2i(-1,-1), alternative := 0)
##   get_cell_source_id(coords); get_cell_alternative_tile(coords); clear().


func _run() -> void:
	var ts := _build_tileset()
	var sid := ts.get_source_id(0)  ## the one valid source id; atlas (0,0) is its only tile.

	var layer0 := TileMapLayer.new()
	layer0.tile_set = ts
	root.add_child(layer0)

	var layer1 := TileMapLayer.new()
	layer1.tile_set = ts
	root.add_child(layer1)

	var layers: Array[TileMapLayer] = [layer0, layer1]

	_test_parse_valid()
	_test_parse_corrupt()
	_test_parse_non_object_root()
	_test_parse_refuses_future_version()
	_test_load_refuses_future_version(layers, layer0, sid, ts)
	_test_clears_first(layers, layer0, sid, ts)
	_test_migrate_path(layers, layer0, sid, ts)
	_test_validate_drop(layers, layer0, sid, ts)
	_test_float_cast_and_alt_default(layers, layer0, sid, ts)
	_test_multi_layer(layers, layer0, layer1, sid, ts)
	_test_elevation_out_of_range(layers, sid, ts)

	# Clean up the live nodes before exiting.
	layer0.queue_free()
	layer1.queue_free()


# --- helpers ---

## Builds a minimal isometric DIAMOND_DOWN TileSet with a single atlas source whose
## tile (0,0) exists, backed by an in-memory ImageTexture (no GPU/atlas file), mirroring
## the headless TileSet construction in the validator + brush tilemap tests.
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

## Builds a cell dict from raw components (no alt key, exercising the alt default).
func _cell(px: int, py: int, s: int, ax: int, ay: int) -> Dictionary:
	return {
		MapSchema.KEY_CELL_POS: [px, py],
		MapSchema.KEY_CELL_SOURCE: s,
		MapSchema.KEY_CELL_ATLAS: [ax, ay],
	}

## Builds one layer dict at a given elevation carrying the supplied cells.
func _layer(elevation: int, cells: Array) -> Dictionary:
	return {
		MapSchema.KEY_LAYER_NAME: "t",
		MapSchema.KEY_LAYER_ELEVATION: elevation,
		MapSchema.KEY_CELLS: cells,
	}

## Wraps layers into a CURRENT_SCHEMA root document and serializes it to JSON, so the
## loader receives real float-decoded numbers rather than hand-written literals.
func _doc_json(doc_layers: Array) -> String:
	return JSON.stringify({
		MapSchema.KEY_SCHEMA_VERSION: MapSchema.CURRENT_SCHEMA,
		MapSchema.KEY_LAYERS: doc_layers,
	})

# --- tests ---

## parse of a well-formed root returns ok with a Dictionary doc.
func _test_parse_valid() -> void:
	var res := MapLoader.parse('{"schema_version":2,"layers":[]}')
	_ok(res["ok"] == true, "parse valid -> ok true")
	_ok(typeof(res["doc"]) == TYPE_DICTIONARY, "parse valid -> doc is a Dictionary")

## parse of corrupt JSON fails with a non-empty message and a real error line, no crash.
func _test_parse_corrupt() -> void:
	var res := MapLoader.parse("{not json")
	_ok(res["ok"] == false, "parse corrupt -> ok false")
	_ok((res["error_message"] as String).length() > 0, "parse corrupt -> error_message non-empty")
	# Godot 4.4's JSON reports a 0-based line for a first-line syntax error, so the
	# line index is only guaranteed non-negative; the real "parse failed" signal is
	# ok==false + a non-empty error_message (asserted above).
	_ok(int(res["error_line"]) >= 0, "parse corrupt -> error_line reported (>=0)")

## parse of a non-object JSON root (array) fails cleanly.
func _test_parse_non_object_root() -> void:
	var res := MapLoader.parse("[1,2,3]")
	_ok(res["ok"] == false, "parse non-object root -> ok false")

## parse REFUSES a future schema_version (> CURRENT_SCHEMA): the migrator preserves
## it (no downgrade) and parse returns ok=false with an explanatory message rather
## than mis-reading a newer on-disk shape as current. (#39)
func _test_parse_refuses_future_version() -> void:
	var future := MapSchema.CURRENT_SCHEMA + 1
	var res := MapLoader.parse('{"schema_version":%d,"layers":[]}' % future)
	_ok(res["ok"] == false, "parse future version -> ok false")
	_ok((res["error_message"] as String).length() > 0, "parse future version -> explanatory message")

## A full load of a future-version doc refuses cleanly: ok=false, a diagnostic, and
## crucially the target layers are left untouched (NOT cleared) since the refusal
## happens before any layer mutation. (#39)
func _test_load_refuses_future_version(layers: Array[TileMapLayer], layer0: TileMapLayer, sid: int, ts: TileSet) -> void:
	# Pre-paint a sentinel; a refused load must not clear it.
	layer0.set_cell(Vector2i(7, 7), sid, Vector2i(0, 0))
	layer0.update_internals()
	var future := MapSchema.CURRENT_SCHEMA + 1
	var text := JSON.stringify({
		MapSchema.KEY_SCHEMA_VERSION: future,
		MapSchema.KEY_LAYERS: [_layer(0, [_cell(1, 1, sid, 0, 0)])],
	})
	var res := MapLoader.load_into_layers(text, layers, ts)
	layer0.update_internals()
	_ok(res["ok"] == false, "load future version -> ok false")
	_ok((res["diagnostics"] as Array).size() >= 1, "load future version -> a diagnostic")
	_i_eq(layer0.get_cell_source_id(Vector2i(7, 7)), sid, "refused load left layer untouched (not cleared)")
	_i_eq(layer0.get_cell_source_id(Vector2i(1, 1)), -1, "refused load painted nothing")
	layer0.clear()

## load_into_layers clears every target layer first: a stray pre-painted cell is gone
## and only the document's cell remains.
func _test_clears_first(layers: Array[TileMapLayer], layer0: TileMapLayer, sid: int, ts: TileSet) -> void:
	layer0.set_cell(Vector2i(9, 9), sid, Vector2i(0, 0))
	layer0.update_internals()
	_i_eq(layer0.get_cell_source_id(Vector2i(9, 9)), sid, "stray cell pre-painted")

	var text := _doc_json([_layer(0, [_cell(1, 1, sid, 0, 0)])])
	var res := MapLoader.load_into_layers(text, layers, ts)
	layer0.update_internals()
	_ok(res["ok"] == true, "clears-first load -> ok true")
	_i_eq(layer0.get_cell_source_id(Vector2i(9, 9)), -1, "stray (9,9) cleared before paint")
	_i_eq(layer0.get_cell_source_id(Vector2i(1, 1)), sid, "doc cell (1,1) painted")

## A legacy v0 doc (top-level cells, no layers) migrates up so its cells land in the
## terrain / elevation-0 layer, then validate + paint.
func _test_migrate_path(layers: Array[TileMapLayer], layer0: TileMapLayer, sid: int, ts: TileSet) -> void:
	var text := JSON.stringify({
		MapSchema.KEY_SCHEMA_VERSION: 0,
		MapSchema.KEY_CELLS: [_cell(2, 2, sid, 0, 0)],
	})
	var res := MapLoader.load_into_layers(text, layers, ts)
	layer0.update_internals()
	_ok(res["ok"] == true, "migrate-path load -> ok true")
	_i_eq(layer0.get_cell_source_id(Vector2i(2, 2)), sid, "migrated legacy cell (2,2) painted at elevation 0")

## A validate-rejected cell (unknown source) is dropped: the good cell paints, the bad
## one never does, and at least one diagnostic is returned.
func _test_validate_drop(layers: Array[TileMapLayer], layer0: TileMapLayer, sid: int, ts: TileSet) -> void:
	var text := _doc_json([_layer(0, [_cell(1, 1, sid, 0, 0), _cell(2, 2, sid + 999, 0, 0)])])
	var res := MapLoader.load_into_layers(text, layers, ts)
	layer0.update_internals()
	_ok(res["ok"] == true, "validate-drop load -> ok true")
	_i_eq(layer0.get_cell_source_id(Vector2i(1, 1)), sid, "good cell (1,1) painted")
	_i_eq(layer0.get_cell_source_id(Vector2i(2, 2)), -1, "bad cell (2,2) NOT painted")
	_ok((res["diagnostics"] as Array).size() >= 1, "dropped cell produced a diagnostic")

## JSON floats cast through int() and a missing alt key defaults to 0.
func _test_float_cast_and_alt_default(layers: Array[TileMapLayer], layer0: TileMapLayer, sid: int, ts: TileSet) -> void:
	var text := _doc_json([_layer(0, [_cell(4, 5, sid, 0, 0)])])
	var res := MapLoader.load_into_layers(text, layers, ts)
	layer0.update_internals()
	_ok(res["ok"] == true, "float-cast load -> ok true")
	_i_eq(layer0.get_cell_source_id(Vector2i(4, 5)), sid, "float coords painted at correct int source")
	_i_eq(layer0.get_cell_alternative_tile(Vector2i(4, 5)), 0, "missing alt key defaults to 0")

## A doc spanning elevation 0 and 1 loads each cell into its own layer with no bleed.
func _test_multi_layer(layers: Array[TileMapLayer], layer0: TileMapLayer, layer1: TileMapLayer, sid: int, ts: TileSet) -> void:
	var text := _doc_json([_layer(0, [_cell(1, 1, sid, 0, 0)]), _layer(1, [_cell(3, 3, sid, 0, 0)])])
	var res := MapLoader.load_into_layers(text, layers, ts)
	layer0.update_internals()
	layer1.update_internals()
	_ok(res["ok"] == true, "multi-layer load -> ok true")
	_i_eq(layer0.get_cell_source_id(Vector2i(1, 1)), sid, "elevation 0 cell in layer0")
	_i_eq(layer1.get_cell_source_id(Vector2i(3, 3)), sid, "elevation 1 cell in layer1")
	_i_eq(layer1.get_cell_source_id(Vector2i(1, 1)), -1, "no cross-bleed: layer1 lacks (1,1)")

## An out-of-range elevation is skipped with a diagnostic and no crash.
func _test_elevation_out_of_range(layers: Array[TileMapLayer], sid: int, ts: TileSet) -> void:
	var text := _doc_json([_layer(99, [_cell(1, 1, sid, 0, 0)])])
	var res := MapLoader.load_into_layers(text, layers, ts)
	_ok(res["ok"] == true, "out-of-range elevation load -> ok true (no crash)")
	_ok((res["diagnostics"] as Array).size() >= 1, "out-of-range elevation produced a diagnostic")
