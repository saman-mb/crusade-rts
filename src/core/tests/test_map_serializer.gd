extends GdTest
## Runtime tests that drive MapSerializer against REAL Godot 4.4 TileMapLayer nodes.
## Requires a Godot 4.4 runtime: godot --headless --script <this file>. Proves the
## serializer flattens live cells into the MapSchema JSON shape and that the result
## survives a JSON round-trip (numbers decode as float, structure intact).
##
## Godot 4.4 signatures (NO leading layer arg -- 4.4 dropped it):
##   set_cell(coords, source_id := -1, atlas_coords := Vector2i(-1,-1), alternative := 0)
##   get_used_cells() -> Array[Vector2i]; get_cell_source_id/atlas_coords/alternative_tile.


func _run() -> void:
	var ts := _build_tileset()
	var sid := ts.get_source_id(0)

	var layer := TileMapLayer.new()
	layer.tile_set = ts
	root.add_child(layer)

	var empty := TileMapLayer.new()
	empty.tile_set = ts
	root.add_child(empty)

	layer.set_cell(Vector2i(3, 5), sid, Vector2i(0, 0), 0)
	layer.set_cell(Vector2i(1, 2), sid, Vector2i(0, 0), 0)
	layer.update_internals()

	var doc := MapSerializer.serialize_layers([layer], ["ground"], [0])

	_test_root(doc)
	_test_layer(doc)
	_test_layer_kind_terrain(doc)
	_test_cell(doc, sid)
	_test_empty(empty)
	_test_round_trip(doc)
	_test_serialize_map(ts, sid)

	layer.queue_free()
	empty.queue_free()


# --- helpers ---

## Deep element-wise equality for a flattened [x, y]-style Array.
func _arr_eq(a: Array, b: Array, msg: String) -> void:
	if a.size() != b.size():
		_ok(false, "%s: size expected %d got %d" % [msg, b.size(), a.size()])
		return
	for i in a.size():
		if int(a[i]) != int(b[i]):
			_ok(false, "%s: element %d expected %d got %d" % [msg, i, int(b[i]), int(a[i])])
			return
	_ok(true, msg)

## Builds a minimal isometric DIAMOND_DOWN TileSet with a single atlas source whose
## tile (0,0) exists, so set_cell has a valid source_id + atlas coord. Backed by an
## in-memory ImageTexture (no GPU/atlas file dependency).
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

## Linear search for the cell object whose flattened pos matches [x, y].
## get_used_cells() order is unspecified, so never assume an index.
func _find_cell(cells: Array, pos: Array) -> Dictionary:
	for cell in cells:
		var p: Array = cell[MapSchema.KEY_CELL_POS]
		if int(p[0]) == int(pos[0]) and int(p[1]) == int(pos[1]):
			return cell
	return {}

# --- tests ---

## Root object carries the schema version + metadata provenance fields.
func _test_root(doc: Dictionary) -> void:
	_i_eq(doc[MapSchema.KEY_SCHEMA_VERSION], MapSchema.CURRENT_SCHEMA, "root schema_version == CURRENT_SCHEMA")
	_ok(doc[MapSchema.KEY_TILE_SHAPE] == MapSchema.TILE_SHAPE_NAME, "root tile_shape == TILE_SHAPE_NAME")
	_arr_eq(doc[MapSchema.KEY_TILE_SIZE], [128, 64], "root tile_size == [128, 64]")
	_ok(doc[MapSchema.KEY_GENERATED_BY] == MapSchema.GENERATED_BY_NAME, "root generated_by == GENERATED_BY_NAME")
	_i_eq(typeof(doc[MapSchema.KEY_LAYERS]), TYPE_ARRAY, "root layers is TYPE_ARRAY")
	_i_eq(doc[MapSchema.KEY_LAYERS].size(), 1, "root has 1 layer")

## The single layer object carries its name, elevation, and both cells.
func _test_layer(doc: Dictionary) -> void:
	var layer0: Dictionary = doc[MapSchema.KEY_LAYERS][0]
	_ok(layer0[MapSchema.KEY_LAYER_NAME] == "ground", "layer name == ground")
	_i_eq(layer0[MapSchema.KEY_LAYER_ELEVATION], 0, "layer elevation == 0")
	_i_eq(layer0[MapSchema.KEY_CELLS].size(), 2, "layer has 2 cells")

## The (3,5) cell round-trips its source, atlas, and alternative fields.
func _test_cell(doc: Dictionary, sid: int) -> void:
	var cells: Array = doc[MapSchema.KEY_LAYERS][0][MapSchema.KEY_CELLS]
	var cell := _find_cell(cells, [3, 5])
	_ok(not cell.is_empty(), "found cell at [3, 5]")
	if cell.is_empty():
		return
	_i_eq(cell[MapSchema.KEY_CELL_SOURCE], sid, "cell [3,5] source == sid")
	_arr_eq(cell[MapSchema.KEY_CELL_ATLAS], [0, 0], "cell [3,5] atlas == [0, 0]")
	_i_eq(cell[MapSchema.KEY_CELL_ALT], 0, "cell [3,5] alt == 0")

## serialize_layers now tags every entry kind=terrain so the loader routes them by
## elevation. (#43)
func _test_layer_kind_terrain(doc: Dictionary) -> void:
	var layer0: Dictionary = doc[MapSchema.KEY_LAYERS][0]
	_ok(layer0.has(MapSchema.KEY_LAYER_KIND), "terrain entry carries a kind field")
	_ok(String(layer0[MapSchema.KEY_LAYER_KIND]) == MapSchema.LAYER_KIND_TERRAIN, "terrain entry kind == terrain")

## serialize_map emits terrain entries keyed by elevation index PLUS a single
## objects entry (kind=objects at the OBJECTS_ELEVATION sentinel). A null objects
## layer yields a terrain-only document with no objects entry. (#43)
func _test_serialize_map(ts: TileSet, sid: int) -> void:
	var e0 := TileMapLayer.new()
	e0.tile_set = ts
	root.add_child(e0)
	var e1 := TileMapLayer.new()
	e1.tile_set = ts
	root.add_child(e1)
	var obj := TileMapLayer.new()
	obj.tile_set = ts
	root.add_child(obj)
	e0.set_cell(Vector2i(0, 0), sid, Vector2i(0, 0), 0)
	obj.set_cell(Vector2i(5, 5), sid, Vector2i(0, 0), 0)

	var elev: Array[TileMapLayer] = [e0, e1]
	var doc := MapSerializer.serialize_map(elev, obj)
	var entries: Array = doc[MapSchema.KEY_LAYERS]
	_i_eq(entries.size(), 3, "serialize_map: 2 terrain + 1 objects == 3 entries")

	# Terrain entries: kind=terrain, elevation == index.
	_ok(String(entries[0][MapSchema.KEY_LAYER_KIND]) == MapSchema.LAYER_KIND_TERRAIN, "entry[0] kind terrain")
	_i_eq(int(entries[0][MapSchema.KEY_LAYER_ELEVATION]), 0, "entry[0] elevation 0")
	_i_eq(int(entries[1][MapSchema.KEY_LAYER_ELEVATION]), 1, "entry[1] elevation 1")

	# Objects entry: kind=objects, name=objects, elevation=OBJECTS_ELEVATION sentinel.
	var obj_entry: Dictionary = entries[2]
	_ok(String(obj_entry[MapSchema.KEY_LAYER_KIND]) == MapSchema.LAYER_KIND_OBJECTS, "objects entry kind objects")
	_ok(String(obj_entry[MapSchema.KEY_LAYER_NAME]) == MapSchema.LAYER_NAME_OBJECTS, "objects entry name objects")
	_i_eq(int(obj_entry[MapSchema.KEY_LAYER_ELEVATION]), MapSchema.OBJECTS_ELEVATION, "objects entry at OBJECTS_ELEVATION")
	_i_eq(int(obj_entry[MapSchema.KEY_CELLS].size()), 1, "objects entry carries its 1 cell")

	# Null objects layer -> terrain-only, no objects entry.
	var doc2 := MapSerializer.serialize_map(elev, null)
	var entries2: Array = doc2[MapSchema.KEY_LAYERS]
	_i_eq(entries2.size(), 2, "serialize_map(null objects): terrain-only, 2 entries")
	for entry in entries2:
		_ok(String(entry[MapSchema.KEY_LAYER_KIND]) != MapSchema.LAYER_KIND_OBJECTS, "no objects entry when objects layer null")

	e0.queue_free()
	e1.queue_free()
	obj.queue_free()

## A layer with no painted cells serializes to an empty Array.
func _test_empty(empty: TileMapLayer) -> void:
	var cells := MapSerializer.serialize_layer(empty)
	_i_eq(typeof(cells), TYPE_ARRAY, "empty layer serializes to Array")
	_i_eq(cells.size(), 0, "empty layer has 0 cells")

## to_json produces valid JSON; parsing it back preserves version + structure,
## and the [3,5] cell survives with matching source/atlas/alt.
func _test_round_trip(doc: Dictionary) -> void:
	var s := MapSerializer.to_json(doc)
	var p := JSON.new()
	_i_eq(p.parse(s), OK, "to_json produces valid JSON")
	var back: Dictionary = p.get_data()
	_i_eq(int(back[MapSchema.KEY_SCHEMA_VERSION]), MapSchema.CURRENT_SCHEMA, "round-trip schema_version == CURRENT_SCHEMA")
	_i_eq(back[MapSchema.KEY_LAYERS].size(), 1, "round-trip has 1 layer")

	var back_cells: Array = back[MapSchema.KEY_LAYERS][0][MapSchema.KEY_CELLS]
	var back_cell := _find_cell(back_cells, [3, 5])
	_ok(not back_cell.is_empty(), "round-trip found cell at [3, 5]")
	if back_cell.is_empty():
		return
	var orig_cell := _find_cell(doc[MapSchema.KEY_LAYERS][0][MapSchema.KEY_CELLS], [3, 5])
	_i_eq(int(back_cell[MapSchema.KEY_CELL_SOURCE]), int(orig_cell[MapSchema.KEY_CELL_SOURCE]), "round-trip cell source matches")
	_arr_eq(back_cell[MapSchema.KEY_CELL_ATLAS], orig_cell[MapSchema.KEY_CELL_ATLAS], "round-trip cell atlas matches")
	_i_eq(int(back_cell[MapSchema.KEY_CELL_ALT]), int(orig_cell[MapSchema.KEY_CELL_ALT]), "round-trip cell alt matches")
