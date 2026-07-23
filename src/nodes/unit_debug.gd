extends Node2D
## Dev-only select/move/spawn hook (#77): turns raw engine input into proper RTS
## controls over a registry of spawned units, so movement and multi-unit orders can
## be exercised by hand before the real order UI (B1) lands.
##
## Controls:
##   LEFT-click  — select the unit under the cursor on the active tier; an empty
##                 cell clears the selection.
##   RIGHT-click — issue a MOVE: path every selected unit to the picked cell/tier.
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
		if button.pressed:
			if button.button_index == MOUSE_BUTTON_LEFT:
				_select_at_mouse()
			elif button.button_index == MOUSE_BUTTON_RIGHT:
				_move_at_mouse()
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


## Issues a MOVE to every selected unit: rebuilds the nav graph and paths each unit
## from its current cell/tier to the picked cell on the active tier. Units with no
## route are skipped with a warning. No-op when the active tier has no layer.
func _move_at_mouse() -> void:
	var cell: Vector2i = _pick_cell()
	if cell == NO_CELL:
		return
	var nav: NavGraph = NavMapBuilder.from_map_system(_map_system, _ramps)
	for id in _selection.selected_ids():
		# Duck-typed unit node: keep it UNTYPED (see _units doc).
		var unit = _units[id]
		var wp: Array = nav.find_path(unit.current_cell(), unit.current_tier(), cell, _active_tier)
		if wp.is_empty():
			push_warning("unit_debug: no path for unit %d to %s tier %d" % [id, cell, _active_tier])
			continue
		unit.issue_path(wp)


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
