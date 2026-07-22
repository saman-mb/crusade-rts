class_name TilesetCatalog
extends RefCounted
## A registry of NAMED tileset factories plus a pure swap-and-revalidate op.
## Each registered entry is a Callable factory returning a TileSet -- either built
## procedurally (via TileSetBuilder) or loaded from a real .tres with
## ResourceLoader.load -- so callers can list and construct the available tilesets
## by name without hardcoding a source.
##
## The documented pitfall: swapping a live TileSet under a TileMapLayer can ORPHAN
## cells whose source id or atlas coord the NEW TileSet does not provide. Those
## cells keep pointing at geometry that no longer exists. swap_into assigns the new
## TileSet and then re-validates every painted cell through #7's
## MapValidator.valid_cell, dropping (and diagnosing) the orphans so the layer is
## left structurally consistent with its new TileSet.

## name -> Callable factory. Dictionary preserves insertion order, so names()
## reports registration order.
var _factories: Dictionary = {}

## Registers a named factory. Calling again with the same name overwrites it.
func register(entry_name: String, factory: Callable) -> void:
	_factories[entry_name] = factory

## True when a factory is registered under entry_name.
func has(entry_name: String) -> bool:
	return _factories.has(entry_name)

## The registered names in insertion order.
func names() -> PackedStringArray:
	var out := PackedStringArray()
	for entry_name in _factories.keys():
		out.append(entry_name)
	return out

## Builds the TileSet for entry_name by invoking its factory. Returns null when the
## name is unknown or the factory returned a non-TileSet value.
func build(entry_name: String) -> TileSet:
	if not has(entry_name):
		return null
	var f: Callable = _factories[entry_name]
	var result: Variant = f.call()
	return result as TileSet

## Assigns tile_set to every layer, then drops any cell that the new TileSet can no
## longer paint (unknown source or missing atlas tile). Pure w.r.t. the catalog --
## operates only on the passed layers. Returns
## { "ok": bool, "orphaned": int, "diagnostics": Array }. ok is false only when
## tile_set is null; a null layer in the array is skipped, not an error.
static func swap_into(layers: Array[TileMapLayer], tile_set: TileSet) -> Dictionary:
	if tile_set == null:
		return {"ok": false, "orphaned": 0, "diagnostics": ["null tile_set"]}

	var orphaned := 0
	var diagnostics: Array = []
	for layer in layers:
		if layer == null:
			continue
		layer.tile_set = tile_set
		# Snapshot the used cells FIRST -- we erase during the loop below.
		var used := layer.get_used_cells()
		for c in used:
			var cell := {
				MapSchema.KEY_CELL_POS: [c.x, c.y],
				MapSchema.KEY_CELL_SOURCE: layer.get_cell_source_id(c),
				MapSchema.KEY_CELL_ATLAS: [
					layer.get_cell_atlas_coords(c).x, layer.get_cell_atlas_coords(c).y],
			}
			if not MapValidator.valid_cell(cell, tile_set):
				# Capture the source id BEFORE erasing -- an erased cell reads -1.
				var sid := layer.get_cell_source_id(c)
				layer.erase_cell(c)
				orphaned += 1
				diagnostics.append(
					"orphaned cell %s (source %d) dropped after swap" % [c, sid])

	return {"ok": true, "orphaned": orphaned, "diagnostics": diagnostics}
