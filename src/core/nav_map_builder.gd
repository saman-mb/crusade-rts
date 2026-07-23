class_name NavMapBuilder
extends RefCounted
## Thin runtime adapter: turns a stack of live elevation TileMapLayers into a
## headless NavGraph. ALL pathfinding logic lives in the cores (NavGraph /
## NavTierGrid / NavPortalGraph) -- this file only reads the live TileSet API
## (get_used_rect / get_cell_tile_data) and wires the pieces together. A tile is
## walkable on a tier iff that tier's layer paints a real tile there AND that
## tile's `walkable` custom data is true (see walkable_query); an empty cell
## (no tile == hole/cliff) or a tile flagged unwalkable (e.g. water) is solid.
## NavRamps are DERIVED from painted ramp tiles (see ramps_from_layers): a tile
## whose `ramp` custom data is true on a high tier links to each walkable lower
## neighbour on the tier below (from_map_system runs this automatically).

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

## A (cell -> bool) ramp probe closed over one layer, MIRRORING walkable_query:
## true iff a tile is painted at `cell` AND that tile's `ramp` custom-data
## (TileSetConstants.RAMP_LAYER) is true. Unlike walkability, ramp defaults to
## FALSE when the semantics are absent -- an empty cell answers false, and a
## layer whose TileSet carries no `ramp` custom-data layer (minimal test
## tilesets) answers false everywhere (no ramp tiles == no derived ramps). Null-
## safe: a null layer answers false everywhere. The layer-presence lookup is
## resolved ONCE outside the closure so every probe stays O(1).
static func ramp_query(layer) -> Callable:
	if layer == null:
		return func(_cell: Vector2i) -> bool: return false
	var ts: TileSet = layer.tile_set
	var has_layer: bool = ts != null and ts.get_custom_data_layer_by_name(TileSetConstants.RAMP_LAYER) != -1
	return func(cell: Vector2i) -> bool:
		if not has_layer:           # tileset carries no ramp semantics -> no ramp tiles anywhere
			return false
		var data: TileData = layer.get_cell_tile_data(cell)
		if data == null:            # empty cell -> not a ramp
			return false
		var value: Variant = data.get_custom_data(TileSetConstants.RAMP_LAYER)
		return bool(value)

## Derives NavRamps from painted ramp tiles across the tier stack (#78). For each
## adjacent tier pair (low = tier-1, high = tier), every HIGH cell flagged a ramp
## tile (ramp_query) is linked to each of its four cartesian neighbours that is
## walkable on the LOW tier (walkable_query) -- one NavRamp per such neighbour,
## low endpoint on tier-1, high endpoint (the ramp tile) on tier. Deterministic:
## ramp cells are sorted (Vector2i sorts by x then y) and neighbours emitted in a
## fixed OFFSETS order, so the ramp list is stable across runs. Nulls are skipped;
## a high cell with no walkable lower neighbour contributes nothing.
static func ramps_from_layers(layers: Array) -> Array[NavRamp]:
	var ramps: Array[NavRamp] = []
	const OFFSETS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for tier in range(1, layers.size()):
		var high = layers[tier]
		var low = layers[tier - 1]
		if high == null or low == null:
			continue
		var is_ramp: Callable = ramp_query(high)
		var low_walk: Callable = walkable_query(low)
		var ramp_cells: Array[Vector2i] = []
		for hc: Vector2i in high.get_used_cells():
			if is_ramp.call(hc):
				ramp_cells.append(hc)
		ramp_cells.sort()   # deterministic emission order (Vector2i sorts by x then y)
		for hc: Vector2i in ramp_cells:
			for off: Vector2i in OFFSETS:
				var nc: Vector2i = hc + off
				var walkable: bool = low_walk.call(nc)
				if walkable:
					ramps.append(NavRamp.new(nc, tier - 1, hc, tier))
	return ramps

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
## `elevation_layers` Array, else probes get_elevation_layer(i) until null. Ramps
## are DERIVED from the painted ramp tiles (ramps_from_layers); `extra_ramps` is
## an optional override appended verbatim after the derived set (e.g. tests or
## scripted transitions). A null map_system returns null (no map -> no graph).
static func from_map_system(map_system, extra_ramps: Array = []) -> NavGraph:
	if map_system == null:
		return null
	var layers: Array = _collect_layers(map_system)
	var ramps: Array = ramps_from_layers(layers)
	for r in extra_ramps:
		ramps.append(r)
	return build(layers, ramps)

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
