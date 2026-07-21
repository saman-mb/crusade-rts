class_name DualGrid
extends RefCounted
## Dual-grid autotiling logic (SC2-style clean edges) in pure integer cell space.
## The DISPLAY grid is offset half a tile from the LOGICAL grid, so each drawn
## display tile straddles the intersection of 4 logical cells. Those 4 cells'
## filled/empty states form a 4-bit corner mask (16 states, 15 non-empty tiles),
## which selects an atlas coord via TileSetConstants.LOOKUP.
##
## This module is PURE integer-cell-space logic -- NO isometric projection here.
## The TileMapLayer owns projection; DUAL-GRID only decides which atlas tile a
## display cell shows and which display cells a logical flip dirties. No Node deps.
##
## Bit convention (corner -> bit): TL=1, TR=2, BL=4, BR=8.
##
## DISPLAY_OFFSET: the display grid is visually offset by half a tile (both axes)
## relative to the logical grid. That offset is applied at the render boundary
## (projection handled elsewhere); this module reasons only in integer cells.

## Empty-tile sentinel: TileSetConstants.LOOKUP[0], returned when no corner is filled.
const SENTINEL := Vector2i(-1, -1)

## Build the 4-bit corner mask from the four corner fill states (TL=1,TR=2,BL=4,BR=8).
static func corner_mask(tl: bool, tr: bool, bl: bool, br: bool) -> int:
	return (1 if tl else 0) | (2 if tr else 0) | (4 if bl else 0) | (8 if br else 0)

## The 4 logical cells a display tile at `dcell` straddles, in TL,TR,BL,BR order.
## Display cell (dx,dy) covers logical corners:
##   TL=(dx-1,dy-1), TR=(dx,dy-1), BL=(dx-1,dy), BR=(dx,dy).
static func logical_corners_of_display(dcell: Vector2i) -> Array[Vector2i]:
	var dx := dcell.x
	var dy := dcell.y
	return [
		Vector2i(dx - 1, dy - 1),
		Vector2i(dx, dy - 1),
		Vector2i(dx - 1, dy),
		Vector2i(dx, dy),
	]

## Atlas coord for a corner mask via TileSetConstants.LOOKUP. Guards the mask into
## 0..15; an out-of-range mask returns SENTINEL rather than indexing out of bounds.
static func atlas_coord_for_mask(mask: int) -> Vector2i:
	if mask < 0 or mask > 15:
		return SENTINEL
	return TileSetConstants.LOOKUP[mask]

## Sample the 4 logical corners of `dcell` via `is_filled.call(cell) -> bool`,
## build the corner mask, and return its atlas coord (SENTINEL when mask == 0).
static func tile_for_display(dcell: Vector2i, is_filled: Callable) -> Vector2i:
	var corners := logical_corners_of_display(dcell)
	var mask := corner_mask(
		is_filled.call(corners[0]),
		is_filled.call(corners[1]),
		is_filled.call(corners[2]),
		is_filled.call(corners[3]),
	)
	return atlas_coord_for_mask(mask)

## The 4 display cells whose mask changes when the single logical cell at
## `logical_cell` flips -- the inverse of logical_corners_of_display:
##   (lx,ly),(lx+1,ly),(lx,ly+1),(lx+1,ly+1).
## For each returned display cell D, `logical_cell` is one of the corners in
## logical_corners_of_display(D), so redrawing exactly these 4 covers every
## display tile affected by the flip (used for incremental large-map updates).
static func changed_display_cells(logical_cell: Vector2i) -> Array[Vector2i]:
	var lx := logical_cell.x
	var ly := logical_cell.y
	return [
		Vector2i(lx, ly),
		Vector2i(lx + 1, ly),
		Vector2i(lx, ly + 1),
		Vector2i(lx + 1, ly + 1),
	]
