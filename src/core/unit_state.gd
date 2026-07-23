class_name UnitState
extends RefCounted
## A single unit's placement: its discrete grid slot AND its continuous world
## position, held together on one object (#75). Pure / headless -- no Node deps.
## All geometry is composed from EntityPlacement (the depth-sorting contract,
## src/core/entity_placement.gd) and, through it, MapConstants; this core never
## re-derives a tile size, an elevation step, or an iso transform inline.
##
## Two coordinate facts to keep straight, both inherited from EntityPlacement:
##
## - `cell` / `tier` are the DISCRETE slot: which iso cell the unit occupies and
##   which elevation tier it stands on. These drive nav, tie-breaks, and which
##   `EntityTier{n}` container the Unit node parents to.
##
## - `world_pos` is the CONTINUOUS position in LIFTED / VISUAL space -- the exact
##   space `EntityPlacement.visual_position(cell, tier)` returns (footprint center
##   RAISED by the tier's `visual_offset`). It is where the unit's art anchor
##   lands on screen. Steering / path-following moves the unit HERE: `world_pos`
##   is public and is mutated directly by the Unit node each frame from its
##   PathFollower, so between cell snaps it holds a smooth off-center point that is
##   NOT any exact cell center. Construction and `place_at` snap it back onto the
##   `visual_position` of the current `{cell, tier}`.
##
## The subtlety this class exists to get right: the Unit NODE must NOT be placed
## at `world_pos`. Under the sorting contract the node ORIGIN sorts by its Y, and
## `world_pos` carries the elevation lift -- parking the origin there would rebake
## that lift into the sort key and pop the unit behind the cliff it stands on (see
## docs/ENTITY_SORTING.md). So the placement splits into two transforms:
##
## - `ground_position()` = `world_pos - visual_offset(tier)` -- the node ORIGIN /
##   sort anchor. Subtracting the tier's lift lands the origin back on the
##   UNLIFTED footprint depth, so the unit sorts exactly like that tier's floor
##   tile, footprint-correct on every tier. For a freshly snapped unit this equals
##   `EntityPlacement.ground_position(cell)` and is tier-INDEPENDENT; while
##   steering off-center it tracks `world_pos` minus the same fixed lift.
##
## - `art_offset()` = `visual_offset(tier)` -- the offset applied to the unit's
##   SPRITE child, which RAISES the drawn body onto the tier without moving the
##   origin. origin sorts, art draws.
##
## Composed so `ground_position() + art_offset() == world_pos` always: the Unit
## node sets its `position` from `ground_position()` and its sprite `offset` from
## `art_offset()`, and the drawn art lands back exactly at `world_pos`.

var cell: Vector2i       ## Discrete iso cell the unit occupies (Cartesian grid).
var tier: int            ## Elevation tier the unit stands on.
var world_pos: Vector2   ## Continuous position in LIFTED / visual space -- the
                         ## space of EntityPlacement.visual_position. PUBLIC: the
                         ## Unit node mutates this each frame from PathFollower.

## Snaps into `{p_cell, p_tier}` with `world_pos` on that slot's `visual_position`
## -- i.e. the unit starts dead-centered on its cell, lifted onto its tier.
func _init(p_cell: Vector2i, p_tier: int) -> void:
	place_at(p_cell, p_tier)

## Re-snap discrete slot AND `world_pos` together (spawn / teleport / ramp step):
## sets `cell`, `tier`, and re-centers `world_pos` onto the new slot's lifted
## `visual_position`, discarding any off-center steering offset.
func place_at(p_cell: Vector2i, p_tier: int) -> void:
	cell = p_cell
	tier = p_tier
	world_pos = EntityPlacement.visual_position(p_cell, p_tier)

## The Unit NODE's origin / sort anchor: `world_pos` with the tier's lift removed,
## dropping it onto the unlifted footprint so the unit sorts by footprint depth
## (identical to that tier's floor tile) instead of by its raised art. Equals
## EntityPlacement.ground_position(cell) when freshly snapped; tracks the live
## `world_pos` minus the fixed lift while steering off-center.
func ground_position() -> Vector2:
	return world_pos - EntityPlacement.visual_offset(tier)

## The offset applied to the unit's SPRITE child: the tier's visual raise, which
## lifts the drawn body onto the tier WITHOUT moving the sorting origin. Added back
## to `ground_position()` it reproduces `world_pos` exactly. Tier 0 is zero.
func art_offset() -> Vector2:
	return EntityPlacement.visual_offset(tier)
