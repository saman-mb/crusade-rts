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
	return {"ok": true, "doc": migrated, "error_line": 0, "error_message": ""}

## Parses + validates text, then rebuilds the provided TileMapLayers from it. Returns
## { "ok": bool, "diagnostics": Array }. A parse failure or an unusable root shape
## returns ok false with the reason(s); otherwise every provided layer is cleared and
## the sanitized cells are painted, and validate's per-cell/-layer diagnostics are
## returned. layers is indexed by elevation: a layer whose elevation is out of range
## (or whose slot is null) is skipped with a diagnostic rather than crashing.
static func load_into_layers(text: String, layers: Array[TileMapLayer], tile_set: TileSet) -> Dictionary:
	var parsed := parse(text)
	if not parsed["ok"]:
		return {"ok": false, "diagnostics": ["parse error line %d: %s" % [parsed["error_line"], parsed["error_message"]]]}

	var validated := MapValidator.validate_document(parsed["doc"], tile_set)
	if not validated["ok"]:
		return {"ok": false, "diagnostics": validated["diagnostics"]}

	# Clear every provided layer FIRST, so a layer absent from the doc is still emptied.
	for layer in layers:
		if layer != null:
			layer.clear()

	var doc: Dictionary = validated["data"]
	var doc_layers: Array = doc.get(MapSchema.KEY_LAYERS, [])
	var diagnostics: Array = validated["diagnostics"]

	for layer_dict in doc_layers:
		if typeof(layer_dict) != TYPE_DICTIONARY:
			continue
		var elevation := int(layer_dict.get(MapSchema.KEY_LAYER_ELEVATION, 0))
		if elevation < 0 or elevation >= layers.size():
			diagnostics.append("layer elevation %d out of range -- skipped" % elevation)
			continue
		var target: TileMapLayer = layers[elevation]
		if target == null:
			diagnostics.append("layer elevation %d target is null -- skipped" % elevation)
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
