@tool
class_name MapSystem
extends Node2D
## Root of the stackable isometric map. Holds one TileMapLayer per elevation
## tier plus an Objects layer. Runtime tile painting and the terrain TileSet are
## now driven by the MapEditor node (Story #4); this node owns the layer stack
## and elevation offsets.
## The per-layer elevation offset is DERIVED from MapConstants so that
## ELEVATION_STEP_PX remains the single source of truth (the scene literals
## are just cached defaults; this script re-derives and auto-corrects them,
## in the editor too via @tool, if the constant ever changes).

## Fired whenever the painted map mutates (paint/erase/bucket/undo/redo/load/tileset
## swap). MapSystem is the single HUB (#95): mutating paths emit through this node,
## and consumers (the camera clamp, and -- via the seam below -- a future live nav
## graph) subscribe here instead of being poked by name. `rect` is the affected
## cells' bounding Rect2i (or the whole painted union for broad changes); `tiers`
## lists the affected elevation tiers.
signal map_changed(rect: Rect2i, tiers: Array[int])

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

## Elevation tier layers, built procedurally in `_ready` from MapConstants.TIER_COUNT
## (#106) rather than hand-authored in the scene, so the tier count has one source
## of truth. Indexed by elevation level (0 == ground).
var elevation_layers: Array[TileMapLayer] = []
## Objects overlay layer (non-terrain props). Built procedurally in `_ready` (#106).
var objects_layer: TileMapLayer
## Per-tier entity container Node2Ds, built procedurally in `_ready` from
## MapConstants.TIER_COUNT (#106). Index-aligned with `elevation_layers`.
var entity_layers: Array[Node2D] = []

## Index of the first procedurally-built tier node (Elevation0) among the map
## root's children. The environment nodes authored in map_system.tscn -- DayNight
## (0) and Sun (1) -- precede it, so the tier stack begins at 2, exactly where the
## scene used to hand-author it. Preserving this order keeps the y-sort tie-break
## identical (e.g. the editor's Preview ghost, a later child, still draws on top).
const _TIER_BASE_INDEX := 2

func _ready() -> void:
	_build_tiers()
	_apply_elevation_offsets()
	_apply_elevation_shading()
	# Feed the camera its clamp bounds from the initial content, but only at
	# runtime: the @tool pass must not mutate the instanced camera in the editor.
	if not Engine.is_editor_hint():
		# The camera clamp is now a SUBSCRIBER of map_changed (#95): every mutating
		# path emits the signal and this is the single place the bounds refresh from.
		# No caller pokes refresh_camera_bounds() by name anymore.
		map_changed.connect(_on_map_changed)
		refresh_camera_bounds()  # seed bounds from the initial painted content

## Subscriber for `map_changed` (#95): re-derives the camera clamp from the new
## painted extent. The camera always reframes the whole map, so `rect`/`tiers` are
## unused here; they exist for finer-grained consumers (see the nav seam below).
func _on_map_changed(_rect: Rect2i, _tiers: Array[int]) -> void:
	refresh_camera_bounds()
	# NAV SEAM (#95): a live nav consumer would connect to map_changed and call
	# `nav_graph.rebuild_tier(t)` for each t in `tiers`, scoped to `rect`. There is
	# no persistent production NavGraph yet (unit_debug rebuilds per move via
	# NavMapBuilder.from_map_system), so nothing subscribes for nav today -- this
	# documents exactly where that subscription plugs in.

## Announces a whole-map change across every tier (#95): rect = the current painted
## union, tiers = [0, tier_count). The broad mutating paths (map load, tileset swap,
## undo/redo) call this instead of each rebuilding the tier list, keeping MapSystem
## the single source of the map_changed payload shape.
func emit_map_changed_all() -> void:
	var tiers: Array[int] = []
	for i in tier_count():
		tiers.append(i)
	map_changed.emit(used_cell_rect(), tiers)

## Builds the elevation TileMapLayer stack, the Objects overlay, and the per-tier
## EntityTier container Node2Ds procedurally from MapConstants.TIER_COUNT (#106),
## reproducing exactly what map_system.tscn used to hand-author: each Elevation
## layer and EntityTier container is Y-sorted; per-tier position + y_sort_origin
## are set afterwards by `_apply_elevation_offsets`. Nodes are inserted starting at
## `_TIER_BASE_INDEX` (after DayNight + Sun, before the interactive/overlay
## children) so tree order -- and thus the y-sort tie-break -- matches the old
## scene. Idempotent: reuses any node already present, so the @tool editor
## re-running `_ready` on a script reload never double-creates the stack.
func _build_tiers() -> void:
	elevation_layers.clear()
	entity_layers.clear()
	var index := _TIER_BASE_INDEX
	for level in MapConstants.TIER_COUNT:
		var layer_name := "Elevation%d" % level
		var layer := get_node_or_null(NodePath(layer_name)) as TileMapLayer
		if layer == null:
			layer = TileMapLayer.new()
			layer.name = layer_name
			layer.y_sort_enabled = true
			add_child(layer)
			move_child(layer, index)
		elevation_layers.append(layer)
		index += 1
	var obj := get_node_or_null(^"Objects") as TileMapLayer
	if obj == null:
		obj = TileMapLayer.new()
		obj.name = "Objects"
		obj.y_sort_enabled = true
		add_child(obj)
		move_child(obj, index)
	objects_layer = obj
	index += 1
	for tier in MapConstants.TIER_COUNT:
		var container_name := "EntityTier%d" % tier
		var container := get_node_or_null(NodePath(container_name)) as Node2D
		if container == null:
			container = Node2D.new()
			container.name = container_name
			container.y_sort_enabled = true
			add_child(container)
			move_child(container, index)
		entity_layers.append(container)
		index += 1

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

## Number of elevation tiers in the layer stack -- the single source of truth for
## layer discovery (#105). Callers derive their tier loops from this instead of
## probing get_elevation_layer(i) until null.
func tier_count() -> int:
	return elevation_layers.size()

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
