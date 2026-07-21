class_name MapSerializer
extends RefCounted
## Serializes painted TileMapLayers into the MapSchema JSON shape. Pure & static:
## it takes live TileMapLayer nodes (or a Dictionary doc) and returns plain data,
## never touching the filesystem -- MapFileIO owns the actual write.
##
## JSON has no Vector2i, so every coordinate flattens to a two-element [x, y]
## array; readers cast the float components back with int(). Every key comes from
## MapSchema so this module carries no string literals of its own.

## Flattens one layer's used cells into an Array of cell objects. Cell order
## follows get_used_cells(), which Godot does not guarantee -- consumers must
## not rely on it.
static func serialize_layer(layer: TileMapLayer) -> Array:
	var cells: Array = []
	for c in layer.get_used_cells():
		var atlas := layer.get_cell_atlas_coords(c)
		cells.append({
			MapSchema.KEY_CELL_POS: [c.x, c.y],
			MapSchema.KEY_CELL_SOURCE: layer.get_cell_source_id(c),
			MapSchema.KEY_CELL_ATLAS: [atlas.x, atlas.y],
			MapSchema.KEY_CELL_ALT: layer.get_cell_alternative_tile(c),
		})
	return cells

## Builds the full root document from parallel layer / name / elevation arrays.
## The three arrays must be the same length; on a mismatch this warns and clamps
## to the shortest to avoid out-of-bounds access.
static func serialize_layers(layers: Array[TileMapLayer], names: Array[String], elevations: Array[int]) -> Dictionary:
	var count := layers.size()
	if not (layers.size() == names.size() and names.size() == elevations.size()):
		push_warning("MapSerializer.serialize_layers: array size mismatch (layers=%d names=%d elevations=%d); clamping." % [layers.size(), names.size(), elevations.size()])
		count = mini(mini(layers.size(), names.size()), elevations.size())

	var doc := {
		MapSchema.KEY_SCHEMA_VERSION: MapSchema.CURRENT_SCHEMA,
		MapSchema.KEY_TILE_SHAPE: MapSchema.TILE_SHAPE_NAME,
		MapSchema.KEY_TILE_SIZE: [MapConstants.TILE_SIZE.x, MapConstants.TILE_SIZE.y],
		MapSchema.KEY_GENERATED_BY: MapSchema.GENERATED_BY_NAME,
		MapSchema.KEY_LAYERS: [],
	}
	for i in count:
		doc[MapSchema.KEY_LAYERS].append({
			MapSchema.KEY_LAYER_NAME: names[i],
			MapSchema.KEY_LAYER_ELEVATION: elevations[i],
			MapSchema.KEY_CELLS: serialize_layer(layers[i]),
		})
	return doc

## Renders a document to a tab-indented, pretty-printed JSON string.
static func to_json(doc: Dictionary) -> String:
	return JSON.stringify(doc, "\t")
