extends SceneTree
## Runtime tests for MapValidator against a REAL in-memory Godot 4.4 TileSet.
## Authored + statically checked now, executed once a binary is available:
##   godot --headless --script <this file>
## Proves the structural cell/document checks (shape, bounds, source ownership,
## atlas-tile existence) hold, that malformed input never crashes, that
## validate_document deep-copies (never mutates the caller's doc), and that
## JSON-float coords still validate through the int() casts.

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
	var ts := _build_tileset()
	var sid := ts.get_source_id(0)  ## the one valid source id; atlas (0,0) is its only tile.

	_test_valid_cell(ts, sid)
	_test_bounds(ts, sid)
	_test_source_and_atlas(ts, sid)
	_test_non_dict_and_null(ts, sid)
	_test_validate_document(ts, sid)
	_test_non_mutation(ts, sid)
	_test_json_roundtrip(ts, sid)
	_test_alternative_tile(ts, sid)
	_test_required_root_keys(ts, sid)

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

## Builds a minimal isometric DIAMOND_DOWN TileSet with a single atlas source whose
## tile (0,0) exists, backed by an in-memory ImageTexture (no GPU/atlas file).
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

## Builds a cell dict from raw components.
func _cell(px: int, py: int, s: int, ax: int, ay: int) -> Dictionary:
	return {
		MapSchema.KEY_CELL_POS: [px, py],
		MapSchema.KEY_CELL_SOURCE: s,
		MapSchema.KEY_CELL_ATLAS: [ax, ay],
	}

# --- tests ---

## A fully well-formed cell against a matching source/atlas is valid.
func _test_valid_cell(ts: TileSet, sid: int) -> void:
	_ok(MapValidator.valid_cell(_cell(3, 5, sid, 0, 0), ts), "happy cell is valid")

## Malformed pos shapes and out-of-bounds coords are rejected; boundary is inside.
func _test_bounds(ts: TileSet, sid: int) -> void:
	var short_pos := {
		MapSchema.KEY_CELL_POS: [1],
		MapSchema.KEY_CELL_SOURCE: sid,
		MapSchema.KEY_CELL_ATLAS: [0, 0],
	}
	_ok(not MapValidator.valid_cell(short_pos, ts), "pos array size 1 is invalid")

	var non_array_pos := {
		MapSchema.KEY_CELL_POS: 5,
		MapSchema.KEY_CELL_SOURCE: sid,
		MapSchema.KEY_CELL_ATLAS: [0, 0],
	}
	_ok(not MapValidator.valid_cell(non_array_pos, ts), "non-array pos is invalid")

	var missing_pos := {
		MapSchema.KEY_CELL_SOURCE: sid,
		MapSchema.KEY_CELL_ATLAS: [0, 0],
	}
	_ok(not MapValidator.valid_cell(missing_pos, ts), "missing pos is invalid")

	_ok(not MapValidator.valid_cell(_cell(MapSchema.MAX_COORD + 1, 0, sid, 0, 0), ts),
		"x just past MAX_COORD is invalid")
	_ok(MapValidator.valid_cell(_cell(MapSchema.MAX_COORD, -MapSchema.MAX_COORD, sid, 0, 0), ts),
		"boundary coords (+MAX, -MAX) are valid")

## Unknown/negative source ids and non-existent atlas tiles are rejected.
func _test_source_and_atlas(ts: TileSet, sid: int) -> void:
	_ok(not MapValidator.valid_cell(_cell(0, 0, sid + 999, 0, 0), ts),
		"unknown source id is invalid")
	_ok(not MapValidator.valid_cell(_cell(0, 0, -1, 0, 0), ts),
		"negative source id is invalid")
	# A non-numeric source (corrupt/hand-edited) must drop cleanly, not coerce via int().
	var dict_source := {
		MapSchema.KEY_CELL_POS: [0, 0],
		MapSchema.KEY_CELL_SOURCE: {"x": 0},
		MapSchema.KEY_CELL_ATLAS: [0, 0],
	}
	_ok(not MapValidator.valid_cell(dict_source, ts), "non-numeric source id is invalid (no coerce)")
	_ok(not MapValidator.valid_cell(_cell(0, 0, sid, 1, 1), ts),
		"atlas tile (1,1) never created is invalid")
	_ok(MapValidator.valid_cell(_cell(0, 0, sid, 0, 0), ts),
		"atlas tile (0,0) created is valid")

## Non-dict cells and a null TileSet return false without crashing.
func _test_non_dict_and_null(ts: TileSet, sid: int) -> void:
	_ok(not MapValidator.valid_cell(42, ts), "int cell is invalid (no crash)")
	_ok(not MapValidator.valid_cell([], ts), "array cell is invalid (no crash)")
	_ok(not MapValidator.valid_cell(_cell(0, 0, sid, 0, 0), null),
		"null tile_set is invalid (no crash)")

## validate_document: bad roots fail ok; a good doc keeps only valid cells.
func _test_validate_document(ts: TileSet, sid: int) -> void:
	var bad_root := MapValidator.validate_document(99, ts)
	_ok(bad_root["ok"] == false, "non-dict root -> ok false")
	_ok((bad_root["diagnostics"] as Array).size() >= 1, "non-dict root -> a diagnostic")

	var bad_layers := MapValidator.validate_document(
		{MapSchema.KEY_SCHEMA_VERSION: MapSchema.CURRENT_SCHEMA, MapSchema.KEY_LAYERS: "oops"}, ts)
	_ok(bad_layers["ok"] == false, "non-array layers -> ok false")

	var good := _cell(1, 1, sid, 0, 0)
	var bad := _cell(2, 2, sid + 999, 0, 0)
	var good2 := _cell(3, 3, sid, 0, 0)
	var doc := {
		MapSchema.KEY_SCHEMA_VERSION: MapSchema.CURRENT_SCHEMA,
		MapSchema.KEY_LAYERS: [{
			MapSchema.KEY_LAYER_NAME: "t",
			MapSchema.KEY_LAYER_ELEVATION: 0,
			MapSchema.KEY_CELLS: [good, bad, good2],
		}],
	}
	var res := MapValidator.validate_document(doc, ts)
	_ok(res["ok"] == true, "good doc -> ok true")
	var out_layers: Array = res["data"][MapSchema.KEY_LAYERS]
	_i_eq(out_layers.size(), 1, "one layer survives")
	var out_cells: Array = out_layers[0][MapSchema.KEY_CELLS]
	_i_eq(out_cells.size(), 2, "invalid cell dropped, 2 kept")
	_ok((res["diagnostics"] as Array).size() >= 1, "skipped cell produced a diagnostic")

## validate_document deep-copies -- the caller's original doc is left intact.
func _test_non_mutation(ts: TileSet, sid: int) -> void:
	var doc := {
		MapSchema.KEY_SCHEMA_VERSION: MapSchema.CURRENT_SCHEMA,
		MapSchema.KEY_LAYERS: [{
			MapSchema.KEY_LAYER_NAME: "t",
			MapSchema.KEY_LAYER_ELEVATION: 0,
			MapSchema.KEY_CELLS: [
				_cell(1, 1, sid, 0, 0),
				_cell(2, 2, sid + 999, 0, 0),
				_cell(3, 3, sid, 0, 0),
			],
		}],
	}
	MapValidator.validate_document(doc, ts)
	var orig_cells: Array = doc[MapSchema.KEY_LAYERS][0][MapSchema.KEY_CELLS]
	_i_eq(orig_cells.size(), 3, "original doc untouched (deep copy)")

## alt (alternative_tile): a nonzero alt must name an alternative the source owns.
## A real alt passes; a nonexistent or negative alt is dropped; alt 0 (base) passes. (#44)
func _test_alternative_tile(ts: TileSet, sid: int) -> void:
	var src := ts.get_source(sid) as TileSetAtlasSource
	var alt_id := src.create_alternative_tile(Vector2i(0, 0))  # a real alternative on (0,0)
	_ok(alt_id > 0, "created a real alternative tile id (%d)" % alt_id)

	var valid_alt := _cell(0, 0, sid, 0, 0)
	valid_alt[MapSchema.KEY_CELL_ALT] = alt_id
	_ok(MapValidator.valid_cell(valid_alt, ts), "cell with an existing alt is valid")

	var bad_alt := _cell(0, 0, sid, 0, 0)
	bad_alt[MapSchema.KEY_CELL_ALT] = alt_id + 999
	_ok(not MapValidator.valid_cell(bad_alt, ts), "cell with a non-existent alt is invalid")

	var neg_alt := _cell(0, 0, sid, 0, 0)
	neg_alt[MapSchema.KEY_CELL_ALT] = -1
	_ok(not MapValidator.valid_cell(neg_alt, ts), "negative alt is invalid")

	var non_numeric_alt := _cell(0, 0, sid, 0, 0)
	non_numeric_alt[MapSchema.KEY_CELL_ALT] = {"x": 1}
	_ok(not MapValidator.valid_cell(non_numeric_alt, ts), "non-numeric alt is invalid (no coerce)")

	# alt 0 / absent (the base tile) stays valid -- the common case.
	var alt_zero := _cell(0, 0, sid, 0, 0)
	alt_zero[MapSchema.KEY_CELL_ALT] = 0
	_ok(MapValidator.valid_cell(alt_zero, ts), "explicit alt 0 (base tile) is valid")
	_ok(MapValidator.valid_cell(_cell(0, 0, sid, 0, 0), ts), "absent alt defaults to base tile, valid")

## validate_document enforces REQUIRED_ROOT_KEYS: a doc missing schema_version is
## rejected even if 'layers' is fine; the helper mirrors that. (#41)
func _test_required_root_keys(ts: TileSet, sid: int) -> void:
	_ok(MapSchema.has_required_root_keys(
		{MapSchema.KEY_SCHEMA_VERSION: MapSchema.CURRENT_SCHEMA, MapSchema.KEY_LAYERS: []}),
		"has_required_root_keys true when both keys present")
	_ok(not MapSchema.has_required_root_keys({MapSchema.KEY_LAYERS: []}),
		"has_required_root_keys false without schema_version")
	_ok(not MapSchema.has_required_root_keys(42), "has_required_root_keys false on non-dict")

	var no_version := MapValidator.validate_document({MapSchema.KEY_LAYERS: []}, ts)
	_ok(no_version["ok"] == false, "validate_document rejects a doc missing schema_version")
	_ok((no_version["diagnostics"] as Array).size() >= 1, "missing-root-key doc yields a diagnostic")

## A JSON round-trip decodes coords as float; int() casts keep the cell valid.
func _test_json_roundtrip(ts: TileSet, sid: int) -> void:
	var parsed := JSON.new()
	parsed.parse(JSON.stringify({
		MapSchema.KEY_CELL_POS: [3, 5],
		MapSchema.KEY_CELL_SOURCE: sid,
		MapSchema.KEY_CELL_ATLAS: [0, 0],
	}))
	var c: Dictionary = parsed.get_data()
	_ok(MapValidator.valid_cell(c, ts),
		"JSON-roundtripped cell (float coords) still valid via int() casts")
