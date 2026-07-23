extends Node2D
## Render-harness proof scene for flow-field crowd movement (Unit V3·C, #80).
##
## This scene PROVES, visually, the acceptance criteria of the flow-field steering
## cluster against the REAL production pieces (never mocks): a whole GROUP of units
## sharing ONE FlowField fans out from a back row, flows AROUND a solid obstacle
## through a single gap, and settles in a SPREAD arc at the goal WITHOUT collapsing
## into a single stacked sprite. Where unit_nav_harness proves one unit steering a
## private A* path up a ramp (#76), this proves N units steering one shared field
## with mutual separation (#80).
##
## It instances the production `map_system.tscn` (so the elevation layer, its
## y_sort space, and the real `EntityTier0` container come straight from
## production), strips the interactive / time-varying nodes for a clean
## deterministic render, paints a SINGLE tier-0 field with a mid-field WATER wall
## that has a gap, builds one `FlowField` from `NavMapBuilder.walkable_query` over
## tier 0, spawns a back row of real `Unit` nodes (each with its own `FlowFollower`
## sharing the one field), and every `_process` drives each unit's drawn position
## from its follower's `advance`. It deliberately does NOT call `unit.issue_path`,
## so each Unit's own `_process` stays inert and never fights the harness.
##
## The orchestrator controls capture timing purely by how many frames it lets the
## scene run before screenshotting:
##   * a few frames in  -> units streaming off the back row toward the gap,
##   * many frames in   -> units funneled through the gap, settled in a spread arc.
##
## Head-ful under Xvfb; run + screenshot with:
##   godot --path . res://src/nodes/flow_field_harness.tscn
##
## Runtime-only (NOT `@tool`): none of this executes during a headless `--import` in
## CI, which only PARSES it. So (src/nodes/* rule) every var is explicitly typed --
## never `:=` inferred from a Variant -- and the `map_system` / `unit` instances are
## kept UNTYPED, duck-typed exactly as unit_nav_harness.gd / unit_debug.gd do
## (MapSystem and Unit carry no `class_name`), so the parse stays warnings-clean.

## Dual-grid lookup index of the fully-surrounded ("solid fill") walkable grass tile.
const GROUND_FILL_INDEX := 15

## Plain dark backdrop so the bright units and terrain read clearly.
const BACKGROUND_COLOR := Color(0.11, 0.12, 0.15)

## Tier-0 terrain tint (render-only legibility aid) and a distinct wall tint so the
## obstacle reads as a barrier rather than more ground.
const GROUND_TINT := Color(0.50, 0.60, 0.45)

## --- Painted geometry (INCLUSIVE cell rectangles [x0..x1] x [y0..y1]) ----------
## A single flat tier-0 field. Iso DIAMOND_DOWN: larger (x+y) draws further SOUTH,
## so the back row (small y, screen-north) flows toward the goal row (large y).
const FIELD_X0 := 0
const FIELD_X1 := 14
const FIELD_Y0 := 0
const FIELD_Y1 := 14

## The obstacle: a solid WATER wall spanning the field at this row, EXCEPT the gap
## columns [GAP_X0..GAP_X1] left as walkable grass. Water is non-walkable terrain, so
## the FlowField routes every unit through the single gap.
const WALL_Y := 7
const GAP_X0 := 6
const GAP_X1 := 8

## The back row the crowd spawns across (one unit per column) and the single shared
## goal in front, past the wall gap. ~12 units fan out and re-converge at the goal.
const SPAWN_Y := 1
const SPAWN_X0 := 2
const SPAWN_X1 := 13
const GOAL_CELL := Vector2i(7, 13)
const SPAWN_TIER := 0

## Fixed camera framing the whole field, wall, and goal. Deterministic -- no panning,
## no bounds, no randomness. Centred on the field's middle cell (7,7) and zoomed out
## so the full 15x15 painted grid plus the fanned crowd fill the viewport with margin.
const CAMERA_CENTER := Vector2(64.0, 480.0)
const CAMERA_ZOOM := Vector2(0.9, 0.9)

## Production scene nodes that are interactive / time-varying (editor, overlays,
## day/night tint, RTS camera, the click-to-spawn debug hook). They only add noise or
## steal control of a static proof render; freed at boot. `UnitDebug` MUST go -- its
## own spawn/pathing would otherwise fight the crowd we drive here.
const STRIPPED_NODES: Array[String] = [
	"DayNight", "Sun", "MapEditor", "MapPersistence", "DevMenu", "Camera", "UnitDebug",
]

## Per-unit followers (typed core; all share the ONE FlowField built in `_ready`).
var _followers: Array[FlowFollower] = []
## The production Unit nodes, held UNTYPED (no class_name; duck-typed API).
var _units: Array = []
## Each unit's current LIFTED world position (EntityPlacement.visual_position space),
## the space FlowFollower integrates in. Index-aligned with `_followers` / `_units`.
var _positions: PackedVector2Array = PackedVector2Array()


func _ready() -> void:
	var map_system = _spawn_map_system()
	if map_system == null:
		return
	_strip_runtime_children(map_system)
	_paint_terrain(map_system)
	_add_background()
	_add_camera()

	var field: FlowField = _build_field(map_system)
	if field == null:
		return
	_spawn_crowd(map_system, field)


## Instances the real MapSystem and adds it as a child (its `_ready` applies the
## per-tier elevation lift + `y_sort_origin` and populates the entity containers we
## depend on). Returned UNTYPED for duck-typed access to its no-`class_name` API, or
## null if the scene is missing.
func _spawn_map_system():
	var scene: PackedScene = load("res://src/nodes/map_system.tscn") as PackedScene
	if scene == null:
		push_error("flow_field_harness: res://src/nodes/map_system.tscn failed to load.")
		return null
	var map_system = scene.instantiate()
	add_child(map_system)
	return map_system


## Frees the instanced scene's interactive / time-varying nodes so the render is
## clean and deterministic. Deferred (queue_free) -- the instance's `_ready` has
## already applied the layer offsets and containers we depend on.
func _strip_runtime_children(map_system) -> void:
	for node_name in STRIPPED_NODES:
		var node: Node = map_system.get_node_or_null(node_name)
		if node != null:
			node.queue_free()


## Paints the single tier-0 proof field with the real terrain TileSet: a full grass
## rectangle, then a solid WATER wall across WALL_Y with a walkable gap. Water carries
## `walkable == false` custom data, so `walkable_query` (and thus the FlowField) treats
## the wall as solid and only the gap columns as passable.
func _paint_terrain(map_system) -> void:
	var tileset: TileSet = TileSetBuilder.build_default_terrain_tileset()
	if tileset == null:
		push_error("flow_field_harness: terrain tileset unavailable; cannot paint.")
		return
	var source_id: int = tileset.get_source_id(0)
	var fill: Vector2i = TileSetConstants.LOOKUP[GROUND_FILL_INDEX]
	var water: Vector2i = TileSetConstants.WATER_ANIM_COORDS

	var elevation0: TileMapLayer = map_system.get_elevation_layer(0)
	if elevation0 == null:
		push_error("flow_field_harness: MapSystem is missing elevation layer 0.")
		return

	# The production scene ships no TileSet resource on the layers, so bind one.
	elevation0.tile_set = tileset
	elevation0.modulate = GROUND_TINT

	# Grass everywhere in the field...
	for x in range(FIELD_X0, FIELD_X1 + 1):
		for y in range(FIELD_Y0, FIELD_Y1 + 1):
			elevation0.set_cell(Vector2i(x, y), source_id, fill)

	# ...then overwrite the wall row with non-walkable water, leaving the gap grass.
	for x in range(FIELD_X0, FIELD_X1 + 1):
		if x >= GAP_X0 and x <= GAP_X1:
			continue
		elevation0.set_cell(Vector2i(x, WALL_Y), source_id, water)


## Builds the ONE shared FlowField over tier 0: region = the painted layer's used
## rect, walkability = NavMapBuilder.walkable_query on that layer (water == solid),
## goal = the single front goal cell. Every follower shares this instance.
func _build_field(map_system) -> FlowField:
	var elevation0: TileMapLayer = map_system.get_elevation_layer(0)
	if elevation0 == null:
		push_error("flow_field_harness: cannot build field; elevation layer 0 missing.")
		return null
	var region: Rect2i = elevation0.get_used_rect()
	var walkable: Callable = NavMapBuilder.walkable_query(elevation0)
	return FlowField.new(region, walkable, GOAL_CELL)


## Spawns one real Unit per back-row column, each with its own FlowFollower sharing
## `field`. `setup()` reparents the unit under EntityTier0 and places its origin at
## the footprint (#75). Records each unit's initial LIFTED world position so
## `_process` can steer it. Does NOT issue a path -- the harness drives motion.
func _spawn_crowd(map_system, field: FlowField) -> void:
	var scene: PackedScene = load("res://src/nodes/unit.tscn") as PackedScene
	if scene == null:
		push_error("flow_field_harness: res://src/nodes/unit.tscn failed to load.")
		return
	for x in range(SPAWN_X0, SPAWN_X1 + 1):
		var cell := Vector2i(x, SPAWN_Y)
		var unit = scene.instantiate()
		add_child(unit)
		unit.setup(map_system, cell, SPAWN_TIER)
		_units.append(unit)
		_followers.append(FlowFollower.new(field, SPAWN_TIER))
		_positions.append(EntityPlacement.visual_position(cell, SPAWN_TIER))


## Every frame: snapshot all units' current world positions, then advance each
## follower against the OTHER units' PRE-frame positions (not a half-updated set,
## and never its own position -- Steering.separation treats a coincident self as a
## huge push), writing each unit's drawn origin from the returned lifted position,
## stripped back to the footprint (EntityPlacement).
func _process(delta: float) -> void:
	if _followers.is_empty():
		return
	var snapshot: PackedVector2Array = _positions
	var lift: Vector2 = EntityPlacement.visual_offset(SPAWN_TIER)
	for i in _followers.size():
		var follower: FlowFollower = _followers[i]
		var out: Dictionary = follower.advance(snapshot[i], _others(snapshot, i), delta)
		var new_pos: Vector2 = out["pos"]
		_positions[i] = new_pos
		var unit = _units[i]
		unit.position = new_pos - lift


## The positions of every unit EXCEPT `self_index` -- the separation neighbour set
## for the unit at `self_index` (a unit must not repel itself; Steering treats a
## coincident point as a fixed maximal push).
func _others(positions: PackedVector2Array, self_index: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in positions.size():
		if i != self_index:
			out.append(positions[i])
	return out


## Full-screen dark backdrop on a below-world CanvasLayer, legible regardless of
## camera framing.
func _add_background() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = -1
	add_child(canvas)
	var rect := ColorRect.new()
	rect.color = BACKGROUND_COLOR
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(rect)


## Fixed camera framing the whole field. Made current so it wins over any camera that
## might have survived stripping.
func _add_camera() -> void:
	var camera := Camera2D.new()
	camera.position = CAMERA_CENTER
	camera.zoom = CAMERA_ZOOM
	add_child(camera)
	camera.make_current()
