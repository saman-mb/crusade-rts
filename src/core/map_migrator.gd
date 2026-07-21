class_name MapMigrator
extends RefCounted
## Sequential migrate-UP chain that lifts any older map document to
## MapSchema.CURRENT_SCHEMA before the loader consumes it. Each step bumps the
## version by exactly one (v0 -> v1 -> v2), so new on-disk shapes only ever add a
## single, isolated transform. The chain is defensive: every key is typeof/has
## guarded before it is indexed, so a malformed document is passed through as-is
## rather than crashing mid-migration (never migrate-then-crash).
##
## Guarantees:
##  - Non-mutating: the caller's Dictionary is deep-copied first, never touched.
##  - Monotonic: the returned document's schema_version is always CURRENT_SCHEMA,
##    regardless of the input version (a missing version is treated as v0).
##  - Idempotent: migrating an already-current document changes nothing meaningful.
##
## Call order for the loader (#5):
##   parse -> MapMigrator.migrate(doc) -> MapValidator.validate_document(doc, tile_set)

## Migrates a parsed map document UP to CURRENT_SCHEMA. Deep-copies the input so
## the caller's Dictionary is never mutated. A missing schema_version is read as
## v0. Steps run in order, each guarded by the incoming version, so a v1 document
## only runs the v1 -> v2 step. The output version is stamped to CURRENT_SCHEMA.
static func migrate(doc: Dictionary) -> Dictionary:
	var out: Dictionary = doc.duplicate(true)
	var v := int(out.get(MapSchema.KEY_SCHEMA_VERSION, 0))  ## missing version treated as v0.
	if v < 1:
		out = _v0_to_v1(out)
	if v < 2:
		out = _v1_to_v2(out)
	out[MapSchema.KEY_SCHEMA_VERSION] = MapSchema.CURRENT_SCHEMA
	return out

## v0 -> v1: the legacy pre-versioned format stored a single top-level "cells"
## list with no "layers". Wraps those cells into one "terrain" layer at elevation
## 0 and removes the old top-level cells key. All other root keys are preserved.
static func _v0_to_v1(doc: Dictionary) -> Dictionary:
	if not doc.has(MapSchema.KEY_LAYERS):
		var old_cells: Variant = doc.get(MapSchema.KEY_CELLS)
		var cells: Array = old_cells if typeof(old_cells) == TYPE_ARRAY else []
		var layer: Dictionary = {
			MapSchema.KEY_LAYER_NAME: "terrain",
			MapSchema.KEY_LAYER_ELEVATION: 0,
			MapSchema.KEY_CELLS: cells,
		}
		doc[MapSchema.KEY_LAYERS] = [layer]
		if doc.has(MapSchema.KEY_CELLS):
			doc.erase(MapSchema.KEY_CELLS)
	return doc

## v1 -> v2: normalizes coord encoding and guarantees every layer has an
## elevation. Cell "p"/"a" move from the v1 dict form {"x":X,"y":Y} to the v2 flat
## [X, Y] array. Every container is typeof-guarded before indexing, so a malformed
## layer or cell is left untouched instead of crashing.
static func _v1_to_v2(doc: Dictionary) -> Dictionary:
	var layers: Variant = doc.get(MapSchema.KEY_LAYERS, [])
	if typeof(layers) != TYPE_ARRAY:
		return doc
	for layer in layers:
		if typeof(layer) != TYPE_DICTIONARY:
			continue
		if not layer.has(MapSchema.KEY_LAYER_ELEVATION):
			layer[MapSchema.KEY_LAYER_ELEVATION] = 0
		var cells: Variant = layer.get(MapSchema.KEY_CELLS)
		if typeof(cells) != TYPE_ARRAY:
			continue
		for cell in cells:
			if typeof(cell) != TYPE_DICTIONARY:
				continue
			if cell.has(MapSchema.KEY_CELL_POS):
				cell[MapSchema.KEY_CELL_POS] = _coord_to_array(cell[MapSchema.KEY_CELL_POS])
			if cell.has(MapSchema.KEY_CELL_ATLAS):
				cell[MapSchema.KEY_CELL_ATLAS] = _coord_to_array(cell[MapSchema.KEY_CELL_ATLAS])
	return doc

## Coerces a coord from the v1 dict encoding {"x":X,"y":Y} to the v2 flat [X, Y]
## array. An already-flat Array (or any other shape) is returned unchanged, so the
## step is safe to re-run on a partially-migrated document.
static func _coord_to_array(c: Variant) -> Variant:
	if typeof(c) == TYPE_DICTIONARY and c.has("x") and c.has("y"):
		return [c["x"], c["y"]]
	return c
