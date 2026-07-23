class_name NavMapBuilder
extends RefCounted
## Thin runtime adapter: turns a stack of live elevation TileMapLayers into a
## headless NavGraph. ALL pathfinding logic lives in the cores (NavGraph /
## NavTierGrid / NavPortalGraph) -- this file only reads the live TileSet API
## (get_used_rect / get_cell_source_id) and wires the pieces together. A tile is
## walkable on a tier iff that tier's layer paints a real tile there
## (source_id != -1 == BrushCore.EMPTY_SOURCE_ID == no tile == hole/cliff).

## Union of every layer's get_used_rect(). Nulls and cell-less layers are
## skipped (a painted-nothing layer reports a 0-size rect that would wrongly
## drag the origin (0,0) into the union). All-empty -> a 0-size Rect2i().
static func compute_region(layers: Array) -> Rect2i:
	var region := Rect2i()
	var seeded := false
	for layer in layers:
		if layer == null:
			continue
		if layer.get_used_cells().is_empty():
			continue
		var used: Rect2i = layer.get_used_rect()
		if not seeded:
			region = used
			seeded = true
		else:
			region = region.merge(used)
	return region

## A (cell -> bool) walkability probe closed over one layer: true iff a tile is
## painted at `cell` AND that tile's `walkable` custom-data (TileSetConstants.
## WALKABLE_LAYER) is true. An empty cell -- a hole/cliff -- is never walkable
## (preserves the old get_cell_source_id == -1 contract). A layer whose TileSet
## carries no `walkable` layer treats any painted tile as walkable, so minimal
## test tilesets (no custom-data) still navigate. Null-safe: a null layer answers
## false everywhere. Shape matches NavTierGrid's `walkable` arg. The layer-presence
## lookup is resolved ONCE outside the closure so every probe stays O(1).
static func walkable_query(layer) -> Callable:
	if layer == null:
		return func(_cell: Vector2i) -> bool: return false
	var ts: TileSet = layer.tile_set
	var has_layer: bool = ts != null and ts.get_custom_data_layer_by_name(TileSetConstants.WALKABLE_LAYER) != -1
	return func(cell: Vector2i) -> bool:
		var data: TileData = layer.get_cell_tile_data(cell)
		if data == null:            # empty cell / hole / cliff -> not walkable (preserves the old get_cell_source_id==-1 contract)
			return false
		if not has_layer:           # tileset carries no semantics -> painted tile == walkable (back-compat with minimal test tilesets)
			return true
		var value: Variant = data.get_custom_data(TileSetConstants.WALKABLE_LAYER)
		return bool(value)

## Builds a NavGraph from the layer stack: region = layer union grown to include
## every ramp endpoint (so no ramp endpoint id falls outside the grid), one
## walkable_query per tier (tier == layer index), and the ramps verbatim.
static func build(layers: Array, ramps: Array) -> NavGraph:
	var region := compute_region(layers)
	for ramp: NavRamp in ramps:
		region = _merge_cell(region, ramp.low_cell)
		region = _merge_cell(region, ramp.high_cell)
	var queries: Array = []
	for layer in layers:
		queries.append(walkable_query(layer))
	return NavGraph.new(layers.size(), region, queries, ramps)

## Builds a NavGraph from an UNTYPED (duck-typed) map_system: reads its
## `elevation_layers` Array, else probes get_elevation_layer(i) until null, and
## delegates to build(). A null map_system returns null (no map -> no graph).
static func from_map_system(map_system, ramps: Array) -> NavGraph:
	if map_system == null:
		return null
	return build(_collect_layers(map_system), ramps)

# --- helpers ---

## Grows `region` to contain `cell`. Seeds from a 1x1 rect at `cell` when the
## region is still empty (size zero) so merge never re-drags in the origin.
static func _merge_cell(region: Rect2i, cell: Vector2i) -> Rect2i:
	var one := Rect2i(cell, Vector2i(1, 1))
	if region.size == Vector2i.ZERO:
		return one
	return region.merge(one)

## The tier-ordered layer stack of a duck-typed map_system: its `elevation_layers`
## Array when present, else get_elevation_layer(i) probed from 0 until null.
static func _collect_layers(map_system) -> Array:
	var out: Array = []
	var raw = map_system.get("elevation_layers")
	if raw is Array:
		for layer in raw:
			out.append(layer)
		return out
	if map_system.has_method("get_elevation_layer"):
		var i := 0
		while i < 4096:  # hard cap: a null return is the real terminator.
			var layer = map_system.get_elevation_layer(i)
			if layer == null:
				break
			out.append(layer)
			i += 1
	return out
