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
		var alt := layer.get_cell_alternative_tile(c)
		# Normalize positional mega-tile windows back to the canonical painted
		# tiles (interior grass / animated water, alt 0). Saved documents stay
		# independent of the visual window scheme and readable by older builds;
		# the load-time TerrainVariation pass re-derives the windows by position.
		if TileSetConstants.is_grass_window_coord(atlas):
			atlas = TileSetConstants.interior_grass_coord()
			alt = 0
		elif TileSetConstants.is_water_window_coord(atlas):
			atlas = TileSetConstants.WATER_ANIM_COORDS
			alt = 0
		cells.append({
			MapSchema.KEY_CELL_POS: [c.x, c.y],
			MapSchema.KEY_CELL_SOURCE: layer.get_cell_source_id(c),
			MapSchema.KEY_CELL_ATLAS: [atlas.x, atlas.y],
			MapSchema.KEY_CELL_ALT: alt,
		})
	return cells

## A fresh root document with the schema/metadata header and an empty layers list.
static func _new_root() -> Dictionary:
	return {
		MapSchema.KEY_SCHEMA_VERSION: MapSchema.CURRENT_SCHEMA,
		MapSchema.KEY_TILE_SHAPE: MapSchema.TILE_SHAPE_NAME,
		MapSchema.KEY_TILE_SIZE: [MapConstants.TILE_SIZE.x, MapConstants.TILE_SIZE.y],
		MapSchema.KEY_GENERATED_BY: MapSchema.GENERATED_BY_NAME,
		MapSchema.KEY_LAYERS: [],
	}

## One layer entry: name + elevation + kind + serialized cells.
static func _layer_entry(layer: TileMapLayer, name: String, elevation: int, kind: String) -> Dictionary:
	return {
		MapSchema.KEY_LAYER_NAME: name,
		MapSchema.KEY_LAYER_ELEVATION: elevation,
		MapSchema.KEY_LAYER_KIND: kind,
		MapSchema.KEY_CELLS: serialize_layer(layer),
	}

## Builds the full root document from parallel layer / name / elevation arrays.
## The three arrays must be the same length; on a mismatch this warns and clamps
## to the shortest to avoid out-of-bounds access. Entries are tagged as terrain.
static func serialize_layers(layers: Array[TileMapLayer], names: Array[String], elevations: Array[int]) -> Dictionary:
	var count := layers.size()
	if not (layers.size() == names.size() and names.size() == elevations.size()):
		push_warning("MapSerializer.serialize_layers: array size mismatch (layers=%d names=%d elevations=%d); clamping." % [layers.size(), names.size(), elevations.size()])
		count = mini(mini(layers.size(), names.size()), elevations.size())

	var doc := _new_root()
	for i in count:
		doc[MapSchema.KEY_LAYERS].append(
			_layer_entry(layers[i], names[i], elevations[i], MapSchema.LAYER_KIND_TERRAIN))
	return doc

## Builds the full document from the elevation stack PLUS the single objects
## overlay (#43). Terrain layers are kind=terrain keyed by their elevation index;
## the objects layer is kind=objects at the OBJECTS_ELEVATION sentinel so the
## loader routes it to the object overlay, never an elevation slot. A null
## objects_layer is simply omitted (terrain-only document).
static func serialize_map(elevation_layers: Array[TileMapLayer], objects_layer: TileMapLayer) -> Dictionary:
	var doc := _new_root()
	for i in elevation_layers.size():
		doc[MapSchema.KEY_LAYERS].append(
			_layer_entry(elevation_layers[i], "elevation_%d" % i, i, MapSchema.LAYER_KIND_TERRAIN))
	if objects_layer != null:
		doc[MapSchema.KEY_LAYERS].append(
			_layer_entry(objects_layer, MapSchema.LAYER_NAME_OBJECTS, MapSchema.OBJECTS_ELEVATION, MapSchema.LAYER_KIND_OBJECTS))
	return doc

## Renders a document to a tab-indented, pretty-printed JSON string.
static func to_json(doc: Dictionary) -> String:
	return JSON.stringify(doc, "\t")
