extends Node2D
## Dev-only select/move/spawn hook (#77): turns raw engine input into proper RTS
## controls over a registry of spawned units, so movement and multi-unit orders can
## be exercised by hand before the real order UI (B1) lands.
##
## Controls:
##   LEFT-click  — select the unit under the cursor on the active tier; an empty
##                 cell clears the selection.
##   LEFT-drag   — MARQUEE multi-select (#81): a drag past a small dead-zone strokes
##                 a rectangle and replace-selects every unit inside it on the active
##                 tier (Shift = additive). A drag under the dead-zone falls through
##                 to the single-click select above.
##   RIGHT-click — issue a MOVE. With a SINGLE unit selected this is the per-unit A*
##                 path (cross-tier capable). With ≥2 units it is a GROUP FORMATION
##                 FLOW order (#81): the units fan out into a formation ring of
##                 distinct walkable cells around the clicked cell on the active tier,
##                 each steered by its own FlowField/FlowFollower driven from _process.
##   S           — spawn a fresh unit at the cursor on the active tier.
##   1 / 2 / 3   — set the active tier (spawn tier / hit-test tier / move-destination
##                 tier). The tier is an explicit selector, NOT inferred from the
##                 click — a debug simplification in the spirit of "grid is guidance":
##                 the human states which tier they mean.
##
## Screen->cell projection reuses `IsoCoord.pick_cell_global`, matching `MapEditor`
## (camera-safe, edge-robust).
##
## Units live in the `_units` registry (monotonic int id -> Unit node) and the picked
## selection is the pure, Node-free `Selection` core: LEFT-click hit-tests via
## `Selection.unit_at` over a fresh snapshot of the registry and replace-selects the
## hit (or clears on a miss); RIGHT-click iterates `Selection.selected_ids()` and
## paths each unit. Highlights are re-driven from the selection after every change.
##
## Ramps are DERIVED from painted ramp tiles on the map by `NavMapBuilder.from_map_system`
## (#78 B1); `set_ramps` is now an optional debug OVERRIDE (empty by default) whose
## `NavRamp` list is overlaid on top of the derived ramps, not the source of them. The
## `NavGraph` is rebuilt from scratch on every MOVE (`NavMapBuilder.from_map_system`) —
## the debug map is tiny, so a per-order rebuild is cheaper than maintaining incremental
## nav state, and it always reflects the latest painted terrain.
##
## Like `MapEditor` this is a RUNTIME node (not `@tool`), so none of it executes during
## a headless `--import` in CI.

## Sentinel cell returned by `_pick_cell` when the active tier has no layer; callers
## bail on it so the hook stays crash-safe on an unresolved/absent tier.
const NO_CELL := Vector2i(-2147483648, -2147483648)

## Minimum drag distance (world px) before a LEFT press+release is treated as a
## MARQUEE rather than a single-click select. Below it, a jittery click still
## selects the unit under the cursor. (#81)
const DRAG_DEADZONE_PX := 6.0

## Marquee overlay look: a faint fill and a thin bright outline, drawn in-world by
## `_draw()` (like the per-unit selection ring — NOT a Control/Theme). (#81)
const MARQUEE_FILL := Color(0.4, 0.8, 1.0, 0.12)
const MARQUEE_LINE := Color(0.5, 0.9, 1.0, 0.9)
const MARQUEE_LINE_WIDTH := 1.5

## Path to the MapSystem node this hook spawns units into and pathfinds across.
@export var map_system_path: NodePath

## Optional debug OVERRIDE `NavRamp` list overlaid on top of the ramps `NavMapBuilder`
## derives from painted ramp tiles (#78 B1). Empty by default; the harness/injector may
## set it via `set_ramps` to append extra ramps to the derived set.
var _ramps: Array = []

## The resolved MapSystem node. Left UNTYPED on purpose so its `get_elevation_layer()`
## API is duck-typed: MapSystem carries no `class_name`, and a static `Node` type would
## make the 4.4 analyzer reject the call ("not found in base Node") and fail the whole
## script load. Mirrors MapEditor.
var _map_system
## Registry of spawned units: monotonic int id -> Unit node. Values are UNTYPED on
## purpose — the Unit node exposes `setup`/`issue_path`/`current_cell`/`current_tier`/
## `set_selected` without a `class_name`, so pulling a value into a typed `Node` local
## would make the 4.4 analyzer reject those calls. Always read a value into an UNTYPED
## `var unit = _units[id]`.
var _units: Dictionary = {}
## Monotonic id source for `_units`; never reused, so a freed id can't collide with a
## later spawn.
var _next_id: int = 0
## Pure selection core (the set of picked unit ids); single source of truth the LEFT
## click writes and the RIGHT click reads.
var _selection := Selection.new()
## Active tier selector (spawn tier / hit-test tier / move-destination tier). Set by
## number keys 1/2/3, default tier 0.
var _active_tier: int = 0

## --- Marquee drag state (#81) -------------------------------------------------
## While `_dragging`, a LEFT button is held down and `_drag_start`/`_drag_end` track
## the drag rectangle in GLOBAL (world) space — the same space every unit's
## `global_position` and the marquee rect live in, so the hit-test is a plain
## point-in-rect. Global space is a pure translation away from the active layer's
## local space (all layers are unscaled translations), so a global-space marquee
## test is IDENTICAL to the layer-local test the single-click pick uses — with far
## less bookkeeping. `_draw()` converts the rect back to this node's local space to
## stroke it.
var _dragging: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _drag_end: Vector2 = Vector2.ZERO

## --- Active group-flow order (#81) --------------------------------------------
## The one live GROUP FORMATION FLOW order, as parallel arrays index-aligned across
## all three: the ordered Unit nodes (UNTYPED — no class_name), their per-unit
## FlowFollowers (each steering its OWN single-goal FlowField toward its assigned
## formation slot), and each unit's current LIFTED world position (the space
## FlowFollower integrates in). Empty when no group order is active, which is what
## keeps `_process` idle. Issuing a new group order retires the previous one first.
var _group_units: Array = []
var _group_followers: Array[FlowFollower] = []
var _group_positions: PackedVector2Array = PackedVector2Array()
## The tier the active group order was issued on (its followers are pinned to it);
## used to lift/unlift positions in `_process`.
var _group_tier: int = 0


func _ready() -> void:
	# Defer binding by one step so the parent MapSystem's @onready layers are populated
	# by the time we resolve it — children ready before their parent, and a deferred
	# call runs after the whole tree finishes readying. (Mirrors MapEditor's rationale.)
	_setup.call_deferred()


func _setup() -> void:
	_map_system = get_node_or_null(map_system_path)
	if _map_system == null:
		push_warning("unit_debug: map_system_path unresolved; hook is inert.")


func _unhandled_input(event: InputEvent) -> void:
	# Inert hook (map_system_path unresolved): every handler below dereferences
	# _map_system, so bail early to stay crash-safe.
	if _map_system == null:
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			# LEFT is a press-drag-release gesture: the press only ARMS the drag; the
			# release decides marquee (past the dead-zone) vs single-click select.
			if button.pressed:
				_begin_drag()
			else:
				_end_drag(button.shift_pressed)
		elif button.button_index == MOUSE_BUTTON_RIGHT and button.pressed:
			_move_at_mouse()
	elif event is InputEventMouseMotion:
		# Grow the marquee rectangle as the cursor moves while the LEFT button is held.
		if _dragging:
			_drag_end = _drag_point()
			queue_redraw()
	elif event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo:
			match key.keycode:
				KEY_1, KEY_2, KEY_3:
					_active_tier = key.keycode - KEY_1
				KEY_S:
					_spawn_at_mouse()


## Projects the mouse to a cell on the active tier's layer. Returns NO_CELL when the
## active tier has no layer; callers bail on that sentinel.
func _pick_cell() -> Vector2i:
	var layer: TileMapLayer = _map_system.get_elevation_layer(_active_tier)
	if layer == null:
		return NO_CELL
	return IsoCoord.pick_cell_global(layer, layer.get_global_mouse_position())


## Spawns a fresh unit at the picked cell on the active tier and registers it under a
## new monotonic id. No-op when the active tier has no layer.
func _spawn_at_mouse() -> void:
	var cell: Vector2i = _pick_cell()
	if cell == NO_CELL:
		return
	# UNTYPED local on purpose: a `var unit := ...instantiate()` (or `var unit: Node`)
	# would infer the static `Node` type and the 4.4 analyzer would then reject
	# `unit.setup()` as "not found in base Node", failing script load. Duck-typing
	# through an untyped var mirrors _map_system.
	var unit = preload("res://src/nodes/unit.tscn").instantiate()
	# Add under this node first so it is in-tree; setup() reparents it into the
	# MapSystem's tier entity container.
	add_child(unit)
	unit.setup(_map_system, cell, _active_tier)
	_units[_next_id] = unit
	_next_id += 1


## Hit-tests the picked cell against the unit registry and replace-selects the unit
## there; an empty cell clears the selection. No-op when the active tier has no layer.
func _select_at_mouse() -> void:
	var cell: Vector2i = _pick_cell()
	if cell == NO_CELL:
		return
	var entries: Array = []
	for id: int in _units:
		# Duck-typed unit node: keep it UNTYPED (see _units doc).
		var unit = _units[id]
		entries.append({"id": id, "cell": unit.current_cell(), "tier": unit.current_tier()})
	var hit: int = Selection.unit_at(entries, cell, _active_tier)
	if hit >= 0:
		_selection.select_only(hit)
	else:
		_selection.clear()
	_refresh_highlights()


## The current marquee anchor point in GLOBAL (world) space — the same space unit
## `global_position`s live in, so the hit-test is a plain point-in-rect. Mirrors the
## single-click pick's use of the world mouse (there via the layer; here direct).
func _drag_point() -> Vector2:
	return get_global_mouse_position()


## Arms a LEFT-drag: records the anchor and starts tracking. The gesture only becomes
## a marquee (vs a single-click select) at release, past the dead-zone.
func _begin_drag() -> void:
	_dragging = true
	_drag_start = _drag_point()
	_drag_end = _drag_start
	queue_redraw()


## Ends a LEFT-drag. Past the dead-zone it is a MARQUEE multi-select (Shift = add to
## the current selection instead of replacing it); under the dead-zone it falls
## through to the existing single-click select so a plain click still works.
func _end_drag(additive: bool) -> void:
	if not _dragging:
		return
	_dragging = false
	_drag_end = _drag_point()
	if _drag_start.distance_to(_drag_end) > DRAG_DEADZONE_PX:
		_marquee_select(additive)
	else:
		_select_at_mouse()
	queue_redraw()


## MARQUEE multi-select: snapshots every unit's world position + tier, asks Marquee
## which ids fall inside the normalised drag rect on the active tier, and (unless
## `additive`) replace-selects them. Highlights are re-driven afterwards.
func _marquee_select(additive: bool) -> void:
	var rect: Rect2 = _drag_rect()
	var entries: Array = []
	for id: int in _units:
		# Duck-typed unit node: keep it UNTYPED (see _units doc). `global_position` is
		# the unlifted footprint origin — the same anchor the rect is drawn over.
		var unit = _units[id]
		entries.append({"id": id, "pos": unit.global_position, "tier": unit.current_tier()})
	var hits: Array[int] = Marquee.ids_in_rect(entries, rect, _active_tier)
	if not additive:
		_selection.clear()
	for hid: int in hits:
		_selection.add(hid)
	_refresh_highlights()


## The current drag as a NORMALISED (non-negative size) Rect2 in global space.
func _drag_rect() -> Rect2:
	return Rect2(_drag_start, _drag_end - _drag_start).abs()


## In-world marquee overlay (like the per-unit selection ring — NOT a Control/Theme):
## while dragging, strokes the drag rectangle with a faint fill + thin bright outline.
## The rect is held in global space, so its corners are converted to this node's local
## space before drawing.
func _draw() -> void:
	if not _dragging:
		return
	var rect: Rect2 = _drag_rect()
	var a: Vector2 = to_local(rect.position)
	var b: Vector2 = to_local(rect.end)
	var local_rect: Rect2 = Rect2(a, b - a).abs()
	draw_rect(local_rect, MARQUEE_FILL, true)
	draw_rect(local_rect, MARQUEE_LINE, false, MARQUEE_LINE_WIDTH)


## Issues a MOVE at the picked cell. Dispatches on the selection SIZE: ≥2 units is a
## GROUP FORMATION FLOW order (units fan out into a ring around the cell); 0–1 units
## keeps the classic per-unit A* path (cross-tier capable). No-op when the active
## tier has no layer.
func _move_at_mouse() -> void:
	var cell: Vector2i = _pick_cell()
	if cell == NO_CELL:
		return
	var selected: Array[int] = _selection.selected_ids()
	if selected.size() >= 2:
		_issue_group_flow(cell, selected)
	else:
		_issue_single_path(cell)


## Per-unit A* MOVE (single-unit or empty selection): rebuilds the nav graph and
## paths each selected unit from its current cell/tier to the picked cell on the
## active tier. Units with no route are skipped with a warning. This is the ORIGINAL
## right-click behaviour, unchanged, now reached only for a 0/1-unit selection.
func _issue_single_path(cell: Vector2i) -> void:
	var nav: NavGraph = NavMapBuilder.from_map_system(_map_system, _ramps)
	for id in _selection.selected_ids():
		# Duck-typed unit node: keep it UNTYPED (see _units doc).
		var unit = _units[id]
		var wp: Array = nav.find_path(unit.current_cell(), unit.current_tier(), cell, _active_tier)
		if wp.is_empty():
			push_warning("unit_debug: no path for unit %d to %s tier %d" % [id, cell, _active_tier])
			continue
		unit.issue_path(wp)


## GROUP FORMATION FLOW order (≥2 selected). Computes N distinct walkable formation
## slots spiralling out from `goal` (Formation.slots) on the active tier, assigns
## each selected unit to a slot minimising total travel (Formation.assign), then
## installs one FlowField (goal = that unit's slot) + FlowFollower per unit as the
## active group order that `_process` drives. Every unit's A* path is first STOPPED
## (`issue_path([])`) so it is controller-driven only and its own `_process` stays
## inert. Any prior group order is retired first. No-op when the active tier has no
## layer or no slots can be placed.
func _issue_group_flow(goal: Vector2i, selected: Array[int]) -> void:
	# Duck-typed layer: read into a typed local for the walkable_query/region calls.
	var layer: TileMapLayer = _map_system.get_elevation_layer(_active_tier)
	if layer == null:
		return
	var walkable: Callable = NavMapBuilder.walkable_query(layer)
	var region: Rect2i = layer.get_used_rect()
	var count: int = selected.size()

	var slot_cells: Array[Vector2i] = Formation.slots(goal, count, walkable, region)
	if slot_cells.is_empty():
		push_warning("unit_debug: no formation slots for goal %s tier %d" % [goal, _active_tier])
		return
	if slot_cells.size() < count:
		# Reachable area smaller than the group: assign() still returns a slot per unit
		# (best-effort, some units may share slot 0). Degraded, not fatal — warn and go.
		push_warning("unit_debug: only %d/%d formation slots around %s" % [slot_cells.size(), count, goal])

	var unit_cells: Array[Vector2i] = []
	for id: int in selected:
		# Duck-typed unit node: keep it UNTYPED (see _units doc).
		var unit = _units[id]
		var ucell: Vector2i = unit.current_cell()
		unit_cells.append(ucell)
	var mapping: PackedInt32Array = Formation.assign(unit_cells, slot_cells)

	# Retire any prior group order before installing this one.
	_clear_group_order()
	_group_tier = _active_tier
	for i in range(count):
		var uid: int = selected[i]
		# Duck-typed unit node: keep it UNTYPED (see _units doc).
		var unit = _units[uid]
		# Stop any live A* path so this unit is driven ONLY by the group order below
		# (its own _process no-ops with no path, so it never fights the follower).
		unit.issue_path([])
		var slot_index: int = mapping[i]
		var slot: Vector2i = slot_cells[slot_index]
		var field: FlowField = FlowField.new(region, walkable, slot)
		var follower: FlowFollower = FlowFollower.new(field, _group_tier)
		var start_cell: Vector2i = unit.current_cell()
		_group_units.append(unit)
		_group_followers.append(follower)
		_group_positions.append(EntityPlacement.visual_position(start_cell, _group_tier))


## Drives the active group-flow order every frame (idle — early-returns — when no
## group order is installed). Mirrors flow_field_harness._process: snapshot every
## unit's PRE-frame lifted position, advance each follower against the OTHER units'
## pre-frame positions (never its own — Steering treats a coincident self as a huge
## push), and write each unit's node origin from the returned lifted position
## stripped of the tier lift. When ALL followers report done, the order is retired
## so this goes idle again.
func _process(delta: float) -> void:
	if _group_followers.is_empty():
		return
	# CoW snapshot: the first write to _group_positions below duplicates the buffer, so
	# `snapshot` stays frozen at this frame's pre-move positions for every neighbour set.
	var snapshot: PackedVector2Array = _group_positions
	var all_done: bool = true
	for i in range(_group_followers.size()):
		var follower: FlowFollower = _group_followers[i]
		var out: Dictionary = follower.advance(snapshot[i], _others(snapshot, i), delta)
		var new_pos: Vector2 = out["pos"]
		_group_positions[i] = new_pos
		# Duck-typed unit node: keep it UNTYPED (see _units doc). drive_to (not a raw
		# position poke) keeps the unit's UnitState live, so click-select / re-order /
		# re-path after this group move read the real cell, not the stale spawn cell.
		var unit = _group_units[i]
		var rcell: Vector2i = out["cell"]
		var rtier: int = out["tier"]
		unit.drive_to(new_pos, rcell, rtier)
		var done: bool = out["done"]
		if not done:
			all_done = false
	if all_done:
		_clear_group_order()


## The positions of every unit EXCEPT `self_index` — the separation neighbour set for
## the unit at `self_index` (a unit must not repel itself). Copied from
## flow_field_harness._others.
func _others(positions: PackedVector2Array, self_index: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in positions.size():
		if i != self_index:
			out.append(positions[i])
	return out


## Retires the active group-flow order (drops all three parallel arrays), so
## `_process` goes idle. Safe when no order is active.
func _clear_group_order() -> void:
	_group_units.clear()
	_group_followers.clear()
	_group_positions = PackedVector2Array()


## Re-drives every unit's highlight from the current selection.
func _refresh_highlights() -> void:
	for id: int in _units:
		# Duck-typed unit node: keep it UNTYPED (see _units doc).
		var unit = _units[id]
		unit.set_selected(_selection.is_selected(id))


## Injects an optional debug OVERRIDE ramp list, overlaid on top of the ramps derived
## from painted ramp tiles in later `NavGraph` rebuilds (#78 B1; harness hook). Passed as
## `NavMapBuilder.from_map_system`'s `extra_ramps` param, so these are appended to — not a
## replacement for — the derived ramps.
func set_ramps(ramps: Array) -> void:
	_ramps = ramps


## Frees every spawned unit and resets the registry and selection. Leaves `_next_id`
## monotonic so freed ids are never reused. Safe when no units exist.
func clear_units() -> void:
	for id: int in _units:
		# Duck-typed unit node: keep it UNTYPED (see _units doc).
		var unit = _units[id]
		if unit != null:
			unit.queue_free()
	_units.clear()
	_selection.clear()
	# Drop any active group-flow order too — it holds refs to the units just freed, so
	# a lingering order would make _process touch freed nodes.
	_clear_group_order()
	_dragging = false
	queue_redraw()
