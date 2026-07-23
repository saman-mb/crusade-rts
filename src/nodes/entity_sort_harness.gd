extends Node2D
## Render-harness proof scene for the entity depth-sorting contract (Unit D, #107).
##
## This scene exists to PROVE, visually, that marker "entities" placed on elevated
## tiers interleave correctly with a stepped-cliff terrain: an entity is occluded
## by higher terrain that sits in front of it (screen-south / +y), yet draws over
## lower terrain in front of it. It exercises the REAL contract, not a mock: it
## instances the production `map_system.tscn`, so the elevation layers, the
## per-tier `EntityTier*` containers come straight from the production scene.
## Markers are placed through the exact `EntityPlacement.ground_position(cell)` +
## `visual_offset(tier)` API a real unit would use.
##
## Runtime-only (NOT `@tool`): it strips the instanced scene's interactive nodes
## (editor, dev overlay, day/night tint, RTS camera) so the render is clean and
## deterministic, paints a small stepped cliff, drops three high-contrast marker
## bars, and frames everything with its own fixed Camera2D. Run head-ful under
## Xvfb; the orchestrator screenshots it:
##   godot --path . res://src/nodes/entity_sort_harness.tscn
##
## Being CI-parse-only (src/nodes/*), every var is explicitly typed and the
## MapSystem instance is kept UNTYPED (MapSystem carries no class_name, so its API
## is duck-typed exactly as map_persistence.gd / dev_menu.gd do), never inferred
## from a Variant -- which would trip warnings-as-errors on import.

## Dual-grid lookup index of the fully-surrounded ("solid fill") ground coord.
const GROUND_FILL_INDEX := 15

## Marker bar geometry, in container-local pixels relative to the footprint. The
## bar extends UP from the footprint (the body) and a little BELOW it, so higher
## terrain immediately to the south can visibly clip the lower edge (the whole
## point of the P1 case).
const MARKER_HALF_WIDTH := 15.0
const MARKER_RISE := 50.0     ## pixels the bar rises above the footprint
const MARKER_DROP := 14.0     ## pixels the bar drops below the footprint

## High-contrast, saturated marker colors -- one per case so they read apart in
## the screenshot.
const COLOR_P1 := Color(1.0, 0.0, 0.85)   ## magenta -- occluded case
const COLOR_P2 := Color(0.0, 0.95, 1.0)   ## cyan    -- draws-over case
const COLOR_P3 := Color(1.0, 0.86, 0.0)   ## amber   -- tier-0 base case

## Plain dark backdrop so the bright markers and terrain read clearly.
const BACKGROUND_COLOR := Color(0.11, 0.12, 0.15)

## Per-tier terrain tints — a RENDER-ONLY legibility aid (not part of the contract).
## Because every tier uses the same grass atlas and the lift is only a half-row,
## an untinted stepped cliff is nearly invisible; tinting each tier a distinct hue
## makes the raised blocks — and whether a marker is occluded by one — unmistakable.
const TIER_TINT: Array[Color] = [
	Color(0.55, 0.55, 0.60),   ## tier 0 — dim, recedes
	Color(0.45, 0.72, 1.00),   ## tier 1 — blue
	Color(1.00, 0.58, 0.35),   ## tier 2 — orange (the P1 occluder)
]

## Fixed camera framing of the whole cliff (center of the painted content, zoomed
## so the scene fills a 1920x1080 viewport with margin). Deterministic -- no
## panning, no bounds, no randomness.
const CAMERA_CENTER := Vector2(0.0, 224.0)
const CAMERA_ZOOM := Vector2(1.5, 1.5)

## Production scene root nodes that are interactive / time-varying and only add
## noise to a static proof render; removed from the instance at boot.
const STRIPPED_NODES: Array[String] = [
	"DayNight", "Sun", "MapEditor", "MapPersistence", "DevMenu", "Camera",
]


func _ready() -> void:
	var map_system = _spawn_map_system()
	if map_system == null:
		return
	_strip_runtime_children(map_system)
	_paint_stepped_cliff(map_system)
	_place_markers(map_system)
	_add_background()
	_add_camera()


## Instances the real MapSystem and adds it as a child (its `_ready` applies the
## elevation + entity-container offsets we are here to test). Returns the instance
## UNTYPED for duck-typed access to its no-class_name API, or null if the scene is
## missing.
func _spawn_map_system():
	var scene: PackedScene = load("res://src/nodes/map_system.tscn") as PackedScene
	if scene == null:
		push_error("entity_sort_harness: res://src/nodes/map_system.tscn failed to load.")
		return null
	var map_system = scene.instantiate()
	add_child(map_system)
	return map_system


## Frees the instanced scene's interactive / time-varying nodes so the render is
## clean and deterministic. Deferred (queue_free) -- the instance's `_ready` has
## already applied every offset we depend on, so removing these is purely cosmetic.
func _strip_runtime_children(map_system) -> void:
	for node_name in STRIPPED_NODES:
		var node: Node = map_system.get_node_or_null(node_name)
		if node != null:
			node.queue_free()


## Paints the proof terrain onto the three elevation layers using the real terrain
## TileSet. Iso orientation: screen-"south" (downward, drawn later) is increasing
## x+y. The layout is deliberately unambiguous:
##   * Elevation0 (green): a wide ground apron under everything.
##   * Elevation2 (orange): a tall tier-2 WALL band spanning the map east-west at
##     rows y=3..4 -- the single occluder both markers are judged against.
##   * Elevation1 (blue): a small ledge on top of the wall for the "unit standing
##     on the raised wall" case.
## A marker NORTH of the wall must be sliced by it (wall sorts deeper, draws over);
## a marker SOUTH of the wall must draw fully over it.
func _paint_stepped_cliff(map_system) -> void:
	var tileset: TileSet = TileSetBuilder.build_default_terrain_tileset()
	if tileset == null:
		push_error("entity_sort_harness: terrain tileset unavailable; markers only.")
		return
	var source_id: int = tileset.get_source_id(0)
	var fill: Vector2i = TileSetConstants.LOOKUP[GROUND_FILL_INDEX]

	var elevation0: TileMapLayer = map_system.get_elevation_layer(0)
	var elevation1: TileMapLayer = map_system.get_elevation_layer(1)
	var elevation2: TileMapLayer = map_system.get_elevation_layer(2)
	if elevation0 == null or elevation1 == null or elevation2 == null:
		push_error("entity_sort_harness: MapSystem is missing an elevation layer.")
		return

	# The production scene ships no TileSet resource on the layers, so bind one.
	elevation0.tile_set = tileset
	elevation1.tile_set = tileset
	elevation2.tile_set = tileset

	# Distinct per-tier tint so the elevation steps (and marker occlusion) read.
	elevation0.modulate = TIER_TINT[0]
	elevation1.modulate = TIER_TINT[1]
	elevation2.modulate = TIER_TINT[2]

	# Tier 0: ground apron beneath the whole footprint.
	_fill_block(elevation0, source_id, fill, 0, 7, 0, 7)
	# Tier 2: a tall orange wall band across the middle rows -- the one occluder.
	_fill_block(elevation2, source_id, fill, 0, 7, 3, 4)
	# Tier 1: a small blue ledge on the wall's east end, for the "stand on it" case.
	_fill_block(elevation1, source_id, fill, 6, 7, 3, 4)


## Fills an inclusive cell rectangle [x0..x1] x [y0..y1] of a layer with one tile.
func _fill_block(layer: TileMapLayer, source_id: int, atlas: Vector2i, x0: int, x1: int, y0: int, y1: int) -> void:
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			layer.set_cell(Vector2i(x, y), source_id, atlas)


## Drops the three proof markers through the real placement contract, all judged
## against the single tier-2 orange wall at rows y=3..4:
##   P1 (magenta): tier-0, NORTH of the wall (row 2) -> MUST be sliced/occluded.
##   P2 (cyan):    tier-0, SOUTH of the wall (row 5) -> MUST draw fully over.
##   P3 (amber):   tier-2, standing ON the wall's blue ledge -> stands correctly.
func _place_markers(map_system) -> void:
	_spawn_marker(map_system, 0, Vector2i(2, 2), COLOR_P1, "P1 tier0 N of wall")
	_spawn_marker(map_system, 0, Vector2i(2, 5), COLOR_P2, "P2 tier0 S of wall")
	_spawn_marker(map_system, 2, Vector2i(6, 3), COLOR_P3, "P3 on tier2 wall")


## Builds one marker bar and parents it to its tier's real entity container. The
## bar's NODE ORIGIN is the unlifted footprint `EntityPlacement.ground_position(cell)`
## -- so it sorts at the same depth as that tier's floor tile -- while the drawn
## body is raised by `EntityPlacement.visual_offset(tier)` so it stands on the
## tier. This is the exact contract a real unit uses: origin = footprint (sort
## anchor), art = raised. The lift stays out of the sort key, so occlusion is
## footprint-correct.
func _spawn_marker(map_system, tier: int, cell: Vector2i, color: Color, label_text: String) -> void:
	var parent: Node2D = map_system.entity_parent_for_tier(tier)
	if parent == null:
		push_error("entity_sort_harness: no entity container for tier %d." % tier)
		return

	var lift: float = EntityPlacement.visual_offset(tier).y

	var bar := Polygon2D.new()
	bar.color = color
	bar.polygon = _marker_shape(lift)
	bar.position = EntityPlacement.ground_position(cell)
	parent.add_child(bar)

	# Caption above the bar (outside any occluder) to identify the case at a glance.
	var caption := Label.new()
	caption.text = label_text
	caption.position = Vector2(-MARKER_HALF_WIDTH, lift - (MARKER_RISE + 26.0))
	caption.add_theme_color_override("font_color", Color.WHITE)
	caption.add_theme_color_override("font_outline_color", Color.BLACK)
	caption.add_theme_constant_override("outline_size", 6)
	caption.add_theme_font_size_override("font_size", 15)
	bar.add_child(caption)


## The marker bar outline: a tall vertical rectangle whose base sits at the tier
## surface (`lift`, the visual raise for the tier, negative/up), rising
## `MARKER_RISE` above it and dropping `MARKER_DROP` below it. The node origin
## stays at the unlifted footprint (`lift == 0` would draw at the footprint), so
## the raise is purely visual and never enters the sort key.
func _marker_shape(lift: float) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(-MARKER_HALF_WIDTH, lift - MARKER_RISE),
		Vector2(MARKER_HALF_WIDTH, lift - MARKER_RISE),
		Vector2(MARKER_HALF_WIDTH, lift + MARKER_DROP),
		Vector2(-MARKER_HALF_WIDTH, lift + MARKER_DROP),
	])


## Full-screen dark backdrop on a below-world CanvasLayer, so the render is legible
## regardless of camera framing.
func _add_background() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = -1
	add_child(canvas)
	var rect := ColorRect.new()
	rect.color = BACKGROUND_COLOR
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(rect)


## Fixed camera framing the whole cliff. Made current so it wins over any camera
## that might have survived stripping.
func _add_camera() -> void:
	var camera := Camera2D.new()
	camera.position = CAMERA_CENTER
	camera.zoom = CAMERA_ZOOM
	add_child(camera)
	camera.make_current()
