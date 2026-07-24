class_name DoodadCatalog
extends RefCounted
## Single source of truth for the procedural doodad atlas layout (#234, Tier 3).
## Mirrors tools/gen_doodads.py: a CELL x CELL grid, one ROW per doodad type,
## VARIANTS columns of jittered variants. The runtime reads region rects + the
## base anchor from here so nothing hardcodes the atlas geometry at a call site.

const ATLAS_PATH := "res://assets/doodads/doodads.png"
const CELL := 64            ## px per doodad cell (square) -- matches gen_doodads.CELL
const VARIANTS := 4         ## variants per type (columns) -- matches gen_doodads.VARIANTS
## Pixels from the cell's bottom edge to the doodad's visual base (contact point).
## gen_doodads draws the base at y = CELL - BASE_INSET, so the sprite anchors there.
const BASE_INSET := 6

## Doodad type row indices -- MUST match the TYPES order in gen_doodads.py.
const TYPE_ROCK := 0
const TYPE_BUSH := 1
const TYPE_GRASS := 2
const TYPE_FLOWER := 3
const TYPE_PEBBLE := 4
const TYPE_COUNT := 5

## Scatter weighting: how often each type is chosen, out of WEIGHT_TOTAL. Ground
## detail (grass/pebbles) is common; rocks/bushes/flowers are accents. Index ==
## type row. Kept here (not in the pure scatter) so tuning the mix is one edit.
const TYPE_WEIGHTS: Array[int] = [3, 3, 8, 4, 6]   ## rock,bush,grass,flower,pebble
const WEIGHT_TOTAL := 24                            ## == sum(TYPE_WEIGHTS)

## Atlas region rect for a (type_row, variant) pair. Variant is wrapped into range.
static func region(type_row: int, variant: int) -> Rect2:
	var col := (variant % VARIANTS + VARIANTS) % VARIANTS
	return Rect2(col * CELL, type_row * CELL, CELL, CELL)

## Sprite2D.offset (with centered=false) that lands the doodad's base-centre at the
## node origin, then lifts the art onto `tier`. Origin stays at the footprint so the
## doodad Y-sorts exactly like a unit; the lift is a pure draw offset (EntityPlacement).
static func art_offset(tier: int) -> Vector2:
	return EntityPlacement.visual_offset(tier) - Vector2(CELL / 2.0, CELL - BASE_INSET)

## Maps a 0..WEIGHT_TOTAL-1 roll onto a doodad type row via TYPE_WEIGHTS, so common
## types are picked proportionally more often. Deterministic; used by the scatter.
static func weighted_type(roll: int) -> int:
	var r := (roll % WEIGHT_TOTAL + WEIGHT_TOTAL) % WEIGHT_TOTAL
	var acc := 0
	for t in range(TYPE_COUNT):
		acc += TYPE_WEIGHTS[t]
		if r < acc:
			return t
	return TYPE_COUNT - 1
