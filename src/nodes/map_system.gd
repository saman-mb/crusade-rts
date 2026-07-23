@tool
extends Node2D
## Root of the stackable isometric map. Holds one TileMapLayer per elevation
## tier plus an Objects layer. Runtime tile painting and the terrain TileSet are
## now driven by the MapEditor node (Story #4); this node owns the layer stack
## and elevation offsets.
## The per-layer elevation offset is DERIVED from MapConstants so that
## ELEVATION_STEP_PX remains the single source of truth (the scene literals
## are just cached defaults; this script re-derives and auto-corrects them,
## in the editor too via @tool, if the constant ever changes).

## Cells of pan headroom left around the painted map so the camera can frame the
## edge tiles and the editor has room to paint outward before the bounds catch up.
const CAMERA_BOUNDS_PAD_CELLS := 3

## Per-tier brighten added to each elevation layer's modulate (Story L4, #85).
## Feeds ElevationShade.shade_at; higher tiers catch more light. 0.0 disables the
## height cue (every tier lit identically, as before L4).
@export_range(0.0, 0.25, 0.005) var elevation_shade_step: float = ElevationShade.DEFAULT_STEP:
	set(v):
		elevation_shade_step = v
		if is_node_ready():
			_apply_elevation_shading()

## Warm sun-ward color of the light added to higher tiers (Story L4, #85). Kept
## consistent with the L3 sun tint so raised ground reads as catching more sun.
@export var elevation_shade_tint: Color = ElevationShade.DEFAULT_TINT:
	set(v):
		elevation_shade_tint = v
		if is_node_ready():
			_apply_elevation_shading()

@onready var elevation_layers: Array[TileMapLayer] = [
	$Elevation0,
	$Elevation1,
	$Elevation2,
]
@onready var objects_layer: TileMapLayer = $Objects
@onready var entity_layers: Array[Node2D] = [$EntityTier0, $EntityTier1, $EntityTier2]

func _ready() -> void:
	_apply_elevation_offsets()
	_apply_elevation_shading()
	# Feed the camera its clamp bounds from the initial content, but only at
	# runtime: the @tool pass must not mutate the instanced camera in the editor.
	if not Engine.is_editor_hint():
		refresh_camera_bounds()

## Positions each elevation layer from MapConstants and sets a matching
## y_sort_origin so the layer sorts at its true (unlifted) world depth.
func _apply_elevation_offsets() -> void:
	for level in elevation_layers.size():
		var layer := elevation_layers[level]
		var pos := MapConstants.elevation_offset(level)
		var origin := MapConstants.ELEVATION_STEP_PX * level
		if layer.position != pos:
			layer.position = pos
		if layer.y_sort_origin != origin:
			layer.y_sort_origin = origin

## Elevation-aware shading (Story L4, #85): tints each tier's layer `modulate`
## brighter the higher it sits, so a terraced map reads with believable height.
## Purely a CanvasItem tint — it does NOT touch position/y_sort_origin, so tier
## sorting (and the no-z-fighting guarantee) is untouched. The modulate
## MULTIPLIES with the DayNight ambient, so tier contrast persists across the
## day/night cycle. Level 0 stays neutral, so flat single-tier maps are unchanged.
func _apply_elevation_shading() -> void:
	for level in elevation_layers.size():
		var layer := elevation_layers[level]
		if layer == null:
			continue
		var tint := ElevationShade.shade_at(level, elevation_shade_step, elevation_shade_tint)
		if layer.modulate != tint:
			layer.modulate = tint

## Returns the TileMapLayer for an elevation tier, or null if out of range.
func get_elevation_layer(level: int) -> TileMapLayer:
	if level < 0 or level >= elevation_layers.size():
		return null
	return elevation_layers[level]

## Returns the per-tier entity container Node2D for `tier`, or null if out of range.
## The containers are plain Y-sorted Node2Ds at the origin (no lift, no
## y_sort_origin — a Node2D has none). Entities (units, elevated props) parent
## here and set `position = EntityPlacement.ground_position(cell)` (the unlifted
## footprint), so they sort at the same depth as that tier's floor tile; the tier
## lift is applied as a VISUAL offset on the entity's art
## (EntityPlacement.visual_offset(tier)), never to the node origin. The per-tier
## split is organizational (know a unit's tier by its parent; reparent on a ramp),
## not a sorting mechanism — every tier container shares the one Y-sort space of
## the map root. See docs/ENTITY_SORTING.md. (#107)
func entity_parent_for_tier(tier: int) -> Node2D:
	if tier < 0 or tier >= entity_layers.size():
		return null
	return entity_layers[tier]

## Cell-space union of every layer's used region (elevation stack + objects).
## All layers share one cell grid, so their rects merge directly. Empty layers
## are skipped so a blank layer does not drag the union to include cell (0,0);
## returns a zero-size rect when nothing is painted anywhere.
func used_cell_rect() -> Rect2i:
	var rect := Rect2i()
	var seeded := false
	for layer in elevation_layers:
		if layer == null:
			continue
		var r := layer.get_used_rect()
		if r.size.x <= 0 or r.size.y <= 0:
			continue
		rect = r if not seeded else rect.merge(r)
		seeded = true
	if objects_layer != null:
		var ro := objects_layer.get_used_rect()
		if ro.size.x > 0 and ro.size.y > 0:
			rect = ro if not seeded else rect.merge(ro)
	return rect

## Recomputes the sibling RtsCamera's clamp bounds from the current painted
## extent (#17). Call after loading/painting changes the map. Safe no-op if the
## camera is absent; a blank map yields empty bounds => the camera stays unbounded.
func refresh_camera_bounds() -> void:
	var camera := get_node_or_null(^"Camera") as RtsCamera
	if camera == null:
		return
	camera.world_bounds = CameraMath.world_bounds_for_cells(
		used_cell_rect(), MapConstants.TILE_SIZE, CAMERA_BOUNDS_PAD_CELLS)
