class_name MapLoader
extends RefCounted
## Parses a map JSON document, migrates it UP to the current schema (#7 MapMigrator),
## validates it against the LIVE TileSet (#7 MapValidator), then rebuilds the target
## TileMapLayers from the sanitized document. Every target layer is cleared FIRST, so
## stale cells never linger -- even a layer absent from the document is emptied. All
## JSON numbers decode as float, so every id/coord read goes through int(). Keys come
## only from MapSchema; there are no string-literal keys and no magic numbers.
##
## Call order:
##   parse -> MapMigrator.migrate (inside parse) -> MapValidator.validate_document -> paint

## Parses raw text into a migrated map document. Returns
## { "ok": bool, "doc": Dictionary, "error_line": int, "error_message": String }.
## On JSON syntax error ok is false with the parser's line/message; on a non-object
## root ok is false with an explanatory message. On success the parsed root is run
## through MapMigrator.migrate so the returned doc is always at CURRENT_SCHEMA.
static func parse(text: String) -> Dictionary:
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		return {
			"ok": false,
			"doc": {},
			"error_line": json.get_error_line(),
			"error_message": json.get_error_message(),
		}
	var data: Variant = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "doc": {}, "error_line": 0, "error_message": "root is not a JSON object"}
	var migrated := MapMigrator.migrate(data as Dictionary)
	# A future/unknown schema is preserved (not downgraded) by the migrator (#39);
	# refuse it here rather than mis-parsing a newer on-disk shape as current.
	var mv := int(migrated.get(MapSchema.KEY_SCHEMA_VERSION, 0))
	if mv > MapSchema.CURRENT_SCHEMA:
		return {"ok": false, "doc": {}, "error_line": 0,
			"error_message": "unsupported future schema_version %d (this build reads up to %d)" % [mv, MapSchema.CURRENT_SCHEMA]}
	return {"ok": true, "doc": migrated, "error_line": 0, "error_message": ""}

## Parses + validates text, then rebuilds the provided elevation TileMapLayers from
## it (terrain only -- object-kind layers in the doc are skipped with a diagnostic).
## Returns { "ok": bool, "diagnostics": Array }. Prefer load_map() when an objects
## overlay exists; this remains for terrain-only callers. layers is indexed by
## elevation: a layer whose elevation is out of range (or null) is skipped.
static func load_into_layers(text: String, layers: Array[TileMapLayer], tile_set: TileSet) -> Dictionary:
	return _load(text, layers, null, tile_set)

## Parses + validates text, then rebuilds BOTH the elevation stack and the objects
## overlay (#43). Terrain-kind layers route by elevation into `elevation_layers`;
## the objects-kind layer routes to `objects_layer`. Every provided target is
## cleared FIRST (so a layer absent from the doc is emptied). A null objects_layer
## means object-kind entries are skipped with a diagnostic instead of mis-painted.
static func load_map(text: String, elevation_layers: Array[TileMapLayer], objects_layer: TileMapLayer, tile_set: TileSet) -> Dictionary:
	return _load(text, elevation_layers, objects_layer, tile_set)

## Shared load core: parse -> validate -> clear targets -> paint by layer kind.
static func _load(text: String, elevation_layers: Array[TileMapLayer], objects_layer: TileMapLayer, tile_set: TileSet) -> Dictionary:
	var parsed := parse(text)
	if not parsed["ok"]:
		return {"ok": false, "diagnostics": ["parse error line %d: %s" % [parsed["error_line"], parsed["error_message"]]]}

	var validated := MapValidator.validate_document(parsed["doc"], tile_set)
	if not validated["ok"]:
		return {"ok": false, "diagnostics": validated["diagnostics"]}

	# Clear every provided target FIRST, so a layer absent from the doc is still emptied.
	for layer in elevation_layers:
		if layer != null:
			layer.clear()
	if objects_layer != null:
		objects_layer.clear()

	var doc: Dictionary = validated["data"]
	var doc_layers: Array = doc.get(MapSchema.KEY_LAYERS, [])
	var diagnostics: Array = validated["diagnostics"]

	for layer_dict in doc_layers:
		if typeof(layer_dict) != TYPE_DICTIONARY:
			continue
		var target := _resolve_target(layer_dict, elevation_layers, objects_layer, diagnostics)
		if target == null:
			continue
		for cell in layer_dict.get(MapSchema.KEY_CELLS, []):
			if typeof(cell) != TYPE_DICTIONARY:
				continue
			var p: Array = cell[MapSchema.KEY_CELL_POS]
			var a: Array = cell[MapSchema.KEY_CELL_ATLAS]
			target.set_cell(
				Vector2i(int(p[0]), int(p[1])),
				int(cell[MapSchema.KEY_CELL_SOURCE]),
				Vector2i(int(a[0]), int(a[1])),
				int(cell.get(MapSchema.KEY_CELL_ALT, 0)))

	return {"ok": true, "diagnostics": diagnostics}

## Resolves the physical TileMapLayer one doc layer paints into, or null (with a
## diagnostic) when it cannot be routed. Object-kind layers go to objects_layer;
## everything else routes by elevation into elevation_layers. A doc written before
## the `kind` field defaults to terrain, so old files still route by elevation.
static func _resolve_target(layer_dict: Dictionary, elevation_layers: Array[TileMapLayer], objects_layer: TileMapLayer, diagnostics: Array) -> TileMapLayer:
	var kind := String(layer_dict.get(MapSchema.KEY_LAYER_KIND, MapSchema.LAYER_KIND_TERRAIN))
	if kind == MapSchema.LAYER_KIND_OBJECTS:
		if objects_layer == null:
			diagnostics.append("objects-kind layer in doc but no objects target -- skipped")
			return null
		return objects_layer
	var elevation := int(layer_dict.get(MapSchema.KEY_LAYER_ELEVATION, 0))
	if elevation < 0 or elevation >= elevation_layers.size():
		diagnostics.append("layer elevation %d out of range -- skipped" % elevation)
		return null
	var target: TileMapLayer = elevation_layers[elevation]
	if target == null:
		diagnostics.append("layer elevation %d target is null -- skipped" % elevation)
	return target
