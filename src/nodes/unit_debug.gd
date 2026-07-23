extends Node2D
## Dev-only spawn/target hook (#75/#76): turns raw clicks into a single unit's
## spawn and path commands so movement can be exercised by hand before the real
## selection/order UI (B1) lands.
##
## All gesture logic lives in the pure, Node-free `UnitCommand` state machine —
## this node only wires engine input (mouse buttons, number keys) to it and does
## the work its verdict names: the FIRST click SPAWNs the unit, every later click
## issues a MOVE toward the picked cell. Screen->cell projection reuses
## `IsoCoord.pick_cell_global`, matching `MapEditor` (camera-safe, edge-robust).
##
## The active TIER is an explicit selector (number keys 1/2/3), NOT inferred from
## the click — a debug simplification in the spirit of "grid is guidance": the
## human states which tier they mean rather than the tool guessing from geometry.
##
## Ramps are HAND-FED via `set_ramps` (empty by default) until B1 derives them
## from the map; the harness/injector supplies a `NavRamp` list. The `NavGraph` is
## rebuilt from scratch on every MOVE (`NavMapBuilder.from_map_system`) — the debug
## map is tiny, so a per-order rebuild is cheaper than maintaining incremental
## nav state, and it always reflects the latest painted terrain.
##
## Like `MapEditor` this is a RUNTIME node (not `@tool`), so none of it executes
## during a headless `--import` in CI.

## Path to the MapSystem node this hook spawns units into and pathfinds across.
@export var map_system_path: NodePath

## Hand-fed `NavRamp` list threaded into every `NavGraph` rebuild. Empty by
## default; the harness/injector sets it via `set_ramps` until B1 derives ramps
## from the map.
var _ramps: Array = []

## The resolved MapSystem node. Left UNTYPED on purpose so its
## `get_elevation_layer()` API is duck-typed: MapSystem carries no `class_name`,
## and a static `Node` type would make the 4.4 analyzer reject the call ("not
## found in base Node") and fail the whole script load. Mirrors MapEditor.
var _map_system
## The single spawned unit, or null before the first click. UNTYPED for the same
## duck-typing reason — the Unit node exposes `setup`/`issue_path`/`current_cell`/
## `current_tier` without a `class_name`.
var _unit
## Active tier selector the next click targets (spawn tier / path destination
## tier). Set by number keys 1/2/3, default tier 0.
var _active_tier: int = 0
## Pure gesture state machine deciding SPAWN vs MOVE per click.
var _command := UnitCommand.new()


func _ready() -> void:
	# Defer binding by one step so the parent MapSystem's @onready layers are
	# populated by the time we resolve it — children ready before their parent,
	# and a deferred call runs after the whole tree finishes readying. (Mirrors
	# MapEditor's rationale.)
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
		if button.button_index == MOUSE_BUTTON_LEFT and button.pressed:
			_click_at_mouse()
	elif event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo:
			match key.keycode:
				KEY_1, KEY_2, KEY_3:
					_active_tier = key.keycode - KEY_1


## Projects the mouse to a cell on the active tier's layer, asks the pure command
## core what to do, and does it: SPAWN instances a unit at the cell, MOVE paths the
## existing unit there. No-op when the active tier has no layer.
func _click_at_mouse() -> void:
	var layer: TileMapLayer = _map_system.get_elevation_layer(_active_tier)
	if layer == null:
		return
	var cell: Vector2i = IsoCoord.pick_cell_global(layer, layer.get_global_mouse_position())
	var cmd: Dictionary = _command.on_click(cell, _active_tier)
	var action: int = cmd["action"]
	match action:
		UnitCommand.Action.SPAWN:
			# Assign straight into the UNTYPED _unit member (not a typed local): a
			# `var unit := ...instantiate()` would infer the static `Node` type and the
			# 4.4 analyzer would then reject `unit.setup()` as "not found in base Node",
			# failing script load. Duck-typing through _unit mirrors MapEditor._map_system.
			_unit = preload("res://src/nodes/unit.tscn").instantiate()
			# Add under this node first so it is in-tree; setup() reparents it into
			# the MapSystem's tier entity container.
			add_child(_unit)
			_unit.setup(_map_system, cell, _active_tier)
		UnitCommand.Action.MOVE:
			var nav: NavGraph = NavMapBuilder.from_map_system(_map_system, _ramps)
			var wp: Array = nav.find_path(_unit.current_cell(), _unit.current_tier(), cell, _active_tier)
			if wp.is_empty():
				push_warning("unit_debug: no path to %s tier %d" % [cell, _active_tier])
				return
			_unit.issue_path(wp)


## Injects the hand-fed ramp list used by later `NavGraph` rebuilds (harness hook).
func set_ramps(ramps: Array) -> void:
	_ramps = ramps


## Frees the current unit and resets the command core so the next click spawns
## again. Safe when no unit exists.
func despawn() -> void:
	if _unit != null:
		_unit.queue_free()
		_unit = null
	_command.on_despawn()
