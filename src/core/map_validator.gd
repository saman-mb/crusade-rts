class_name MapValidator
extends RefCounted
## Structural safety checks run BEFORE any tilemap mutation, so a hand-edited or
## corrupt map file can never crash the load or write a garbage cell. Every check
## is skip-and-log: one bad cell (or one bad layer) is dropped and diagnosed, the
## rest of the document keeps loading -- a single malformed entry never aborts the
## whole load. This core only DROPS + DIAGNOSES skipped cells; the loader (#5)
## decides what fallback tile to RENDER in their place. Pure: takes a TileSet
## object only -- no Node, no file IO, no path. JSON numbers all decode as float,
## so every numeric read goes through int() (see _is_number, which also accepts
## already-int values).
##
## Call order for the loader (#5):
##   parse -> MapMigrator.migrate(doc) -> MapValidator.validate_document(doc, tile_set) -> build layers

## True when a cell dict is structurally safe to paint against tile_set: correct
## pos/atlas array shapes, in-bounds coords, a source the TileSet actually owns,
## and an atlas coord that exists on that source. Order matters -- every key is
## read with .get() and typeof-checked before indexing, so a missing key returns
## false instead of crashing.
static func valid_cell(cell: Variant, tile_set: TileSet) -> bool:
	if typeof(cell) != TYPE_DICTIONARY:
		return false

	var p: Variant = cell.get(MapSchema.KEY_CELL_POS)
	if typeof(p) != TYPE_ARRAY or p.size() != 2 or not _is_number(p[0]) or not _is_number(p[1]):
		return false
	if absi(int(p[0])) > MapSchema.MAX_COORD or absi(int(p[1])) > MapSchema.MAX_COORD:
		return false

	var s: Variant = cell.get(MapSchema.KEY_CELL_SOURCE, -1)
	if not _is_number(s):
		return false
	var sid := int(s)
	if sid < 0:
		return false
	if tile_set == null or not tile_set.has_source(sid):
		return false

	var a: Variant = cell.get(MapSchema.KEY_CELL_ATLAS)
	if typeof(a) != TYPE_ARRAY or a.size() != 2 or not _is_number(a[0]) or not _is_number(a[1]):
		return false

	var src := tile_set.get_source(sid) as TileSetAtlasSource
	return src != null and src.has_tile(Vector2i(int(a[0]), int(a[1])))

## True for JSON-decoded numbers. JSON yields float, but an already-int value is
## accepted too so callers that build dicts in code aren't rejected.
static func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT

## Validates + sanitizes a parsed map document without mutating the caller's copy.
## Returns { "ok": bool, "data": Dictionary, "diagnostics": Array }. ok is true as
## long as the root is a Dictionary and "layers" is an Array -- even when some
## cells or layers were skipped (those are dropped from data + noted in
## diagnostics). ok is false only for an unusable root shape, in which case data
## is an empty Dictionary. Never crashes on malformed input.
static func validate_document(doc: Variant, tile_set: TileSet) -> Dictionary:
	if typeof(doc) != TYPE_DICTIONARY:
		return {"ok": false, "data": {}, "diagnostics": ["root is not a Dictionary"]}

	# Deep copy so the caller's document is never mutated by the sanitize pass.
	var out: Dictionary = (doc as Dictionary).duplicate(true)

	var layers: Variant = out.get(MapSchema.KEY_LAYERS)
	if typeof(layers) != TYPE_ARRAY:
		return {"ok": false, "data": {}, "diagnostics": ["'layers' missing or not an Array"]}

	var diagnostics: Array = []
	var kept_layers: Array = []
	for i in range(layers.size()):
		var layer: Variant = layers[i]
		if typeof(layer) != TYPE_DICTIONARY:
			diagnostics.append("layer[%d]: not a Dictionary -- dropped" % i)
			continue
		kept_layers.append(_sanitize_layer(layer, i, tile_set, diagnostics))

	out[MapSchema.KEY_LAYERS] = kept_layers
	return {"ok": true, "data": out, "diagnostics": diagnostics}

## Sanitizes one already-confirmed-Dictionary layer: its cells array is coerced to
## [] if missing/wrong-typed, then filtered down to only valid_cell entries. Every
## coercion or dropped cell appends a diagnostic. Returns the same layer dict with
## its cells replaced (operates on the deep-copied layer, so no caller mutation).
static func _sanitize_layer(layer: Dictionary, index: int, tile_set: TileSet, diagnostics: Array) -> Dictionary:
	var cells: Variant = layer.get(MapSchema.KEY_CELLS)
	if typeof(cells) != TYPE_ARRAY:
		diagnostics.append("layer[%d]: 'cells' missing or not an Array -- reset to empty" % index)
		layer[MapSchema.KEY_CELLS] = []
		return layer

	var kept_cells: Array = []
	for j in range(cells.size()):
		var cell: Variant = cells[j]
		if valid_cell(cell, tile_set):
			kept_cells.append(cell)
		else:
			diagnostics.append("layer[%d] cell[%d]: invalid -- skipped" % [index, j])

	layer[MapSchema.KEY_CELLS] = kept_cells
	return layer
