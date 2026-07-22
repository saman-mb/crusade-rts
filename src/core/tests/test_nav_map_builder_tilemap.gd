extends GdTest
## Runtime tests that drive NavMapBuilder against REAL Godot 4.4 TileMapLayer
## nodes. Requires a Godot 4.4 runtime; authored + statically checked now,
## executed once a binary is available: godot --headless --script <this file>.
## Proves the thin adapter reads the live TileSet API (get_used_rect /
## get_cell_source_id) and hands the cores a NavGraph whose multi-tier
## find_path only crosses tiers where a NavRamp says it may.
##
## Godot 4.4 signatures (NO leading layer arg -- 4.4 dropped it):
##   set_cell(coords, source_id := -1, atlas_coords := Vector2i(-1,-1), alternative := 0)
##   get_cell_source_id(coords); get_used_rect(); get_used_cells().


## Duck-typed MapSystem stand-in exposing `elevation_layers` (the primary path).
class MapSystemStub extends RefCounted:
	var elevation_layers: Array = []

## Duck-typed stand-in WITHOUT `elevation_layers` -- exercises the
## get_elevation_layer(i)-until-null probe fallback in NavMapBuilder.
class MapSystemProbeStub extends RefCounted:
	var _layers: Array = []
	func get_elevation_layer(i: int):
		if i < 0 or i >= _layers.size():
			return null
		return _layers[i]

func _run() -> void:
	var ts := _build_tileset()
	var source_id := ts.get_source_id(0)
	var atlas := Vector2i(0, 0)  ## tile (0,0) exists on the source below -> a valid cell.

	# Tier 0: a horizontal strip with a HOLE/cliff gap at x in {3,4}.
	var layer0 := TileMapLayer.new()
	layer0.tile_set = ts
	root.add_child(layer0)
	for x: int in [0, 1, 2, 5, 6]:
		layer0.set_cell(Vector2i(x, 0), source_id, atlas)
	layer0.update_internals()

	# Tier 1: a short vertical strip climbing away from the ramp foot.
	var layer1 := TileMapLayer.new()
	layer1.tile_set = ts
	root.add_child(layer1)
	for y: int in [1, 2, 3]:
		layer1.set_cell(Vector2i(2, y), source_id, atlas)
	layer1.update_internals()

	var painted0 := Vector2i(2, 0)   ## walkable on tier 0.
	var hole := Vector2i(3, 0)       ## in-region but unpainted -> cliff/hole on tier 0.
	var painted1 := Vector2i(2, 1)   ## walkable on tier 1 (ramp top / foot of strip).
	var way_off := Vector2i(100, 100)

	_test_compute_region(layer0, layer1, painted0, painted1, way_off)
	_test_walkable_query(layer0, painted0, hole, way_off)
	_test_null_guards(layer0, layer1)
	_test_cross_tier_path(layer0, layer1, painted0, painted1)
	_test_intra_tier_hole_blocks(layer0, layer1)
	_test_from_map_system(layer0, layer1, painted0, painted1)

	layer0.queue_free()
	layer1.queue_free()


# --- helpers ---

## Same minimal isometric TileSet the brush/iso tilemap tests build: one atlas
## source whose tile (0,0) exists, backed by an in-memory ImageTexture.
func _build_tileset() -> TileSet:
	var ts := TileSet.new()
	ts.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	ts.tile_layout = TileSet.TILE_LAYOUT_DIAMOND_DOWN
	ts.tile_size = MapConstants.TILE_SIZE

	var img := Image.create(
		TileSetConstants.REGION_SIZE.x, TileSetConstants.REGION_SIZE.y, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)

	var src := TileSetAtlasSource.new()
	src.texture = tex
	src.texture_region_size = TileSetConstants.REGION_SIZE
	ts.add_source(src)
	src.create_tile(Vector2i(0, 0))

	return ts

# --- tests ---

## compute_region unions the painted cells of every layer, has area, contains a
## painted cell from each tier, and excludes a far-off cell.
func _test_compute_region(layer0: TileMapLayer, layer1: TileMapLayer, painted0: Vector2i, painted1: Vector2i, way_off: Vector2i) -> void:
	var region := NavMapBuilder.compute_region([layer0, layer1])
	_ok(region.has_area(), "compute_region has area")
	_ok(region.has_point(painted0), "region contains tier-0 painted cell %s" % painted0)
	_ok(region.has_point(painted1), "region contains tier-1 painted cell %s" % painted1)
	_ok(not region.has_point(way_off), "region excludes far-off cell %s" % way_off)

	# All-empty -> a 0-size Rect2i().
	var empty := NavMapBuilder.compute_region([])
	_ok(empty == Rect2i(), "compute_region of no layers == Rect2i()")

## walkable_query answers true on painted ground, false on a hole and off-map,
## and (null-safe) false everywhere for a null layer.
func _test_walkable_query(layer0: TileMapLayer, painted0: Vector2i, hole: Vector2i, way_off: Vector2i) -> void:
	var q := NavMapBuilder.walkable_query(layer0)
	var on_ground: bool = q.call(painted0)
	var on_hole: bool = q.call(hole)
	var off_map: bool = q.call(way_off)
	_ok(on_ground, "walkable_query true on painted cell %s" % painted0)
	_ok(not on_hole, "walkable_query false on hole %s" % hole)
	_ok(not off_map, "walkable_query false off-map %s" % way_off)

	var qnull := NavMapBuilder.walkable_query(null)
	var null_ans: bool = qnull.call(painted0)
	_ok(not null_ans, "walkable_query(null) false without crashing")

## A null entry in the layer array must not crash compute_region, and must yield
## the same region as the array with the null removed.
func _test_null_guards(layer0: TileMapLayer, layer1: TileMapLayer) -> void:
	var with_null := NavMapBuilder.compute_region([layer0, null, layer1])
	var without := NavMapBuilder.compute_region([layer0, layer1])
	_ok(with_null == without, "compute_region ignores null layer: %s vs %s" % [with_null, without])

## A ramp links a tier-0 cell to a tier-1 cell: the multi-tier find_path is
## non-empty, starts/ends at the queried endpoints, and visits both tiers. With
## NO ramps the identical cross-tier query returns [] (cliffs are hard walls).
func _test_cross_tier_path(layer0: TileMapLayer, layer1: TileMapLayer, painted0: Vector2i, painted1: Vector2i) -> void:
	var ramp := NavRamp.new(painted0, 0, painted1, 1)
	var graph := NavMapBuilder.build([layer0, layer1], [ramp])

	var path := graph.find_path(painted0, 0, painted1, 1)
	_ok(not path.is_empty(), "cross-tier find_path is non-empty over a ramp")
	if not path.is_empty():
		var first: Dictionary = path[0]
		var last: Dictionary = path[path.size() - 1]
		var fc: Vector2i = first["cell"]
		var ft: int = first["tier"]
		var lc: Vector2i = last["cell"]
		var lt: int = last["tier"]
		_ok(fc == painted0 and ft == 0, "path starts at (%s,0) got (%s,%d)" % [painted0, fc, ft])
		_ok(lc == painted1 and lt == 1, "path ends at (%s,1) got (%s,%d)" % [painted1, lc, lt])
		var tiers := {}
		for step in path:
			var t: int = step["tier"]
			tiers[t] = true
		_ok(tiers.has(0) and tiers.has(1), "cross-tier path visits both tiers")

	# No ramp -> no way to change tier -> empty path.
	var graph_no_ramp := NavMapBuilder.build([layer0, layer1], [])
	var blocked := graph_no_ramp.find_path(painted0, 0, painted1, 1)
	_ok(blocked.is_empty(), "cross-tier find_path is [] with no ramps")

## Intra-tier hole-blocks through the ADAPTER (#62): tier 0 is painted at
## x in {0,1,2,5,6} with an unpainted cliff gap at x in {3,4}. A same-tier path
## from the left segment to the right segment must be [] (the hole is a hard wall
## and there is no ramp detour), while a path within one segment still routes.
func _test_intra_tier_hole_blocks(layer0: TileMapLayer, layer1: TileMapLayer) -> void:
	var graph := NavMapBuilder.build([layer0, layer1], [])
	var across := graph.find_path(Vector2i(0, 0), 0, Vector2i(6, 0), 0)
	_ok(across.is_empty(), "adapter: same-tier path across the hole gap is []")
	var within := graph.find_path(Vector2i(0, 0), 0, Vector2i(2, 0), 0)
	_ok(not within.is_empty(), "adapter: same-tier path within the left segment routes")

## from_map_system reads a duck-typed stand-in and produces a NavGraph
## equivalent to build(): same region and the same cross-tier path. Covers both
## the `elevation_layers` path and the get_elevation_layer(i) probe fallback,
## plus the null-map_system -> null contract.
func _test_from_map_system(layer0: TileMapLayer, layer1: TileMapLayer, painted0: Vector2i, painted1: Vector2i) -> void:
	var ramp := NavRamp.new(painted0, 0, painted1, 1)
	var reference := NavMapBuilder.build([layer0, layer1], [ramp])
	var ref_path := reference.find_path(painted0, 0, painted1, 1)

	# Primary path: `elevation_layers` Array.
	var stub := MapSystemStub.new()
	stub.elevation_layers = [layer0, layer1]
	var from_stub := NavMapBuilder.from_map_system(stub, [ramp])
	_ok(from_stub.region == reference.region, "from_map_system region == build region")
	var stub_path := from_stub.find_path(painted0, 0, painted1, 1)
	_ok(stub_path == ref_path, "from_map_system path equals build path")

	# Fallback path: get_elevation_layer(i) probe.
	var probe := MapSystemProbeStub.new()
	probe._layers = [layer0, layer1]
	var from_probe := NavMapBuilder.from_map_system(probe, [ramp])
	_ok(from_probe.region == reference.region, "from_map_system (probe) region == build region")
	_ok(not from_probe.find_path(painted0, 0, painted1, 1).is_empty(), "from_map_system (probe) yields a cross-tier path")

	# Null map_system -> null (documented no-map contract).
	var from_null := NavMapBuilder.from_map_system(null, [ramp])
	_ok(from_null == null, "from_map_system(null) returns null")
