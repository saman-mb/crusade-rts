class_name VariationPicker
extends RefCounted
## Deterministic per-cell tile-variant chooser (#232). Given a cell and a variant
## count, returns a stable index in [0, count) from an integer hash of (x, y) --
## no RNG, so the choice is identical every run and survives save/load unchanged
## (the chosen alternative_tile round-trips on disk like any other cell). This is
## what stops a field of the SAME atlas tile from reading as one stamp repeated on
## a visible grid: adjacent cells hash to different variants (flip/tint) instead.
##
## PURE integer-space logic -- no Node, no engine state, no isometric projection.
## The variant LOOK (flip_h/flip_v/modulate per index) lives on the TileSet
## alternatives built by TileSetBuilder; this module only decides WHICH index a
## cell gets. TerrainVariation is the runtime pass that applies it to a layer.

## Variant index for `cell` in [0, count). count <= 1 always maps to 0 (the base
## tile), so a non-varyable tile is a safe no-op.
static func pick(cell: Vector2i, count: int) -> int:
	if count <= 1:
		return 0
	return _hash2(cell.x, cell.y) % count

## A well-mixed non-negative 31-bit hash of two (possibly negative) ints. Masking
## to 31 bits right after the first combine keeps every later shift logical (not
## sign-extending), so the avalanche mixing stays well-distributed for negative
## cells too. Distribution across small bucket counts is exercised by the tests.
static func _hash2(x: int, y: int) -> int:
	var h := (x * 73856093) ^ (y * 19349663)
	h = h & 0x7fffffff
	h = (h * 2654435761) & 0x7fffffff
	h = (h ^ (h >> 13)) & 0x7fffffff
	h = (h * 40503) & 0x7fffffff
	return h ^ (h >> 15)
