extends Node2D
## Render-harness proof scene for continuous unit movement across the elevation
## stack (Unit F, #75/#76).
##
## This scene exists to PROVE, visually, TWO contracts at once, against the REAL
## production pieces (never mocks):
##   #75 — a `Unit` PLACES and Y-SORTS correctly on the stacked elevation terrain:
##         its node origin sits at the unlifted footprint and its art is raised
##         onto the tier, so it interleaves with terrain footprint-correctly.
##   #76 — the `Unit` STEERS CONTINUOUSLY along a nav path from tier 0, up a
##         single painted ramp onto a tier-1 platform, and STOPS at the goal.
##
## It instances the production `map_system.tscn` (so the elevation layers, their
## per-tier lift/`y_sort_origin`, and the real `EntityTier*` containers come
## straight from production), strips the interactive/time-varying nodes for a
## clean deterministic render, paints an unambiguous tier-0 apron + tier-1
## platform (+ a small tier-2 block so the full stack reads), defines ONE real
## ramp DERIVED from a painted ramp tile (#78), spawns a real `Unit`, asks the real
## `NavGraph` for the route, and issues it. Once the path is issued the Unit's
## own `_process` steers it every frame — the ORCHESTRATOR controls capture
## timing purely by how many frames it lets the scene run before screenshotting:
##   * a few frames in  -> the unit is mid-climb on the ramp,
##   * many frames in   -> the unit has arrived on the platform and stopped.
##
## Head-ful under Xvfb; run + screenshot with:
##   godot --path . res://src/nodes/unit_nav_harness.tscn
##
## Runtime-only (NOT `@tool`): none of this executes during a headless `--import`
## in CI, which only PARSES it. So (src/nodes/* rule) every var is explicitly
## typed — never `:=` inferred from a Variant — and the `map_system` and `unit`
## instances are kept UNTYPED, duck-typed exactly as unit_debug.gd / map_editor.gd
## do (MapSystem and Unit carry no `class_name`), so warnings-as-errors stays green.

## Dual-grid lookup index of the fully-surrounded ("solid fill") ground coord —
## a plain walkable grass tile (only water is non-walkable), so every painted cell
## navigates.
const GROUND_FILL_INDEX := 15

## Plain dark backdrop so the bright unit and tinted terrain read clearly.
const BACKGROUND_COLOR := Color(0.11, 0.12, 0.15)

## Per-tier terrain tints — a RENDER-ONLY legibility aid (not part of any contract).
## Every tier paints the same grass atlas and the lift is only a half-row, so an
## untinted stack is nearly invisible; distinct hues make the elevation steps — and
## which tier the unit stands on as it climbs — unmistakable in the screenshot.
const TIER_TINT: Array[Color] = [
	Color(0.55, 0.55, 0.60),   ## tier 0 — dim, the ground apron (recedes)
	Color(0.45, 0.72, 1.00),   ## tier 1 — blue, the raised platform (the goal)
	Color(1.00, 0.58, 0.35),   ## tier 2 — orange, a corner block for stack depth
]

## --- Painted geometry (INCLUSIVE cell rectangles [x0..x1] x [y0..y1]) ---------
## Iso orientation (DIAMOND_DOWN): larger (x+y) draws further screen-SOUTH / lower.
## The tier-0 apron is the SOUTH half; the tier-1 platform is the NORTH half and is
## lifted 32 px, so the unit climbs from the low south ground UP to the north shelf.
const APRON_X0 := 0
const APRON_X1 := 9
const APRON_Y0 := 3
const APRON_Y1 := 9

const PLATFORM_X0 := 0
const PLATFORM_X1 := 9
const PLATFORM_Y0 := 0
const PLATFORM_Y1 := 2

## Small tier-2 block on the platform's far (north-west) corner — off the unit's
## path (the path runs the x=4 column) — purely to show the 3-tier stack occluding.
const BLOCK_X0 := 0
const BLOCK_X1 := 2
const BLOCK_Y0 := 0
const BLOCK_Y1 := 1

## --- The ONE ramp + the unit's spawn and goal ---------------------------------
## The ramp's endpoints are EXACTLY two adjacent painted walkable cells, one per
## tier: LOW = (4,3) on tier 0 (the north edge of the apron), HIGH = (4,2) on
## tier 1 (the south edge of the platform). They differ by (0,1) — cartesian
## neighbours — so the ramp lines up with the painted seam between apron and shelf.
const RAMP_LOW_CELL := Vector2i(4, 3)
const RAMP_LOW_TIER := 0
const RAMP_HIGH_CELL := Vector2i(4, 2)
const RAMP_HIGH_TIER := 1

## The unit spawns on the ramp's low cell (tier 0) and is ordered to a cell two
## rows deep onto the tier-1 platform, so the route is:
##   (4,3)t0  --ramp-->  (4,2)t1  ->  (4,1)t1  ->  (4,0)t1   [climb, then stop].
const SPAWN_CELL := Vector2i(4, 3)
const SPAWN_TIER := 0
const GOAL_CELL := Vector2i(4, 0)
const GOAL_TIER := 1

## Fixed camera framing the ramp + climb path. Deterministic — no panning, no
## bounds, no randomness. Centered on the apron-to-platform seam and zoomed so the
## whole painted stack and the unit's route fill a 1920x1080 viewport with margin.
const CAMERA_CENTER := Vector2(96.0, 256.0)
const CAMERA_ZOOM := Vector2(1.2, 1.2)

## Production scene root nodes that are interactive / time-varying (editor, dev
## overlays, day/night tint, RTS camera, the click-to-spawn debug hook) and only
## add noise or steal control of a static proof render; freed from the instance
## at boot. `UnitDebug` MUST go — otherwise its own spawn/pathing would fight ours.
const STRIPPED_NODES: Array[String] = [
	"DayNight", "Sun", "MapEditor", "MapPersistence", "DevMenu", "Camera", "UnitDebug",
]


func _ready() -> void:
	var map_system = _spawn_map_system()
	if map_system == null:
		return
	_strip_runtime_children(map_system)
	_paint_terrain(map_system)
	_add_background()
	_add_camera()

	var unit = _spawn_unit(map_system)
	if unit == null:
		return
	_issue_climb_path(map_system, unit)


## Instances the real MapSystem and adds it as a child (its `_ready` applies the
## per-tier elevation lift + `y_sort_origin` and populates the entity containers we
## depend on). Returned UNTYPED for duck-typed access to its no-`class_name` API,
## or null if the scene is missing.
func _spawn_map_system():
	var scene: PackedScene = load("res://src/nodes/map_system.tscn") as PackedScene
	if scene == null:
		push_error("unit_nav_harness: res://src/nodes/map_system.tscn failed to load.")
		return null
	var map_system = scene.instantiate()
	add_child(map_system)
	return map_system


## Frees the instanced scene's interactive / time-varying nodes so the render is
## clean and deterministic. Deferred (queue_free) — the instance's `_ready` has
## already applied every layer offset and container we depend on, so removing these
## is purely cosmetic / control-hygiene.
func _strip_runtime_children(map_system) -> void:
	for node_name in STRIPPED_NODES:
		var node: Node = map_system.get_node_or_null(node_name)
		if node != null:
			node.queue_free()


## Paints the proof terrain onto the elevation layers with the real terrain TileSet:
##   * Elevation0 (dim grey): a wide tier-0 ground apron across the south rows.
##   * Elevation1 (blue):     a tier-1 platform across the north rows — the goal
##     shelf, reachable from the apron only at the single ramp seam (x=4, y=2/3).
##   * Elevation2 (orange):   a small corner block, off the path, to show the stack.
## The ramp's low (4,3)/high (4,2) cells are painted walkable on their tiers, so
## the cross-tier `find_path` has real ground to stand on at both endpoints.
func _paint_terrain(map_system) -> void:
	var tileset: TileSet = TileSetBuilder.build_default_terrain_tileset()
	if tileset == null:
		push_error("unit_nav_harness: terrain tileset unavailable; cannot paint.")
		return
	var source_id: int = tileset.get_source_id(0)
	var fill: Vector2i = TileSetConstants.LOOKUP[GROUND_FILL_INDEX]

	var elevation0: TileMapLayer = map_system.get_elevation_layer(0)
	var elevation1: TileMapLayer = map_system.get_elevation_layer(1)
	var elevation2: TileMapLayer = map_system.get_elevation_layer(2)
	if elevation0 == null or elevation1 == null or elevation2 == null:
		push_error("unit_nav_harness: MapSystem is missing an elevation layer.")
		return

	# The production scene ships no TileSet resource on the layers, so bind one.
	elevation0.tile_set = tileset
	elevation1.tile_set = tileset
	elevation2.tile_set = tileset

	# Distinct per-tier tint so the elevation steps (and the climb) read.
	elevation0.modulate = TIER_TINT[0]
	elevation1.modulate = TIER_TINT[1]
	elevation2.modulate = TIER_TINT[2]

	_fill_block(elevation0, source_id, fill, APRON_X0, APRON_X1, APRON_Y0, APRON_Y1)
	_fill_block(elevation1, source_id, fill, PLATFORM_X0, PLATFORM_X1, PLATFORM_Y0, PLATFORM_Y1)
	_fill_block(elevation2, source_id, fill, BLOCK_X0, BLOCK_X1, BLOCK_Y0, BLOCK_Y1)

	# Paint the RAMP TILE at the high transition cell (overwriting the platform's
	# plain ground there). NavMapBuilder derives the NavRamp from this painted tile
	# (#78) — its one walkable tier-0 cartesian neighbour is the low apron cell
	# (4,3) — so nothing is hand-fed; the cross-tier link comes from the map itself.
	elevation1.set_cell(RAMP_HIGH_CELL, source_id, TileSetConstants.RAMP_COORDS[0])


## Fills an inclusive cell rectangle [x0..x1] x [y0..y1] of a layer with one tile.
func _fill_block(layer: TileMapLayer, source_id: int, atlas: Vector2i, x0: int, x1: int, y0: int, y1: int) -> void:
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			layer.set_cell(Vector2i(x, y), source_id, atlas)


## Instances the real Unit, adds it in-tree, and spawns it on the ramp's low cell.
## `setup()` reparents it under the tier's real `EntityTier*` container and places
## its origin at the footprint with the sprite raised onto the tier (#75 contract).
## Returned UNTYPED for duck-typed access to its no-`class_name` API (mirrors
## unit_debug.gd), or null if the scene is missing.
func _spawn_unit(map_system):
	var scene: PackedScene = load("res://src/nodes/unit.tscn") as PackedScene
	if scene == null:
		push_error("unit_nav_harness: res://src/nodes/unit.tscn failed to load.")
		return null
	var unit = scene.instantiate()
	# Add under this node first so it is in-tree; setup() then reparents it into the
	# MapSystem's tier entity container.
	add_child(unit)
	unit.setup(map_system, SPAWN_CELL, SPAWN_TIER)
	return unit


## Builds the real NavGraph over the painted stack — with the ramp DERIVED from the
## painted ramp tile (no hand-fed NavRamp, #78) — asks for the cross-tier route from
## the spawn (tier 0) to the goal (tier 1), and issues it to the unit. From here the
## Unit's own `_process` steers along the waypoints every frame (#76) — the
## orchestrator screenshots mid-climb vs arrived by frame count. An empty route means
## the ramp tile / painting don't line up (a real scenario bug) or derivation broke —
## so it is surfaced loudly rather than silently rendering a stationary unit.
func _issue_climb_path(map_system, unit) -> void:
	var nav: NavGraph = NavMapBuilder.from_map_system(map_system)
	if nav == null:
		push_error("unit_nav_harness: NavMapBuilder returned no graph.")
		return
	var waypoints: Array = nav.find_path(SPAWN_CELL, SPAWN_TIER, GOAL_CELL, GOAL_TIER)
	if waypoints.is_empty():
		push_error("unit_nav_harness: find_path returned [] — ramp/painting do not line up (%s t%d -> %s t%d)." % [SPAWN_CELL, SPAWN_TIER, GOAL_CELL, GOAL_TIER])
		return
	unit.issue_path(waypoints)


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


## Fixed camera framing the ramp + climb path. Made current so it wins over any
## camera that might have survived stripping.
func _add_camera() -> void:
	var camera := Camera2D.new()
	camera.position = CAMERA_CENTER
	camera.zoom = CAMERA_ZOOM
	add_child(camera)
	camera.make_current()
