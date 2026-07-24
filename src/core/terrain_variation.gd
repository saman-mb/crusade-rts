class_name TerrainVariation
extends RefCounted
## Runtime pass that gives each varyable terrain cell a deterministic per-cell
## alternative_tile (#232), so a field of the SAME atlas tile stops reading as one
## stamp repeated on a visible grid. Mirrors NavMapBuilder's pattern: pure logic
## that probes/writes a live TileMapLayer, no other Node deps, headless-testable.
##
## Split of concerns: the variant LOOK (flip_h/flip_v/modulate per index) is baked
## onto the TileSet alternatives by TileSetBuilder; the per-cell CHOICE is
## VariationPicker (deterministic hash); this just walks the painted cells and
## applies the choice. Because the pick is deterministic, re-running after a
## save/reload is idempotent and the chosen alternative round-trips on disk.

## Assigns every varyable cell of `layer` its VariationPicker alternative_tile.
## Non-varyable tiles (variant_count_for == 1) are left untouched. Safe no-op on a
## null layer or a layer with no TileSet. get_used_cells() returns a snapshot, so
## rewriting each cell's alternative in place during the walk is safe.
static func apply(layer: TileMapLayer) -> void:
	if layer == null or layer.tile_set == null:
		return
	var cells: Array[Vector2i] = layer.get_used_cells()
	for cell in cells:
		var coord: Vector2i = layer.get_cell_atlas_coords(cell)
		var count := TileSetConstants.variant_count_for(coord)
		if count <= 1:
			continue
		var source_id := layer.get_cell_source_id(cell)
		var alt := VariationPicker.pick(cell, count)
		layer.set_cell(cell, source_id, coord, alt)
