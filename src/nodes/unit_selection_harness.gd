extends Node2D
## Render-harness proof scene for SELECTION + MOVE (Unit selection, #77 WU-D).
##
## This scene exists to PROVE, visually, TWO contracts at once against the REAL
## production pieces (never mocks):
##   (a) SELECTION — `set_selected(true)` shows the footprint selection ring on a
##       unit, and `set_selected(false)` leaves another unit ring-less: the render
##       must show the ring on EXACTLY ONE of the two spawned units.
##   (b) MOVE — a selected unit, handed a real `NavGraph.find_path` route via
##       `issue_path`, STEERS along it over frames (its own `_process` drives it),
##       while the UNSELECTED unit stays put: a right-click-equivalent move order.
##
## It instances the production `map_system.tscn` (so the elevation layers and the
## real `EntityTier*` containers come straight from production), strips the
## interactive / time-varying nodes for a clean deterministic render (UnitDebug
## MUST go — its own click-to-spawn/path hook would fight ours), paints ONE flat
## tinted tier-0 apron, spawns TWO real `Unit`s on a single tier, selects one,
## and issues that one a move. Once the path is issued the selected Unit's own
## `_process` steers it every frame — the ORCHESTRATOR controls capture timing
## purely by how many frames it lets the scene run before screenshotting:
##   * frame 0     -> both units in place, ring on the SELECTED (2,2) unit only,
##   * many frames -> the selected unit has moved toward (2,7); the other unchanged.
##
## Head-ful under Xvfb; run + screenshot with:
##   godot --path . res://src/nodes/unit_selection_harness.tscn
##
## Runtime-only (NOT `@tool`): none of this executes during a headless `--import`
## in CI, which only PARSES it. So (src/nodes/* rule) every var is explicitly
## typed — never `:=` inferred from a Variant — and the `map_system` and `unit`
## instances are kept UNTYPED, duck-typed exactly as unit_nav_harness.gd /
## unit_debug.gd do (MapSystem and Unit carry no `class_name`), so
## warnings-as-errors stays green.

## Dual-grid lookup index of the fully-surrounded ("solid fill") ground coord — a
## plain walkable grass tile (only water is non-walkable), so every painted cell
## navigates.
const GROUND_FILL_INDEX := 15

## Plain dark backdrop so the bright units and tinted terrain read clearly.
const BACKGROUND_COLOR := Color(0.11, 0.12, 0.15)

## Flat tier-0 ground tint — a RENDER-ONLY legibility aid (not part of any
## contract). Mirrors unit_nav_harness's tier-0 dim grey so the apron reads as
## ground under the bright units and their rings.
const GROUND_TINT := Color(0.55, 0.55, 0.60)

## --- Painted geometry (INCLUSIVE cell rectangle [x0..x1] x [y0..y1]) -----------
## One flat tier-0 apron wide enough to hold both units and the full move path.
const APRON_X0 := 0
const APRON_X1 := 9
const APRON_Y0 := 0
const APRON_Y1 := 9

## --- Spawn cells + the ONE move order ------------------------------------------
## Two clearly-separated units on tier 0:
##   * SELECTED unit spawns at (2,2)  [world (64,160)]  -> gets the ring + the move.
##   * UNSELECTED unit spawns at (6,2) [world (320,288)] -> no ring, never moves.
## The selected unit is ordered to (2,7) [world (-256,320)], a straight walk down
## the x=2 column (all painted, all walkable), so over frames it visibly departs
## its spawn while the other stays fixed.
const SELECTED_SPAWN_CELL := Vector2i(2, 2)
const UNSELECTED_SPAWN_CELL := Vector2i(6, 2)
const SPAWN_TIER := 0
const MOVE_GOAL_CELL := Vector2i(2, 7)
const MOVE_GOAL_TIER := 0

## Fixed camera framing both spawns + the move path. Deterministic — no panning,
## no bounds, no randomness. Centered on the midpoint of the spawns and the goal
## (world x in [-256..320], y in [160..320]) and zoomed so the whole scenario fills
## a 1920x1080 viewport with generous margin.
const CAMERA_CENTER := Vector2(32.0, 240.0)
const CAMERA_ZOOM := Vector2(1.2, 1.2)

## Production scene root nodes that are interactive / time-varying (editor, dev
## overlays, day/night tint, RTS camera, the click-to-spawn debug hook) and only
## add noise or steal control of a static proof render; freed from the instance at
## boot. `UnitDebug` MUST go — otherwise its own spawn/pathing would fight ours.
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

	# Spawn BOTH units on tier 0, then select exactly one.
	var selected_unit = _spawn_unit(map_system, SELECTED_SPAWN_CELL)
	var unselected_unit = _spawn_unit(map_system, UNSELECTED_SPAWN_CELL)
	if selected_unit == null or unselected_unit == null:
		return
	selected_unit.set_selected(true)
	unselected_unit.set_selected(false)

	# Issue the move to the SELECTED unit only.
	_issue_move(map_system, selected_unit)


## Instances the real MapSystem and adds it as a child (its `_ready` applies the
## per-tier elevation lift + `y_sort_origin` and populates the entity containers we
## depend on). Returned UNTYPED for duck-typed access to its no-`class_name` API,
## or null if the scene is missing.
func _spawn_map_system():
	var scene: PackedScene = load("res://src/nodes/map_system.tscn") as PackedScene
	if scene == null:
		push_error("unit_selection_harness: res://src/nodes/map_system.tscn failed to load.")
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


## Paints the flat tier-0 apron onto Elevation0 with the real terrain TileSet, so
## both units and the whole move path stand on real walkable ground.
func _paint_terrain(map_system) -> void:
	var tileset: TileSet = TileSetBuilder.build_default_terrain_tileset()
	if tileset == null:
		push_error("unit_selection_harness: terrain tileset unavailable; cannot paint.")
		return
	var source_id: int = tileset.get_source_id(0)
	var fill: Vector2i = TileSetConstants.LOOKUP[GROUND_FILL_INDEX]

	var elevation0: TileMapLayer = map_system.get_elevation_layer(0)
	if elevation0 == null:
		push_error("unit_selection_harness: MapSystem is missing elevation layer 0.")
		return

	# The production scene ships no TileSet resource on the layer, so bind one.
	elevation0.tile_set = tileset
	# Dim grey tint so the bright units and their rings read against the ground.
	elevation0.modulate = GROUND_TINT

	_fill_block(elevation0, source_id, fill, APRON_X0, APRON_X1, APRON_Y0, APRON_Y1)


## Fills an inclusive cell rectangle [x0..x1] x [y0..y1] of a layer with one tile.
func _fill_block(layer: TileMapLayer, source_id: int, atlas: Vector2i, x0: int, x1: int, y0: int, y1: int) -> void:
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			layer.set_cell(Vector2i(x, y), source_id, atlas)


## Instances the real Unit, adds it in-tree, and spawns it on `cell` (tier 0).
## `setup()` reparents it under the tier's real `EntityTier*` container and places
## its origin at the footprint with the sprite raised onto the tier. Returned
## UNTYPED for duck-typed access to its no-`class_name` API (mirrors unit_debug.gd),
## or null if the scene is missing.
func _spawn_unit(map_system, cell: Vector2i):
	var scene: PackedScene = load("res://src/nodes/unit.tscn") as PackedScene
	if scene == null:
		push_error("unit_selection_harness: res://src/nodes/unit.tscn failed to load.")
		return null
	var unit = scene.instantiate()
	# Add under this node first so it is in-tree; setup() then reparents it into the
	# MapSystem's tier entity container.
	add_child(unit)
	unit.setup(map_system, cell, SPAWN_TIER)
	return unit


## Builds the real NavGraph over the painted flat apron (no ramps — single tier),
## asks for the same-tier route from the selected unit's spawn to the move goal, and
## issues it. From here the Unit's own `_process` steers along the waypoints every
## frame — the orchestrator screenshots "before" vs "after" by frame count. An empty
## route means the painting/goal don't line up — a real scenario bug — so it is
## surfaced loudly rather than silently rendering a stationary unit.
func _issue_move(map_system, unit) -> void:
	var nav: NavGraph = NavMapBuilder.from_map_system(map_system, [])
	if nav == null:
		push_error("unit_selection_harness: NavMapBuilder returned no graph.")
		return
	var waypoints: Array = nav.find_path(SELECTED_SPAWN_CELL, SPAWN_TIER, MOVE_GOAL_CELL, MOVE_GOAL_TIER)
	if waypoints.is_empty():
		push_error("unit_selection_harness: find_path returned [] — apron/goal do not line up (%s t%d -> %s t%d)." % [SELECTED_SPAWN_CELL, SPAWN_TIER, MOVE_GOAL_CELL, MOVE_GOAL_TIER])
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


## Fixed camera framing both spawns + the move path. Made current so it wins over any
## camera that might have survived stripping.
func _add_camera() -> void:
	var camera := Camera2D.new()
	camera.position = CAMERA_CENTER
	camera.zoom = CAMERA_ZOOM
	add_child(camera)
	camera.make_current()
