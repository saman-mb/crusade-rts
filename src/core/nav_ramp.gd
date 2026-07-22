class_name NavRamp
extends RefCounted
## One ramp/transition linking a low tier cell to a high tier cell -- the ONLY
## kind of cross-tier connection in the nav mesh (cliffs are hard walls). Pure
## descriptor: it carries the two endpoints, their tiers, and a climb `weight`.
## Endpoint ids and world positions are PURE iso math (no live TileMapLayer):
## positions come from IsoCoord + MapConstants, the single source of truth.

var low_cell: Vector2i   ## Cartesian cell of the low (bottom-of-ramp) endpoint.
var low_tier: int        ## Elevation tier the low endpoint sits on.
var high_cell: Vector2i  ## Cartesian cell of the high (top-of-ramp) endpoint.
var high_tier: int       ## Elevation tier the high endpoint sits on.
var weight: float        ## Climb cost multiplier applied to the high endpoint.

## Stores the two endpoints, their tiers, and the climb `weight` (default 1.0).
func _init(p_low_cell: Vector2i, p_low_tier: int, p_high_cell: Vector2i, p_high_tier: int, p_weight: float = 1.0) -> void:
	low_cell = p_low_cell
	low_tier = p_low_tier
	high_cell = p_high_cell
	high_tier = p_high_tier
	weight = p_weight

## Deterministic AStar2D point id for a (cell, tier) endpoint within `region`.
## Layout: tier-major, then row-major within the region -- collision-free for
## any distinct (cell, tier) inside `region` (cell offsets stay in [0, size)).
static func endpoint_id(cell: Vector2i, tier: int, region: Rect2i) -> int:
	var area: int = region.size.x * region.size.y
	var col: int = cell.x - region.position.x
	var row: int = cell.y - region.position.y
	return tier * area + row * region.size.x + col

## Pure-iso world position of a (cell, tier) endpoint: the flat diamond center
## (IsoCoord.cart_to_iso) lifted by the tier's elevation offset (MapConstants).
static func endpoint_world_pos(cell: Vector2i, tier: int) -> Vector2:
	return IsoCoord.cart_to_iso(cell) + MapConstants.elevation_offset(tier)
