extends Node2D
## Root of the stackable isometric map. Holds one TileMapLayer per elevation
## tier plus an Objects layer. TileSets are assigned later (Story #3); this
## script only exposes the layer structure to the rest of the systems.

@onready var elevation_layers: Array[TileMapLayer] = [
	$Elevation0,
	$Elevation1,
	$Elevation2,
]
@onready var objects_layer: TileMapLayer = $Objects

## Returns the TileMapLayer for an elevation tier, or null if out of range.
func get_elevation_layer(level: int) -> TileMapLayer:
	if level < 0 or level >= elevation_layers.size():
		return null
	return elevation_layers[level]
