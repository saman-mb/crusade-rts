extends Node2D
## In-game brush editor: translates mouse input into `BrushCore` decisions that
## are applied to the active elevation `TileMapLayer` of a `MapSystem`.
##
## All decision logic lives in the pure, Node-free `BrushCore` library; this node
## only wires engine input (mouse buttons, motion, keys) and layer state to those
## static calls and applies the returned action. Left-drag paints, right-drag
## erases, `[`/`]` cycle the active elevation, and number keys jump to a tier.
##
## Screen->cell projection reuses `IsoCoord.pick_cell_global`, which is
## camera-safe (works through any Camera2D transform via `to_local`) and
## edge-robust: it picks the diamond whose center is nearest rather than relying
## on `TileMapLayer.local_to_map`, sidestepping godot issue #89423.
##
## This is a RUNTIME editor (not `@tool`), so none of this executes during a
## headless `--import` in CI.

## Path to the MapSystem node whose elevation layers this editor paints.
@export_group("Target")
@export var map_system_path: NodePath
## Optional terrain atlas texture; if null, `_ready` loads the committed default
## at res://assets/tilesets/terrain_atlas.png.
@export var terrain_atlas: Texture2D

## The resolved MapSystem node. Left UNTYPED on purpose so its
## `get_elevation_layer()` / `elevation_layers` API is duck-typed: MapSystem
## carries no `class_name`, and a static `Node` type would make the 4.4 analyzer
## reject those calls ("not found in base Node") and fail the whole script load.
var _map_system
## Active elevation tier index the brush writes to.
var _active_level: int = 0
## The TileMapLayer for `_active_level` (null when out of range / no map).
var _active_layer: TileMapLayer
## Atlas source id of the built terrain TileSet.
var _source_id: int = -1
## Default terrain atlas coord to paint: the fully-filled dual-grid mask (15)
## cell Vector2i(3, 3), a real tile created by TileSetBuilder.
var _atlas_coords: Vector2i = Vector2i(3, 3)
## Translucent ghost layer that previews the cell under the cursor.
@onready var _preview: TileMapLayer = $Preview
## Cell currently holding the preview tile.
var _preview_cell: Vector2i = Vector2i(0, 0)
## True when `_preview` currently holds a ghost tile to be cleared.
var _has_preview: bool = false
## True while a left-mouse paint drag is active.
var _painting: bool = false
## True while a right-mouse erase drag is active.
var _erasing: bool = false


func _ready() -> void:
	# Defer binding by one step: our parent MapSystem fills its @onready
	# `elevation_layers` only when ITS `_ready` runs, and because children are
	# readied BEFORE their parent, that happens after this node's `_ready`.
	# A deferred call runs after the whole tree has finished readying, so the
	# map's layers are populated by the time we query them.
	_setup.call_deferred()


func _setup() -> void:
	_map_system = get_node_or_null(map_system_path)
	if _map_system == null:
		push_warning("map_editor: map_system_path unresolved; editor is inert.")
		return

	var tex := (terrain_atlas if terrain_atlas != null else load("res://assets/tilesets/terrain_atlas.png")) as Texture2D
	if tex == null:
		push_warning("map_editor: terrain_atlas.png not found; editor is inert.")
		return

	# Build the TileSet once and share it across every elevation layer that lacks
	# one plus the preview layer, so all paint/ghost cells resolve identically.
	var ts := TileSetBuilder.build_terrain_tileset(tex)
	for i in _layer_count():
		var layer := _map_system.get_elevation_layer(i) as TileMapLayer
		if layer != null and layer.tile_set == null:
			layer.tile_set = ts
	_preview.tile_set = ts

	_source_id = ts.get_source_id(0)

	# Translucent ghost; explicit LINEAR filter matches the HD art and avoids the
	# blurry-nearest ghost artefact of godot issue #52332.
	_preview.modulate = Color(1, 1, 1, 0.5)
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

	_set_active_level(0)


## Selects the active elevation tier (clamped to the available layers), rebinds
## the active layer, and lifts the preview to that tier's elevation offset.
func _set_active_level(level: int) -> void:
	_active_level = BrushCore.clamp_level(level, _layer_count())
	_active_layer = _map_system.get_elevation_layer(_active_level) as TileMapLayer
	_preview.position = MapConstants.elevation_offset(_active_level)
	if _active_layer == null:
		return


## Counts the contiguous non-null elevation layers from level 0 (probe capped).
func _layer_count() -> int:
	var count := 0
	for i in range(16):
		if _map_system.get_elevation_layer(i) == null:
			break
		count += 1
	return count


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		match button.button_index:
			MOUSE_BUTTON_LEFT:
				_painting = button.pressed
				if button.pressed:
					_apply_at_mouse(BrushCore.Mode.PAINT)
			MOUSE_BUTTON_RIGHT:
				_erasing = button.pressed
				if button.pressed:
					_apply_at_mouse(BrushCore.Mode.ERASE)
	elif event is InputEventMouseMotion:
		_update_preview()
		if _painting:
			_apply_at_mouse(BrushCore.Mode.PAINT)
		elif _erasing:
			_apply_at_mouse(BrushCore.Mode.ERASE)
	elif event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo:
			match key.keycode:
				KEY_BRACKETLEFT:
					_set_active_level(BrushCore.cycle_level(_active_level, -1, _layer_count()))
				KEY_BRACKETRIGHT:
					_set_active_level(BrushCore.cycle_level(_active_level, 1, _layer_count()))
				KEY_1, KEY_2, KEY_3:
					var target := key.keycode - KEY_1
					if target < _layer_count():
						_set_active_level(target)


## Projects the mouse to a cell and applies the pure BrushCore decision to the
## active layer. No-op through UI, without an active layer, or on Action.NONE.
func _apply_at_mouse(mode: BrushCore.Mode) -> void:
	if _active_layer == null or get_viewport().gui_get_hovered_control() != null:
		return
	var cell := IsoCoord.pick_cell_global(_active_layer, get_global_mouse_position())
	var cur_src := _active_layer.get_cell_source_id(cell)
	var cur_atlas := _active_layer.get_cell_atlas_coords(cell)
	var r := BrushCore.resolve(mode, cur_src, cur_atlas, _source_id, _atlas_coords)
	match r["action"]:
		BrushCore.Action.WRITE:
			_active_layer.set_cell(cell, r["source_id"], r["atlas_coords"])
		BrushCore.Action.CLEAR:
			_active_layer.erase_cell(cell)
		BrushCore.Action.NONE:
			pass
	# NOTE: nav/physics consumers would want a single batched `update_internals()`
	# after a paint stroke ends; per-cell drag painting does not need it here.


## Moves the translucent ghost to the cell under the cursor, clearing it when the
## cursor is over UI or there is no active layer, and skipping redundant churn.
func _update_preview() -> void:
	if _active_layer == null or get_viewport().gui_get_hovered_control() != null:
		if _has_preview:
			_preview.erase_cell(_preview_cell)
			_has_preview = false
		return
	var cell := IsoCoord.pick_cell_global(_active_layer, get_global_mouse_position())
	if _has_preview and cell == _preview_cell:
		return
	if _has_preview:
		_preview.erase_cell(_preview_cell)
	_preview.set_cell(cell, _source_id, _atlas_coords)
	_preview_cell = cell
	_has_preview = true
