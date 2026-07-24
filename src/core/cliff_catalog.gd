class_name CliffCatalog
extends RefCounted
## Single source of truth for the cliff-face art sheet layout (#235 art pass).
## Mirrors tools/gen_cliffs.py: row 0 = 8 SE face pieces, row 1 = 8 SW face
## pieces, row 2 col 0 = the corner boulder cap. Pieces are 64px-wide crops of a
## horizontally-PERIODIC rock strip, indexed by posmod(x+y, 8) -- consecutive
## cells along a wall chain take consecutive crops, so strata/cracks flow
## continuously along the whole wall (the mega-tile principle, applied to walls).

const SHEET_PATH := "res://assets/cliffs/cliffs.png"
const PIECE_W := 64
const PIECE_H := 144
## Px above the diamond top edge reserved in each piece for the lip/tuft zone.
const TOP_PAD := 20
const PIECES := 8
const ROW_SE := 0
const ROW_SW := 1
## Tall (64px, two-tier) faces: used where two tiers stack at the same cells so
## a sheer wall is ONE artwork with continuous strata, not two stacked bands.
const ROW_SE_TALL := 3
const ROW_SW_TALL := 4
const CORNER_RECT := Rect2(0, 2 * PIECE_H, 56, 56)

## Piece index (0..7) for the wall segment at `cell` -- positional, not hashed,
## so the strip stays continuous along a chain (q = x + y advances by 1 per
## consecutive wall cell in both the SE and SW chain directions).
static func piece_index(cell: Vector2i) -> int:
	return posmod(cell.x + cell.y, PIECES)

## Atlas region of the face piece for `cell` on the given side. `tall` selects
## the 64px two-tier artwork.
static func face_region(cell: Vector2i, is_se: bool, tall: bool = false) -> Rect2:
	var row: int
	if tall:
		row = ROW_SE_TALL if is_se else ROW_SW_TALL
	else:
		row = ROW_SE if is_se else ROW_SW
	return Rect2(piece_index(cell) * PIECE_W, row * PIECE_H, PIECE_W, PIECE_H)

## Sprite2D.offset (centered=false) that lands the piece's sheared top edge on
## the cell's raised diamond edge. Canvas x spans world 0..64 for the SE face and
## world -64..0 for the SW face; canvas y=TOP_PAD sits at the top-edge start.
static func face_offset(tier: int, is_se: bool) -> Vector2:
	var lift := float(MapConstants.ELEVATION_STEP_PX * tier)
	return Vector2(0.0 if is_se else -float(PIECE_W), -lift - float(TOP_PAD))
