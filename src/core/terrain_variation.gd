class_name TerrainVariation
extends RefCounted
## Runtime pass that remaps each solid-grass / water cell onto its POSITIONAL
## mega-tile window, so the ground artwork flows continuously across cells: the
## atlas windows are crops of one seamless mega texture cut at the exact screen
## offsets of the cells they land on (see TileSetConstants and
## tools/pack_terrain_atlas.py). A field of one repeated tile always reads as a
## grid; a field of positional windows reads as ONE surface -- SC1's technique.
##
## Mirrors NavMapBuilder's pattern: pure logic probing/writing a live
## TileMapLayer, no other Node deps, headless-testable. Pure positional math (no
## hashing), so the pass is deterministic and idempotent -- re-running after a
## save/reload reproduces the identical result. MapSerializer normalizes window
## coords back to the canonical painted tiles on save, so map files stay
## backward-compatible and this pass re-derives the windows on every load.

## Remaps every varyable cell of `layer`: solid grass -> its grass window, water
## -> its water window, alt forced to 0 (windows carry no flips, and a legacy
## save's flip alt must not survive the remap). Transition and ramp tiles are
## untouched. Safe no-op on a null layer or a layer with no TileSet.
## get_used_cells() returns a snapshot, so rewriting in place is safe.
static func apply(layer: TileMapLayer) -> void:
	if layer == null or layer.tile_set == null:
		return
	var cells: Array[Vector2i] = layer.get_used_cells()
	for cell in cells:
		var coord: Vector2i = layer.get_cell_atlas_coords(cell)
		var source_id := layer.get_cell_source_id(cell)
		if TileSetConstants.is_grass_coord(coord):
			layer.set_cell(cell, source_id, TileSetConstants.grass_window_coord(cell), 0)
		elif TileSetConstants.is_water_coord(coord):
			layer.set_cell(cell, source_id, TileSetConstants.water_window_coord(cell), 0)
