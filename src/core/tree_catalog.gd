class_name TreeCatalog
extends RefCounted
## Single source of truth for the tree sprite sheet layout (#249 trees & doodads v2).
## Mirrors tools/gen_trees.py: VARIANTS variants in one row of CELL_W x CELL_H cells
## (oak x3, pine x3, scrub x3, one dead tree), each with the trunk base at ANCHOR
## and a warm SE cast shadow baked into the art (sun from NW). Trees follow the same
## placement contract as every entity: node origin at the footprint (Y-sort key),
## art offset lifts it onto the tier.

const SHEET_PATH := "res://assets/doodads/trees.png"
const CELL_W := 288
const CELL_H := 232
const VARIANTS := 10
## Trunk-base point inside every cell (px) -- where the tree meets the ground.
const ANCHOR := Vector2(96.0, 190.0)

## Atlas region rect for a variant (wrapped into range).
static func region(variant: int) -> Rect2:
	var v := posmod(variant, VARIANTS)
	return Rect2(v * CELL_W, 0, CELL_W, CELL_H)

## Sprite2D.offset (centered=false) landing the trunk base on the node origin,
## then lifting the art onto `tier` (EntityPlacement contract).
static func art_offset(tier: int) -> Vector2:
	return EntityPlacement.visual_offset(tier) - ANCHOR
