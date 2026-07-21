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
