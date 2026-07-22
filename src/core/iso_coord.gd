class_name IsoCoord
extends RefCounted
## Isometric coordinate conversions at the render boundary (DIAMOND_DOWN).
## Cartesian space -- the logical grid cell plus an integer elevation level --
## is the source of truth; iso pixel positions are produced ONLY here.
## Elevation offsets are never computed inline: they come from MapConstants,
## the single source of truth for tile geometry & vertical steps.

# --- Pure math (no Node deps) ---

## Cartesian cell -> local iso pixel (diamond center). Matches
## TileMapLayer.map_to_local: Godot anchors the isometric cell origin a half-tile
## from our raw diamond origin, so we add the (w, h) origin offset -- making this
## pure math a faithful, Node-free replica of the layer transform.
static func cart_to_iso(cell: Vector2i, tile_size := MapConstants.TILE_SIZE) -> Vector2:
	var w := tile_size.x / 2.0
	var h := tile_size.y / 2.0
	return Vector2((cell.x - cell.y) * w + w, (cell.x + cell.y) * h + h)

## Local iso pixel -> fractional (continuous) cell coords. Exact inverse of cart_to_iso.
static func iso_to_cart(local_pos: Vector2, tile_size := MapConstants.TILE_SIZE) -> Vector2:
	var w := tile_size.x / 2.0
	var h := tile_size.y / 2.0
	var fx := (local_pos.x - w) / w
	var fy := (local_pos.y - h) / h
	return Vector2((fx + fy) / 2.0, (fy - fx) / 2.0)

## Local iso pixel -> nearest cell. Rounding the exact continuous inverse picks the
## diamond whose CENTER is nearest, which is identical to point-in-diamond containment;
## this is edge-robust and sidesteps godot issue #89423 (local_to_map edge inaccuracy).
static func pick_cell(local_pos: Vector2, tile_size := MapConstants.TILE_SIZE) -> Vector2i:
	return Vector2i(iso_to_cart(local_pos, tile_size).round())

## True when local_pos falls inside the diamond of the given cell (L1 ball in cell space).
static func is_point_in_diamond(local_pos: Vector2, cell: Vector2i, tile_size := MapConstants.TILE_SIZE) -> bool:
	var w := tile_size.x / 2.0
	var h := tile_size.y / 2.0
	var d := local_pos - cart_to_iso(cell, tile_size)
	return abs(d.x) / w + abs(d.y) / h <= 1.0

# --- TileMapLayer render-boundary wrappers ---

## Cell -> layer-local pixel via the layer's own tile geometry.
static func cell_to_local(layer: TileMapLayer, cell: Vector2i) -> Vector2:
	return layer.map_to_local(cell)

## Layer-local pixel -> cell via the layer's own tile geometry.
## WARNING: delegates to TileMapLayer.local_to_map, which has documented edge
## inaccuracy on isometric shapes (godotengine/godot#89423) -- the exact "wrong
## tile at the diamond edge" artifact Story #8 set out to avoid. For mouse / hover
## / hit-testing use `pick_cell_global` (or `pick_cell` in local space) instead:
## they round the exact continuous inverse and are edge-robust. This wrapper is
## kept only for parity/where Godot's own mapping is explicitly wanted. (#13)
static func local_to_cell(layer: TileMapLayer, local_pos: Vector2) -> Vector2i:
	return layer.local_to_map(local_pos)

## Layout-aware adjacent cell (never manual +/-1).
static func neighbor(layer: TileMapLayer, cell: Vector2i, dir: TileSet.CellNeighbor) -> Vector2i:
	return layer.get_neighbor_cell(cell, dir)

## Global pixel position of a cell at an elevation level (offset from MapConstants).
## ASSUMES UNSCALED LAYERS: the base position goes through `to_global` (which
## respects the layer's transform, incl. scale) but the elevation lift is added
## as RAW, unscaled pixels. Correct for the current 1:1-scale layer stack; if a
## layer is ever zoomed/scaled the base and the lift would desync. Revisit then
## by scaling the offset (or applying it pre-`to_global`). Camera zoom is fine --
## it scales the whole canvas uniformly, not individual layers. (#15)
static func tile_world_pos(layer: TileMapLayer, cell: Vector2i, level: int) -> Vector2:
	return layer.to_global(layer.map_to_local(cell)) + MapConstants.elevation_offset(level)

## Global pixel -> nearest cell, using edge-robust diamond picking.
static func pick_cell_global(layer: TileMapLayer, world_pos: Vector2, tile_size := MapConstants.TILE_SIZE) -> Vector2i:
	return pick_cell(layer.to_local(world_pos), tile_size)
