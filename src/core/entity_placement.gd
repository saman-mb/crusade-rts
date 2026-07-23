class_name EntityPlacement
extends RefCounted
## The entity depth-sorting contract on elevated terrain (#107).
##
## An isometric map is built from one Y-sorted TileMapLayer per elevation tier,
## each raised on screen by MapConstants.elevation_offset(tier). A unit standing
## on tier t must (a) appear lifted by that same amount so it stands ON the
## raised ground, yet (b) sort against every other entity and tile by its
## UNLIFTED footprint depth, so a unit on a hill still occludes / is occluded
## correctly relative to units and terrain on the ground below it.
##
## How the terrain layers pull this off: a TileMapLayer draws its tiles lifted
## (position.y = -32*tier) but adds a compensating `y_sort_origin = +32*tier`,
## so each tile SORTS at its unlifted footprint depth (`-32t + 32t == 0`). That
## `y_sort_origin` knob is what makes the raised layer interleave correctly.
##
## Entities cannot copy that trick directly: `y_sort_origin` exists ONLY on
## TileMapLayer (and CanvasItem-derived tiles); a plain Node2D unit has no such
## property (verified: `"y_sort_origin" in Node2D.new()` is false). Under a
## Y-sorted parent a Node2D is sorted purely by the global Y of its ORIGIN.
##
## So the contract inverts the terrain trick: put the entity's ORIGIN at the
## unlifted footprint (`ground_position`), which sorts it at exactly the same
## depth as that tier's floor tile, and express the elevation as a VISUAL raise
## of the art alone (`visual_offset` applied to the sprite/child), which never
## moves the origin and so never perturbs the sort key. Elevation becomes a pure
## draw offset; depth-sorting stays footprint-correct on every tier.
##
## Pure / headless: no Node deps. All geometry is composed from IsoCoord (iso
## math) and MapConstants (the single source of truth for tile size + vertical
## steps); this core never re-derives a tile size or an elevation offset inline.

## The entity NODE's position: the unlifted diamond-center of `cell`. Because a
## Node2D sorts by its origin's Y, placing the node here sorts the entity at its
## footprint depth — identical to the tier's floor tile at the same cell,
## regardless of tier. This value is deliberately tier-INDEPENDENT: elevation is
## never baked into the sort anchor. Equals IsoCoord.cart_to_iso(cell).
static func ground_position(cell: Vector2i) -> Vector2:
	return IsoCoord.cart_to_iso(cell)

## The VISUAL raise applied to the entity's art (its Sprite2D/child `position` or
## `offset`), lifting the drawn body onto tier `tier` WITHOUT moving the node
## origin — so the sprite stands on the raised ground while the entity still
## sorts by its footprint. Sourced from MapConstants so it always matches the map
## scene's per-layer transform (== Vector2(0, -32 * tier)). Tier 0 is zero.
static func visual_offset(tier: int) -> Vector2:
	return MapConstants.elevation_offset(tier)

## Convenience: where the entity's art anchor lands on screen — the footprint
## position plus the elevation raise (`ground_position(cell) + visual_offset`).
## Use this when a caller applies the whole placement to a single node's draw
## (e.g. a self-offsetting sprite); the depth sort must still key off
## `ground_position`, not this, or the lift re-enters the sort order.
static func visual_position(cell: Vector2i, tier: int) -> Vector2:
	return ground_position(cell) + visual_offset(tier)
