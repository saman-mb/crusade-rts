@tool
extends Node2D
## Root of the stackable isometric map. Holds one TileMapLayer per elevation
## tier plus an Objects layer. TileSets are assigned later (Story #3).
## The per-layer elevation offset is DERIVED from MapConstants so that
## ELEVATION_STEP_PX remains the single source of truth (the scene literals
## are just cached defaults; this script re-derives and auto-corrects them,
## in the editor too via @tool, if the constant ever changes).

@onready var elevation_layers: Array[TileMapLayer] = [
	$Elevation0,
	$Elevation1,
	$Elevation2,
]
@onready var objects_layer: TileMapLayer = $Objects

func _ready() -> void:
	_apply_elevation_offsets()
	_demo_paint_pond()

## Positions each elevation layer from MapConstants and sets a matching
## y_sort_origin so the layer sorts at its true (unlifted) world depth.
func _apply_elevation_offsets() -> void:
	for level in elevation_layers.size():
		var layer := elevation_layers[level]
		var pos := MapConstants.elevation_offset(level)
		var origin := MapConstants.ELEVATION_STEP_PX * level
		if layer.position != pos:
			layer.position = pos
		if layer.y_sort_origin != origin:
			layer.y_sort_origin = origin

## Returns the TileMapLayer for an elevation tier, or null if out of range.
func get_elevation_layer(level: int) -> TileMapLayer:
	if level < 0 or level >= elevation_layers.size():
		return null
	return elevation_layers[level]

## DEMO / PLACEHOLDER (Story #3): proves the whole TileSet + dual-grid stack end
## to end by building the terrain TileSet from the committed atlas and painting a
## small autotiled pond onto Elevation0. Remove once the real editor (Story #4)
## drives painting. Runtime-only: guarded out of the @tool editor path and any
## headless CI import so it writes nothing there and never crashes on a missing
## asset. Additive -- does not touch existing map_system behaviour.
func _demo_paint_pond() -> void:
	if Engine.is_editor_hint():
		return
	var tex := load("res://assets/tilesets/terrain_atlas.png")
	if tex == null:
		push_warning("map_system demo: terrain_atlas.png not found; skipping pond.")
		return
	var ts := TileSetBuilder.build_terrain_tileset(tex)
	var layer := elevation_layers[0]
	layer.tile_set = ts
	var source_id := ts.get_source_id(0)

	# "Pond": a handful of filled logical cells. The dual-grid autotiler reads
	# these to pick clean-edged atlas tiles for the surrounding display cells.
	var pond_cells := {
		Vector2i(1, 1): true, Vector2i(2, 1): true, Vector2i(3, 1): true,
		Vector2i(1, 2): true, Vector2i(2, 2): true, Vector2i(3, 2): true,
		Vector2i(2, 3): true,
	}
	var is_filled := func(c: Vector2i) -> bool:
		return pond_cells.has(c)

	# Iterate the display cells straddling the pond (one ring wider than the
	# filled region so the outer edge tiles resolve), skipping the empty sentinel.
	for dy in range(1, 5):
		for dx in range(1, 5):
			var dcell := Vector2i(dx, dy)
			var atlas_coord := DualGrid.tile_for_display(dcell, is_filled)
			if atlas_coord == DualGrid.SENTINEL:
				continue
			layer.set_cell(dcell, source_id, atlas_coord)
