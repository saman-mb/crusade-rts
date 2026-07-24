class_name MapEditor
extends Node2D
## In-game brush editor: translates mouse input into `BrushCore` decisions that
## are applied to the active elevation `TileMapLayer` of a `MapSystem`.
##
## All decision logic lives in the pure, Node-free `BrushCore` library; this node
## only wires engine input (mouse buttons, motion, keys) and layer state to those
## static calls and applies the returned action. Left-drag paints, right-drag
## erases, `[`/`]` cycle the active elevation, and number keys jump to a tier.
##
## Tool state machine (`ToolState`): B = paint, I = eyedropper (sample tile under
## cursor into the brush), G = bucket (flood-fill the seed's region). Edits are
## undoable via an `UndoRedo`: Ctrl+Z undoes, Ctrl+Y / Ctrl+Shift+Z redoes. Each
## stroke commits ONCE per press->release (paint/erase drags accumulate into one
## composite action through `StrokeRecorder`); a bucket fill is one one-shot action.
## Strokes are applied LIVE during the drag, so commits use execute=false.
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

## Max undo steps retained; the oldest strokes drop once the cap is exceeded.
const UNDO_HISTORY := 64
## Cells the bucket-fill bounds extend beyond the layer's used rect, so a fill can
## spill into adjacent empty space by a margin rather than clamping to painted tiles.
const FILL_MARGIN := 4
## Hard cap on a single bucket-fill region size -- a safety valve against runaway fills.
const FILL_MAX_CELLS := 4096
## Corner mask of the fully-filled dual-grid tile (TL|TR|BL|BR = 1|2|4|8 = 15). Its
## `TileSetConstants.LOOKUP` entry -- Vector2i(3, 3) -- is the editor's default brush.
const FILLED_TILE_MASK := 15
## Shared terrain tint shader (#233): smooth low-frequency world-space colour
## variation applied to every elevation layer. A missing shader degrades to untinted.
const TERRAIN_TINT_SHADER := "res://assets/shaders/terrain_tint.gdshader"

## The resolved MapSystem node. Typed via class_name (#105): its
## `get_elevation_layer()` / `tier_count()` / `elevation_layers` API resolves
## statically on the MapSystem type.
var _map_system: MapSystem
## Active elevation tier index the brush writes to.
var _active_level: int = 0
## The TileMapLayer for `_active_level` (null when out of range / no map).
var _active_layer: TileMapLayer
## Atlas source id of the built terrain TileSet.
var _source_id: int = -1
## Default terrain atlas coord to paint: the fully-filled dual-grid mask's tile,
## sourced from the single-source-of-truth LOOKUP table (== Vector2i(3, 3)) rather
## than duplicating the literal here.
var _atlas_coords: Vector2i = TileSetConstants.LOOKUP[FILLED_TILE_MASK]
## Alternative-tile index the brush paints (#109). 0 is the base tile; the eyedropper
## samples this off a cell, and it round-trips through StrokeRecorder so undo restores it.
var _alt: int = 0
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
## Undo/redo history. One stroke = one press->release = one composite action, so a
## single Ctrl+Z reverts a whole paint drag, erase drag, or bucket fill at once.
var _undo := UndoRedo.new()
## Active editor tool state machine (B paint / I eyedropper / G bucket).
var _tool := ToolState.new()
## Stroke accumulating the current LMB paint / RMB erase drag; null between strokes.
## Created fresh on press, committed and cleared on release. `_apply_at_mouse`
## records into it when non-null.
var _stroke: StrokeRecorder
## When false, the brush ignores all input (Play mode / menu open). The DevMenu flips this.
var editing_enabled: bool = true


func _ready() -> void:
	# Defer binding by one step: our parent MapSystem fills its @onready
	# `elevation_layers` only when ITS `_ready` runs, and because children are
	# readied BEFORE their parent, that happens after this node's `_ready`.
	# A deferred call runs after the whole tree has finished readying, so the
	# map's layers are populated by the time we query them.
	_setup.call_deferred()


func _setup() -> void:
	_undo.set_max_steps(UNDO_HISTORY)
	_map_system = get_node_or_null(map_system_path) as MapSystem
	if _map_system == null:
		push_warning("map_editor: map_system_path unresolved; editor is inert.")
		return

	var tex := (terrain_atlas if terrain_atlas != null else load(TileSetConstants.ATLAS_PATH)) as Texture2D
	if tex == null:
		push_warning("map_editor: terrain_atlas.png not found; editor is inert.")
		return

	# Pair the diffuse atlas with the L1 normal map so the terrain catches
	# directional light from the sun (#84). A missing normal degrades to unlit.
	var normal := load(TileSetConstants.NORMAL_ATLAS_PATH) as Texture2D

	# Build the TileSet once and share it across every elevation layer that lacks
	# one plus the preview layer, so all paint/ghost cells resolve identically.
	# Each elevation layer also gets the shared terrain tint material (#233) -- a
	# low-frequency world-space noise that gives the ground smooth meadow-like
	# colour variation with no tile boundary (the preview ghost stays untinted).
	var ts := TileSetBuilder.build_terrain_tileset(tex, normal)
	var tint_mat := _make_terrain_tint_material()
	for i in _layer_count():
		var layer := _map_system.get_elevation_layer(i) as TileMapLayer
		if layer == null:
			continue
		if layer.tile_set == null:
			layer.tile_set = ts
		if tint_mat != null and layer.material == null:
			layer.material = tint_mat
	_preview.tile_set = ts

	_source_id = ts.get_source_id(0)

	# The ghost's translucency (modulate alpha 0.5) and explicit LINEAR texture_filter
	# -- which matches the HD art and avoids the blurry-nearest ghost artefact of godot
	# issue #52332 -- live on map_editor.tscn's Preview node, the single home for that
	# config (it was previously duplicated here).

	_set_active_level(0)


## Builds the shared terrain tint ShaderMaterial (#233) from the committed shader,
## or null if the shader is missing (callers then leave the layers untinted). One
## material instance is shared across every elevation layer -- the noise is sampled
## in world space, so a single shared material tints the whole map coherently.
func _make_terrain_tint_material() -> ShaderMaterial:
	var shader := load(TERRAIN_TINT_SHADER) as Shader
	if shader == null:
		return null
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat


## Re-binds a swapped-in TileSet: assigns it to every elevation layer + the preview
## and re-derives the cached source id, so the brush and hover ghost stay valid after
## the DevMenu switches tilesets live (Story #6).
func rebind_tileset(ts: TileSet) -> void:
	if ts == null:
		return
	for i in _layer_count():
		var layer := _map_system.get_elevation_layer(i) as TileMapLayer
		if layer != null:
			layer.tile_set = ts
	if _preview != null:
		_preview.tile_set = ts
	_source_id = ts.get_source_id(0)
	# The new TileSet may not have a tile at the current brush atlas coord (e.g. swapping
	# to the DevMenu "Debug (grid)" set, which has a single tile at (0,0), while the brush
	# still points at (3,3)) -- painting that would write invalid cells (#101). Validate the
	# brush against the new source and, if it is now missing, reset to that source's first tile.
	if _source_id != -1:
		var src: TileSetAtlasSource = ts.get_source(_source_id) as TileSetAtlasSource
		if src != null and not src.has_tile(_atlas_coords):
			if src.get_tiles_count() > 0:
				var first: Vector2i = src.get_tile_id(0)
				_atlas_coords = first
				_alt = 0
	# Re-project the hover ghost so it reflects the (possibly reset) brush + new tileset.
	_update_preview()


## Selects the active elevation tier (clamped to the available layers), rebinds
## the active layer, and lifts the preview to that tier's elevation offset.
func _set_active_level(level: int) -> void:
	_active_level = BrushCore.clamp_level(level, _layer_count())
	_active_layer = _map_system.get_elevation_layer(_active_level) as TileMapLayer
	_preview.position = MapConstants.elevation_offset(_active_level)


## The number of elevation tiers, sourced from MapSystem.tier_count() (#105 --
## the single source of truth for layer discovery). Returns 0 when the editor is
## inert (`_map_system` unresolved), so every caller -- including
## rebind_tileset()'s layer loop -- stays null-safe.
func _layer_count() -> int:
	if _map_system == null:
		return 0
	return _map_system.tier_count()


func _unhandled_input(event: InputEvent) -> void:
	if not editing_enabled:
		return
	# Inert editor (map_system_path unresolved): the mouse handlers already no-op on a
	# null _active_layer, but the key handlers reach _layer_count()/_set_active_level(),
	# which dereference _map_system -- so bail here to keep those paths crash-safe. (#35)
	if _map_system == null:
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		match button.button_index:
			MOUSE_BUTTON_LEFT:
				if button.pressed:
					# Ignore a chorded LMB press while an RMB erase drag is live: a
					# fresh stroke would orphan the erase's cells (no undo entry).
					if _erasing:
						return
					# Dispatch via the tested ToolState predicates (single source of
					# truth) rather than re-deriving per-tool behavior inline: PAINT is
					# the only stroke tool; BUCKET is the other mutating tool (a one-shot
					# fill); EYEDROPPER is the read-only remainder. (#55)
					if _tool.creates_stroke():
						_stroke = StrokeRecorder.new()
						_painting = true
						_apply_at_mouse(BrushCore.Mode.PAINT)  # records the first cell
					elif _tool.is_mutating():
						_bucket_fill_at_mouse()
					else:
						_eyedrop_at_mouse()
				else:
					_end_stroke("Paint", _painting)
					_painting = false
			MOUSE_BUTTON_RIGHT:
				if button.pressed:
					# Symmetric guard: don't start an erase mid paint-drag (would
					# discard the live paint stroke, leaving un-undoable tiles).
					if _painting:
						return
					# Erase mirrors paint: record the live drag, commit as one action.
					_stroke = StrokeRecorder.new()
					_erasing = true
					_apply_at_mouse(BrushCore.Mode.ERASE)
				else:
					_end_stroke("Erase", _erasing)
					_erasing = false
	elif event is InputEventMouseMotion:
		_update_preview()
		if _painting:
			_apply_at_mouse(BrushCore.Mode.PAINT)
		elif _erasing:
			_apply_at_mouse(BrushCore.Mode.ERASE)
	elif event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo:
			# Undo / redo -- raw keycode combos, matching the [/] house style (not
			# project.godot actions). Refresh the ghost after history moves the map.
			if key.ctrl_pressed and key.keycode == KEY_Z and not key.shift_pressed:
				if _undo.has_undo():
					_undo.undo()
					# History move mutated the map -- announce it through the hub (#95).
					# The reverted cells/tier aren't tracked, so emit a whole-map change.
					if _map_system != null:
						_map_system.emit_map_changed_all()
				_update_preview()
				return
			if (key.ctrl_pressed and key.keycode == KEY_Y) or (key.ctrl_pressed and key.shift_pressed and key.keycode == KEY_Z):
				if _undo.has_redo():
					_undo.redo()
					if _map_system != null:
						_map_system.emit_map_changed_all()
				_update_preview()
				return
			# Tool select (B/I/G). from_keycode returns -1 for [/]/1-3, so those fall
			# through to the layer handling below untouched.
			var t := ToolState.from_keycode(key.keycode)
			if t != -1:
				_tool.select(t)
				_update_preview()
				return
			# A stroke records no per-cell layer, so switching elevation mid-drag would
			# split one undo action across layers (old-layer cells never revert). Lock
			# the layer while a paint/erase drag is live; the keys resume on release.
			if _painting or _erasing:
				return
			match key.keycode:
				KEY_BRACKETLEFT:
					_set_active_level(BrushCore.cycle_level(_active_level, -1, _layer_count()))
				KEY_BRACKETRIGHT:
					_set_active_level(BrushCore.cycle_level(_active_level, 1, _layer_count()))
				_:
					# Number keys 1..9 jump straight to tier 0..8, bounded by the live
					# tier count (#106) so the hotkeys track tier_count() rather than a
					# hardcoded KEY_1..KEY_3.
					if key.keycode >= KEY_1 and key.keycode <= KEY_9:
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
	# Capture the cell's alternative_tile too (#109): it round-trips on disk, so undo must
	# restore it. get_cell_alternative_tile returns int -- annotate to stay warnings-clean.
	var cur_alt: int = _active_layer.get_cell_alternative_tile(cell)
	var r := BrushCore.resolve(mode, cur_src, cur_atlas, _source_id, _atlas_coords)
	# When a stroke is active, record before/after per changed cell so the whole drag
	# commits as ONE undo action. StrokeRecorder drops net no-ops, so NONE is skipped.
	match r["action"]:
		BrushCore.Action.WRITE:
			if _stroke != null:
				_stroke.record(cell, cur_src, cur_atlas, cur_alt, r["source_id"], r["atlas_coords"], _alt)
			_active_layer.set_cell(cell, r["source_id"], r["atlas_coords"], _alt)
		BrushCore.Action.CLEAR:
			if _stroke != null:
				_stroke.record(cell, cur_src, cur_atlas, cur_alt, -1, Vector2i(-1, -1), 0)
			_active_layer.erase_cell(cell)
		BrushCore.Action.NONE:
			pass
	# NOTE: nav/physics consumers would want a single batched `update_internals()`
	# after a paint stroke ends; per-cell drag painting does not need it here.


## Commits the just-finished drag stroke (paint or erase) as ONE undo action and clears
## it. `active` is the drag flag captured before it is reset; a null/empty stroke commits
## nothing (StrokeRecorder makes no action for a net-zero stroke).
## ASSUMED PEER API: StrokeRecorder.commit(ur, action_name, sink) commits with
## execute=false (stroke already applied live during the drag). SDET: verify signature.
func _end_stroke(action_name: String, active: bool) -> void:
	if active and _stroke != null and not _stroke.is_empty():
		var changes := _stroke.changes()
		_stroke.commit(_undo, action_name, Callable(_active_layer, "set_cell"))
		# Announce the mutation on the active tier through the MapSystem hub (#95).
		_emit_map_changed(MapChange.bounds_of_changes(changes), _active_level)
	_stroke = null


## Emits `map_changed` on the MapSystem hub for a single-tier edit (#95): `rect` is
## the affected cells' bounding box, `tier` the elevation level that changed. No-op
## when the editor is inert (`_map_system` unresolved).
func _emit_map_changed(rect: Rect2i, tier: int) -> void:
	if _map_system == null:
		return
	var tiers: Array[int] = [tier]
	_map_system.map_changed.emit(rect, tiers)


## EYEDROPPER: samples the tile under the cursor from the ACTIVE elevation layer into the
## brush (source id + atlas coords) and refreshes the ghost. Reads only; no stroke, no undo
## entry, no drag. Empty cells (source -1) are ignored so the brush keeps a paintable tile.
func _eyedrop_at_mouse() -> void:
	if _active_layer == null or get_viewport().gui_get_hovered_control() != null:
		return
	var cell := IsoCoord.pick_cell_global(_active_layer, get_global_mouse_position())
	var s := _active_layer.get_cell_source_id(cell)
	var a := _active_layer.get_cell_atlas_coords(cell)
	# Sample the alternative_tile too (#109) so painting re-lays the exact tile variant.
	var alt: int = _active_layer.get_cell_alternative_tile(cell)
	if s != -1:
		_source_id = s
		_atlas_coords = a
		_alt = alt
		_update_preview()


## BUCKET: flood-fills the seed cell's contiguous same-identity region on the active layer
## with the brush tile, applied live and committed as ONE "Bucket Fill" undo action. One-shot
## (no drag flag). FloodFill is pure -- the injected read/neighbors lambdas wrap the live layer.
func _bucket_fill_at_mouse() -> void:
	if _active_layer == null or get_viewport().gui_get_hovered_control() != null:
		return
	var seed := IsoCoord.pick_cell_global(_active_layer, get_global_mouse_position())
	var match_src := _active_layer.get_cell_source_id(seed)
	var match_atlas := _active_layer.get_cell_atlas_coords(seed)
	# Bound the otherwise-infinite layer: the used rect grown by a margin so a fill can
	# spill a little into surrounding empty space without running forever.
	var bounds := _active_layer.get_used_rect().grow(FILL_MARGIN)
	var read := func(c: Vector2i) -> Dictionary:
		return { "src": _active_layer.get_cell_source_id(c), "atlas": _active_layer.get_cell_atlas_coords(c) }
	var neighbors := func(c: Vector2i) -> Array[Vector2i]:
		return _active_layer.get_surrounding_cells(c)
	var cells := FloodFill.compute(seed, match_src, match_atlas, bounds, read, neighbors, FILL_MAX_CELLS)
	# All fill cells share the seed identity; StrokeRecorder drops cells that don't net-change
	# (e.g. filling onto the identical brush tile), so this commits nothing when it's a no-op.
	var stroke := StrokeRecorder.new()
	for cell in cells:
		# Cells share the seed's src+atlas identity (FloodFill matches on those), but their
		# alternative_tile can differ, so read each cell's alt for a faithful undo (#109).
		var before_alt: int = _active_layer.get_cell_alternative_tile(cell)
		stroke.record(cell, match_src, match_atlas, before_alt, _source_id, _atlas_coords, _alt)
		_active_layer.set_cell(cell, _source_id, _atlas_coords, _alt)
	if not stroke.is_empty():
		var changes := stroke.changes()
		stroke.commit(_undo, "Bucket Fill", Callable(_active_layer, "set_cell"))
		# Announce the fill on the active tier through the MapSystem hub (#95).
		_emit_map_changed(MapChange.bounds_of_changes(changes), _active_level)
	_update_preview()


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
	_preview.set_cell(cell, _source_id, _atlas_coords, _alt)
	_preview_cell = cell
	_has_preview = true
