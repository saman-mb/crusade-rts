extends Node2D
## Render-harness proof scene for ramp/chokepoint polish (#79).
##
## This scene PROVES, visually, the chokepoint-queueing acceptance of #79 against the
## REAL production pieces (never mocks): a crowd of units funnelling toward a SINGLE
## 1-cell-wide gap crosses it SINGLE-FILE — queueing upstream — instead of stacking a
## pile of sprites onto the one choke cell. It is the 1-wide sibling of
## flow_field_harness (which funnels the same crowd through a 3-wide gap and therefore
## never needs to queue): here the gap is one cell, so the RampQueue core governs who
## may enter it while the existing FlowField + Steering handle the rest of the motion.
##
## HOW IT WORKS. Like flow_field_harness it instances the production `map_system.tscn`
## (real elevation layer, y_sort space, EntityTier0 container), strips the interactive
## / time-varying nodes, paints a single tier-0 field with a solid WATER wall broken by
## exactly ONE walkable gap cell (the choke), builds one shared `FlowField` over tier 0,
## and spawns a back row of real `Unit` nodes each with its own `FlowFollower` sharing
## the field. Every `_process` it (1) resolves the queue at the choke via `RampQueue` —
## priority = distance to the choke, so the nearest unit has right-of-way — and (2)
## advances only the units the queue ADMITS, holding the rest in place so at most one
## unit is on the choke at a time. It does NOT call `unit.issue_path`, so each Unit's
## own `_process` stays inert and never fights the harness.
##
## The orchestrator controls capture timing by how many frames it lets the scene run:
##   * a few frames in  -> the crowd streaming toward the choke,
##   * mid   -> a single-file column threading the gap with a queue backed up behind it,
##   * many  -> the crowd re-formed past the gap, settled at the goal.
##
## SINGLE-TIER NOTE. FlowFollower is pinned to one tier (cross-tier group flow is
## deferred, per its class docs), so the "ramp" here is modelled as a 1-wide corridor
## on tier 0. RampQueue is tier-agnostic (it orders abstract { id, cell, priority }
## records), so the exact same gate governs a genuine cross-tier ramp once cross-tier
## flow lands. The SMOOTH-ELEVATION half of #79 is proven separately by the ramp climb
## in unit_nav_harness (now interpolated by unit.gd + ElevationLerp).
##
## Head-ful under Xvfb; run + screenshot with:
##   godot --path . res://src/nodes/ramp_polish_harness.tscn
##
## Runtime-only (NOT `@tool`): none of this executes during a headless `--import` in CI,
## which only PARSES it. So (src/nodes/* rule) every var is explicitly typed — never
## `:=` inferred from a Variant — and the `map_system` / `unit` instances are kept
## UNTYPED, duck-typed exactly as flow_field_harness.gd / unit_debug.gd do.

## Dual-grid lookup index of the fully-surrounded ("solid fill") walkable grass tile.
const GROUND_FILL_INDEX := 15

## Plain dark backdrop so the bright units and terrain read clearly.
const BACKGROUND_COLOR := Color(0.11, 0.12, 0.15)

## Tier-0 terrain tint (render-only legibility aid).
const GROUND_TINT := Color(0.50, 0.60, 0.45)

## --- Painted geometry (INCLUSIVE cell rectangles [x0..x1] x [y0..y1]) ----------
## A single flat tier-0 field. Iso DIAMOND_DOWN: larger (x+y) draws further SOUTH,
## so the back row (small y) flows toward the goal row (large y).
const FIELD_X0 := 0
const FIELD_X1 := 14
const FIELD_Y0 := 0
const FIELD_Y1 := 14

## The obstacle: a solid WATER wall across this row, EXCEPT the single walkable gap
## column CHOKE_X — a ONE-cell gap, so every unit must cross the same choke cell.
const WALL_Y := 7
const CHOKE_X := 7

## The choke cell itself (the 1-wide gap the queue governs).
const CHOKE_CELL := Vector2i(CHOKE_X, WALL_Y)

## The back row the crowd spawns across (one unit per column) and the single shared
## goal past the wall gap. ~9 units contend for the one gap.
const SPAWN_Y := 1
const SPAWN_X0 := 3
const SPAWN_X1 := 11
const GOAL_CELL := Vector2i(7, 13)
const SPAWN_TIER := 0

## Queue gate range: only units within this Chebyshev cell distance of the choke are
## gated by the queue; farther units flow freely. Matches unit_debug.CHOKE_HOLD_RANGE.
const CHOKE_HOLD_RANGE := 3

## Fixed camera framing the whole field, wall, and goal. Deterministic — centred on the
## field middle and zoomed so the full grid plus the queued column fill the viewport.
const CAMERA_CENTER := Vector2(64.0, 480.0)
const CAMERA_ZOOM := Vector2(0.9, 0.9)

## Production scene nodes that are interactive / time-varying; freed at boot. `UnitDebug`
## MUST go — its own spawn/pathing would fight the crowd we drive here.
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


## Instances the real MapSystem (its `_ready` applies the per-tier lift + y_sort_origin
## and populates the entity containers). UNTYPED for duck-typed access, or null.
func _spawn_map_system():
	var scene: PackedScene = load("res://src/nodes/map_system.tscn") as PackedScene
	if scene == null:
		push_error("ramp_polish_harness: res://src/nodes/map_system.tscn failed to load.")
		return null
	var map_system = scene.instantiate()
	add_child(map_system)
	return map_system


## Frees the instanced scene's interactive / time-varying nodes for a clean render.
func _strip_runtime_children(map_system) -> void:
	for node_name in STRIPPED_NODES:
		var node: Node = map_system.get_node_or_null(node_name)
		if node != null:
			node.queue_free()


## Paints the single tier-0 field: full grass, then a solid WATER wall across WALL_Y
## with a SINGLE walkable gap at CHOKE_X. Water is non-walkable, so the FlowField routes
## every unit through the one gap cell.
func _paint_terrain(map_system) -> void:
	var tileset: TileSet = TileSetBuilder.build_default_terrain_tileset()
	if tileset == null:
		push_error("ramp_polish_harness: terrain tileset unavailable; cannot paint.")
		return
	var source_id: int = tileset.get_source_id(0)
	var fill: Vector2i = TileSetConstants.LOOKUP[GROUND_FILL_INDEX]
	var water: Vector2i = TileSetConstants.WATER_ANIM_COORDS

	var elevation0: TileMapLayer = map_system.get_elevation_layer(0)
	if elevation0 == null:
		push_error("ramp_polish_harness: MapSystem is missing elevation layer 0.")
		return

	elevation0.tile_set = tileset
	elevation0.modulate = GROUND_TINT

	# Grass everywhere...
	for x in range(FIELD_X0, FIELD_X1 + 1):
		for y in range(FIELD_Y0, FIELD_Y1 + 1):
			elevation0.set_cell(Vector2i(x, y), source_id, fill)

	# ...then a solid water wall across WALL_Y, leaving ONLY CHOKE_X grass.
	for x in range(FIELD_X0, FIELD_X1 + 1):
		if x == CHOKE_X:
			continue
		elevation0.set_cell(Vector2i(x, WALL_Y), source_id, water)


## Builds the ONE shared FlowField over tier 0 toward GOAL_CELL. Every follower shares it.
func _build_field(map_system) -> FlowField:
	var elevation0: TileMapLayer = map_system.get_elevation_layer(0)
	if elevation0 == null:
		push_error("ramp_polish_harness: cannot build field; elevation layer 0 missing.")
		return null
	var region: Rect2i = elevation0.get_used_rect()
	var walkable: Callable = NavMapBuilder.walkable_query(elevation0)
	return FlowField.new(region, walkable, GOAL_CELL)


## Spawns one real Unit per back-row column, each with its own FlowFollower sharing
## `field`. Records each unit's initial LIFTED world position. Does NOT issue a path.
func _spawn_crowd(map_system, field: FlowField) -> void:
	var scene: PackedScene = load("res://src/nodes/unit.tscn") as PackedScene
	if scene == null:
		push_error("ramp_polish_harness: res://src/nodes/unit.tscn failed to load.")
		return
	for x in range(SPAWN_X0, SPAWN_X1 + 1):
		var cell := Vector2i(x, SPAWN_Y)
		var unit = scene.instantiate()
		add_child(unit)
		unit.setup(map_system, cell, SPAWN_TIER)
		_units.append(unit)
		_followers.append(FlowFollower.new(field, SPAWN_TIER))
		_positions.append(EntityPlacement.visual_position(cell, SPAWN_TIER))


## Every frame: resolve the choke queue, then advance only the ADMITTED units (holding
## the rest in place). Each admitted follower is fed the OTHER units' pre-frame positions
## (separation), and each unit's drawn origin is written from the returned lifted pos.
func _process(delta: float) -> void:
	if _followers.is_empty():
		return
	var snapshot: PackedVector2Array = _positions
	var lift: Vector2 = EntityPlacement.visual_offset(SPAWN_TIER)
	var holds: Dictionary = _choke_holds(snapshot)
	for i in _followers.size():
		var unit = _units[i]
		if holds.has(i):
			# HELD behind the choke: freeze in place this frame (queue upstream).
			unit.position = snapshot[i] - lift
			continue
		var follower: FlowFollower = _followers[i]
		var out: Dictionary = follower.advance(snapshot[i], _others(snapshot, i), delta)
		var new_pos: Vector2 = out["pos"]
		_positions[i] = new_pos
		unit.position = new_pos - lift


## Which unit indices must HOLD this frame to keep the choke single-file (#79): every
## non-admitted contender within CHOKE_HOLD_RANGE of the choke. Priority = distance to
## the choke world position (nearer == front); the ordering/admission is the pure
## RampQueue core, so at most one unit is ever cleared onto the choke cell.
func _choke_holds(snapshot: PackedVector2Array) -> Dictionary:
	var holds: Dictionary = {}
	var choke_world: Vector2 = EntityPlacement.visual_position(CHOKE_CELL, SPAWN_TIER)
	var lift: Vector2 = EntityPlacement.visual_offset(SPAWN_TIER)
	var contenders: Array = []
	for i in _units.size():
		var ucell: Vector2i = IsoCoord.pick_cell(snapshot[i] - lift)
		var dx: int = absi(ucell.x - CHOKE_CELL.x)
		var dy: int = absi(ucell.y - CHOKE_CELL.y)
		if maxi(dx, dy) > CHOKE_HOLD_RANGE:
			continue
		var prio: float = snapshot[i].distance_to(choke_world)
		contenders.append({ "id": i, "cell": ucell, "priority": prio })
	if contenders.size() <= 1:
		return holds
	var res: Dictionary = RampQueue.resolve(contenders, CHOKE_CELL)
	for it: Dictionary in contenders:
		var id: int = it["id"]
		if not RampQueue.may_enter(res, id):
			holds[id] = true
	return holds


## The positions of every unit EXCEPT `self_index` — the separation neighbour set.
func _others(positions: PackedVector2Array, self_index: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in positions.size():
		if i != self_index:
			out.append(positions[i])
	return out


## Full-screen dark backdrop on a below-world CanvasLayer.
func _add_background() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = -1
	add_child(canvas)
	var rect := ColorRect.new()
	rect.color = BACKGROUND_COLOR
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(rect)


## Fixed camera framing the whole field. Made current so it wins over any survivor.
func _add_camera() -> void:
	var camera := Camera2D.new()
	camera.position = CAMERA_CENTER
	camera.zoom = CAMERA_ZOOM
	add_child(camera)
	camera.make_current()
