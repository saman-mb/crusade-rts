extends Node2D
## Render-harness proof scene for GROUP FORMATION FLOW commands (Group Command V3, #81).
##
## This scene PROVES, visually, the acceptance criterion of the formation cluster
## against the REAL production pieces (never mocks): a compact CLUSTER of units, given
## ONE group move order at a single goal cell, fans out and ARRIVES SPREAD across
## DISTINCT cells in a formation ring around the goal — none stacked on the goal cell.
## Where flow_field_harness proves N units sharing ONE field converging on one goal
## (#80), this proves N units each steering its OWN field toward its OWN assigned
## FORMATION SLOT (#81): Formation.slots lays out the ring, Formation.assign matches
## each unit to a slot, and one FlowField+FlowFollower per unit drives it there.
##
## It instances the production `map_system.tscn` (so the elevation layer, its y_sort
## space, and the real `EntityTier0` container come straight from production), strips
## the interactive / time-varying nodes for a clean deterministic render, paints a
## SINGLE tier-0 field with a small WATER blob NEAR the goal (so a few ring slots are
## blocked and the formation visibly DEGRADES around the obstacle), spawns a real
## `Unit` cluster, computes the formation + assignment ONCE at boot, and every
## `_process` drives each unit's drawn position from its follower's `advance`. It
## deliberately does NOT call `unit.issue_path`, so each Unit's own `_process` stays
## inert and never fights the harness.
##
## The orchestrator controls capture timing purely by how many frames it lets the
## scene run before screenshotting:
##   * a few frames in  -> the cluster streaming out toward the goal,
##   * many frames in   -> the cluster settled in a spread formation ring at the goal.
##
## Head-ful under Xvfb; run + screenshot with:
##   godot --path . res://src/nodes/group_command_harness.tscn
##
## Runtime-only (NOT `@tool`): none of this executes during a headless `--import` in
## CI, which only PARSES it. So (src/nodes/* rule) every var is explicitly typed --
## never `:=` inferred from a Variant -- and the `map_system` / `unit` instances are
## kept UNTYPED, duck-typed exactly as flow_field_harness.gd / unit_debug.gd do
## (MapSystem and Unit carry no `class_name`), so the parse stays warnings-clean.

## Dual-grid lookup index of the fully-surrounded ("solid fill") walkable grass tile.
const GROUND_FILL_INDEX := 15

## Plain dark backdrop so the bright units and terrain read clearly.
const BACKGROUND_COLOR := Color(0.11, 0.12, 0.15)

## Tier-0 terrain tint (render-only legibility aid).
const GROUND_TINT := Color(0.50, 0.60, 0.45)

## --- Painted geometry (INCLUSIVE cell rectangles [x0..x1] x [y0..y1]) ----------
## A single flat tier-0 field. Iso DIAMOND_DOWN: larger (x+y) draws further SOUTH,
## so the north-west cluster (small x+y) flows toward the south-east goal.
const FIELD_X0 := 0
const FIELD_X1 := 14
const FIELD_Y0 := 0
const FIELD_Y1 := 14

## The compact CLUSTER the group spawns in (a solid block, north-west of the goal).
## 3x3 == 9 real units — enough to fill a formation ring plus spill into a second.
const CLUSTER_X0 := 1
const CLUSTER_X1 := 3
const CLUSTER_Y0 := 1
const CLUSTER_Y1 := 3
const SPAWN_TIER := 0

## The single group goal, south-east of the cluster. The goal cell itself stays
## walkable (it is formation slot 0); the obstacle sits BESIDE it.
const GOAL_CELL := Vector2i(10, 10)

## A small non-walkable WATER blob NEAR the goal (on its north-west approach, where
## the cluster comes from). It blocks a few of the goal's ring-1 formation slots, so
## Formation.slots skips them and the arriving ring is visibly ASYMMETRIC around the
## obstacle rather than a clean symmetric ring — formation degradation on show.
const OBSTACLE_CELLS: Array[Vector2i] = [
	Vector2i(9, 9), Vector2i(10, 9), Vector2i(9, 10),
]

## Fixed camera framing the cluster, obstacle, and goal. Deterministic -- no panning,
## no bounds, no randomness. Centred between the cluster and the goal and zoomed out
## so the full path plus the fanned formation fill the viewport with margin.
const CAMERA_CENTER := Vector2(64.0, 448.0)
const CAMERA_ZOOM := Vector2(0.85, 0.85)

## Production scene nodes that are interactive / time-varying (editor, overlays,
## day/night tint, RTS camera, the click-to-spawn debug hook). They only add noise or
## steal control of a static proof render; freed at boot. `UnitDebug` MUST go -- its
## own spawn/pathing/group-order would otherwise fight the crowd we drive here.
const STRIPPED_NODES: Array[String] = [
	"DayNight", "Sun", "MapEditor", "MapPersistence", "DevMenu", "Camera", "UnitDebug",
]

## Per-unit followers (typed core; each steers its OWN FlowField toward its assigned
## formation slot). Index-aligned with `_units` / `_positions`.
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
	_spawn_and_order(map_system)


## Instances the real MapSystem and adds it as a child (its `_ready` applies the
## per-tier elevation lift + `y_sort_origin` and populates the entity containers we
## depend on). Returned UNTYPED for duck-typed access to its no-`class_name` API, or
## null if the scene is missing.
func _spawn_map_system():
	var scene: PackedScene = load("res://src/nodes/map_system.tscn") as PackedScene
	if scene == null:
		push_error("group_command_harness: res://src/nodes/map_system.tscn failed to load.")
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
## rectangle, then a small WATER blob near the goal. Water carries `walkable == false`
## custom data, so `walkable_query` (and thus Formation.slots and every FlowField)
## treats those cells as solid.
func _paint_terrain(map_system) -> void:
	var tileset: TileSet = TileSetBuilder.build_default_terrain_tileset()
	if tileset == null:
		push_error("group_command_harness: terrain tileset unavailable; cannot paint.")
		return
	var source_id: int = tileset.get_source_id(0)
	var fill: Vector2i = TileSetConstants.LOOKUP[GROUND_FILL_INDEX]
	var water: Vector2i = TileSetConstants.WATER_ANIM_COORDS

	var elevation0: TileMapLayer = map_system.get_elevation_layer(0)
	if elevation0 == null:
		push_error("group_command_harness: MapSystem is missing elevation layer 0.")
		return

	# The production scene ships no TileSet resource on the layers, so bind one.
	elevation0.tile_set = tileset
	elevation0.modulate = GROUND_TINT

	# Grass everywhere in the field...
	for x in range(FIELD_X0, FIELD_X1 + 1):
		for y in range(FIELD_Y0, FIELD_Y1 + 1):
			elevation0.set_cell(Vector2i(x, y), source_id, fill)

	# ...then punch the non-walkable water obstacle beside the goal.
	for cell: Vector2i in OBSTACLE_CELLS:
		elevation0.set_cell(cell, source_id, water)


## Spawns the real Unit cluster, computes the formation ONCE, and installs one
## FlowField+FlowFollower per unit toward its ASSIGNED slot. `setup()` reparents each
## unit under EntityTier0 and places its origin at the footprint (#75). Records each
## unit's initial LIFTED world position so `_process` can steer it. Does NOT issue a
## path -- the harness drives motion.
func _spawn_and_order(map_system) -> void:
	var elevation0: TileMapLayer = map_system.get_elevation_layer(0)
	if elevation0 == null:
		push_error("group_command_harness: cannot order group; elevation layer 0 missing.")
		return
	var region: Rect2i = elevation0.get_used_rect()
	var walkable: Callable = NavMapBuilder.walkable_query(elevation0)

	var scene: PackedScene = load("res://src/nodes/unit.tscn") as PackedScene
	if scene == null:
		push_error("group_command_harness: res://src/nodes/unit.tscn failed to load.")
		return

	# Spawn the compact cluster; record each unit's start cell (the `unit_cells` input
	# to Formation.assign), index-aligned with `_units` / `_positions`.
	var unit_cells: Array[Vector2i] = []
	for y in range(CLUSTER_Y0, CLUSTER_Y1 + 1):
		for x in range(CLUSTER_X0, CLUSTER_X1 + 1):
			var cell := Vector2i(x, y)
			var unit = scene.instantiate()
			add_child(unit)
			unit.setup(map_system, cell, SPAWN_TIER)
			_units.append(unit)
			_positions.append(EntityPlacement.visual_position(cell, SPAWN_TIER))
			unit_cells.append(cell)

	# One group order: N distinct walkable formation slots around the goal, then a
	# stable nearest assignment of unit -> slot.
	var count: int = _units.size()
	var slot_cells: Array[Vector2i] = Formation.slots(GOAL_CELL, count, walkable, region)
	if slot_cells.is_empty():
		push_error("group_command_harness: no formation slots for goal %s." % GOAL_CELL)
		return
	var mapping: PackedInt32Array = Formation.assign(unit_cells, slot_cells)

	# Per-unit FlowField toward its assigned slot, each followed by its own FlowFollower.
	for i in range(count):
		var slot_index: int = mapping[i]
		var slot: Vector2i = slot_cells[slot_index]
		var field: FlowField = FlowField.new(region, walkable, slot)
		_followers.append(FlowFollower.new(field, SPAWN_TIER))


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
