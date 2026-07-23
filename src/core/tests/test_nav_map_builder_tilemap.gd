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
	_test_walkable_semantics()

	# Ramp derivation from painted ramp tiles (#78 WU-C).
	_test_ramps_from_layers_valid()
	_test_ramps_from_layers_none()
	_test_ramps_from_layers_no_lower_neighbor()
	_test_ramps_from_layers_multi_neighbor()
	_test_ramps_from_layers_deterministic()
	_test_ramp_query_absent_layer()
	_test_from_map_system_derives()

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

## The REAL terrain TileSet (walkable + ramp custom-data layers populated), built
## in-memory against a blank atlas -- same recipe as _test_walkable_semantics.
## Used by the #78 ramp-derivation tests so ramp_query has a `ramp` layer to read.
func _build_terrain_tileset() -> TileSet:
	var img := Image.create(TileSetConstants.ATLAS_PX.x, TileSetConstants.ATLAS_PX.y, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)
	return TileSetBuilder.build_terrain_tileset(tex)

## A TileMapLayer bound to `ts` and added to root, painting each cell in `cells`
## with the atlas tile at `atlas` (all same source). Caller update_internals() +
## queue_free()s it. Keeps the ramp-derivation tests terse.
func _make_layer(ts: TileSet, cells: Array, atlas: Vector2i) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	root.add_child(layer)
	var source_id := ts.get_source_id(0)
	for c: Vector2i in cells:
		layer.set_cell(c, source_id, atlas)
	layer.update_internals()
	return layer

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

## Per-tile walkability (#96): against a REAL terrain TileSet whose `walkable`
## custom-data layer is populated (ground true, water false), walkable_query must
## read the layer, not bare source presence. Ground cells answer true, a painted
## water cell answers false, an unpainted cell false, and walkable_query(null)
## false. The NavGraph built over the row marks the water cell solid, so a
## same-row path forced straight through it (no detour in a 1-tall region) is [].
func _test_walkable_semantics() -> void:
	var img := Image.create(TileSetConstants.ATLAS_PX.x, TileSetConstants.ATLAS_PX.y, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)
	var ts := TileSetBuilder.build_terrain_tileset(tex)
	var source_id := ts.get_source_id(0)
	var ground_atlas: Vector2i = TileSetConstants.LOOKUP[1]     ## a real, walkable ground tile.
	var water_atlas := TileSetConstants.WATER_ANIM_COORDS       ## the non-walkable water tile.

	# A single ground row with ONE water cell painted inside it (same atlas source).
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	root.add_child(layer)
	for x: int in [0, 1, 2, 3, 4]:
		layer.set_cell(Vector2i(x, 0), source_id, ground_atlas)
	var water := Vector2i(2, 0)
	layer.set_cell(water, source_id, water_atlas)
	layer.update_internals()

	var unpainted := Vector2i(20, 20)

	# walkable_query reads the `walkable` custom-data layer.
	var q := NavMapBuilder.walkable_query(layer)
	_ok(q.call(Vector2i(0, 0)), "walkable_query true on ground cell (0,0)")
	_ok(q.call(Vector2i(4, 0)), "walkable_query true on ground cell (4,0)")
	_ok(not q.call(water), "walkable_query false on painted water cell %s" % water)
	_ok(not q.call(unpainted), "walkable_query false on unpainted cell %s" % unpainted)

	var qnull := NavMapBuilder.walkable_query(null)
	_ok(not qnull.call(water), "walkable_query(null) false everywhere")

	# The NavGraph over this row marks the water cell solid; ground stays walkable.
	var graph := NavMapBuilder.build([layer], [])
	var grid := graph.tier_grid(0)
	_ok(not grid.is_walkable(water), "graph: water cell %s is not walkable" % water)
	_ok(grid.is_walkable(Vector2i(0, 0)), "graph: ground cell (0,0) is walkable")

	# A straight same-row path must cross the water cell; the 1-tall region offers
	# no detour, so the path is [] (water is a hard wall), while a same-side path routes.
	var across := graph.find_path(Vector2i(0, 0), 0, Vector2i(4, 0), 0)
	_ok(across.is_empty(), "graph: path forced across the water cell is []")
	var within := graph.find_path(Vector2i(0, 0), 0, Vector2i(1, 0), 0)
	_ok(not within.is_empty(), "graph: same-side ground path routes")

	layer.queue_free()

## ramps_from_layers derives exactly one NavRamp when a HIGH-tier ramp tile has a
## single walkable LOWER-tier cartesian neighbour: tier-0 ground row incl. (2,0),
## a ramp tile painted at (2,1) on tier 1 -> the sole ramp links (2,0)@0 to
## (2,1)@1 with the default weight 1.0.
func _test_ramps_from_layers_valid() -> void:
	var ts := _build_terrain_tileset()
	var ground: Vector2i = TileSetConstants.LOOKUP[1]
	var ramp_atlas: Vector2i = TileSetConstants.RAMP_COORDS[0]
	var t0 := _make_layer(ts, [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)], ground)
	var t1 := _make_layer(ts, [Vector2i(2, 1)], ramp_atlas)

	var ramps := NavMapBuilder.ramps_from_layers([t0, t1])
	_i_eq(ramps.size(), 1, "ramps_from_layers derives one ramp")
	if ramps.size() == 1:
		var r: NavRamp = ramps[0]
		_v_eq(r.low_cell, Vector2i(2, 0), "derived ramp low_cell")
		_i_eq(r.low_tier, 0, "derived ramp low_tier")
		_v_eq(r.high_cell, Vector2i(2, 1), "derived ramp high_cell")
		_i_eq(r.high_tier, 1, "derived ramp high_tier")
		_ok(r.weight == 1.0, "derived ramp weight is 1.0 got %s" % r.weight)

	t0.queue_free()
	t1.queue_free()

## A plain GROUND tile on the high tier (no `ramp` custom data) yields NO ramps,
## even directly above a walkable lower neighbour -- only painted ramp tiles count.
func _test_ramps_from_layers_none() -> void:
	var ts := _build_terrain_tileset()
	var ground: Vector2i = TileSetConstants.LOOKUP[1]
	var t0 := _make_layer(ts, [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)], ground)
	var t1 := _make_layer(ts, [Vector2i(2, 1)], ground)   ## plain ground, NOT the ramp coord

	_ok(NavMapBuilder.ramps_from_layers([t0, t1]).is_empty(), "plain ground on high tier derives no ramps")

	t0.queue_free()
	t1.queue_free()

## A ramp tile whose four cartesian neighbours are all EMPTY on the tier below
## contributes nothing (a ramp needs a walkable lower endpoint to link to).
func _test_ramps_from_layers_no_lower_neighbor() -> void:
	var ts := _build_terrain_tileset()
	var ground: Vector2i = TileSetConstants.LOOKUP[1]
	var ramp_atlas: Vector2i = TileSetConstants.RAMP_COORDS[0]
	# tier-0 ground sits far from (2,1)'s neighbours {(3,1),(1,1),(2,2),(2,0)}.
	var t0 := _make_layer(ts, [Vector2i(10, 0)], ground)
	var t1 := _make_layer(ts, [Vector2i(2, 1)], ramp_atlas)

	_ok(NavMapBuilder.ramps_from_layers([t0, t1]).is_empty(), "ramp with no walkable lower neighbour derives no ramp")

	t0.queue_free()
	t1.queue_free()

## A ramp tile with TWO walkable lower neighbours emits TWO NavRamps -- one per
## neighbour (the accepted B1 multi-emit). Ramp at (2,1); tier-0 ground at (2,0)
## and (2,2) -> low endpoints are exactly those two cells.
func _test_ramps_from_layers_multi_neighbor() -> void:
	var ts := _build_terrain_tileset()
	var ground: Vector2i = TileSetConstants.LOOKUP[1]
	var ramp_atlas: Vector2i = TileSetConstants.RAMP_COORDS[0]
	var t0 := _make_layer(ts, [Vector2i(2, 0), Vector2i(2, 2)], ground)
	var t1 := _make_layer(ts, [Vector2i(2, 1)], ramp_atlas)

	var ramps := NavMapBuilder.ramps_from_layers([t0, t1])
	_i_eq(ramps.size(), 2, "two walkable lower neighbours derive two ramps")
	var lows := {}
	for r: NavRamp in ramps:
		lows[r.low_cell] = true
		_v_eq(r.high_cell, Vector2i(2, 1), "multi-emit ramp high_cell")
		_i_eq(r.high_tier, 1, "multi-emit ramp high_tier")
		_i_eq(r.low_tier, 0, "multi-emit ramp low_tier")
	_ok(lows.has(Vector2i(2, 0)) and lows.has(Vector2i(2, 2)), "multi-emit low endpoints are (2,0) and (2,2)")

	t0.queue_free()
	t1.queue_free()

## Derivation is deterministic: two calls over the same layers return identical
## endpoint / tier / weight sequences (sorted ramp cells + fixed OFFSETS order).
func _test_ramps_from_layers_deterministic() -> void:
	var ts := _build_terrain_tileset()
	var ground: Vector2i = TileSetConstants.LOOKUP[1]
	var ramp_atlas: Vector2i = TileSetConstants.RAMP_COORDS[0]
	var t0 := _make_layer(ts, [Vector2i(2, 0), Vector2i(2, 2), Vector2i(5, 0)], ground)
	var t1 := _make_layer(ts, [Vector2i(2, 1), Vector2i(5, 1)], ramp_atlas)

	var a := NavMapBuilder.ramps_from_layers([t0, t1])
	var b := NavMapBuilder.ramps_from_layers([t0, t1])
	_i_eq(a.size(), b.size(), "deterministic: same ramp count")
	var identical := a.size() == b.size()
	for i in range(min(a.size(), b.size())):
		var ra: NavRamp = a[i]
		var rb: NavRamp = b[i]
		if ra.low_cell != rb.low_cell or ra.low_tier != rb.low_tier \
				or ra.high_cell != rb.high_cell or ra.high_tier != rb.high_tier or ra.weight != rb.weight:
			identical = false
	_ok(identical, "ramps_from_layers is deterministic across calls")

	t0.queue_free()
	t1.queue_free()

## ramp_query is false everywhere over a MINIMAL tileset (no `ramp` custom-data
## layer) even on a painted cell, and ramp_query(null) is false everywhere --
## mirrors walkable_query's absent-layer / null-layer null-safety, but defaults
## to FALSE (absent ramp semantics == no ramps).
func _test_ramp_query_absent_layer() -> void:
	var ts := _build_tileset()   ## minimal TS: no walkable/ramp custom-data layers.
	var layer := _make_layer(ts, [Vector2i(2, 1)], Vector2i(0, 0))

	var q := NavMapBuilder.ramp_query(layer)
	_ok(not q.call(Vector2i(2, 1)), "ramp_query false on painted cell (absent ramp layer)")
	_ok(not q.call(Vector2i(9, 9)), "ramp_query false on unpainted cell (absent ramp layer)")

	var qnull := NavMapBuilder.ramp_query(null)
	_ok(not qnull.call(Vector2i(2, 1)), "ramp_query(null) false everywhere")

	layer.queue_free()

## from_map_system DERIVES ramps from painted ramp tiles with NO extra_ramps: a
## stub carrying [tier-0 ground, tier-1 ramp] yields a graph whose cross-tier
## find_path (2,0)@0 -> (2,1)@1 is non-empty, starts/ends at the endpoints, and
## visits both tiers. Erasing the ramp cell + rebuilding severs the link -> [].
func _test_from_map_system_derives() -> void:
	var ts := _build_terrain_tileset()
	var ground: Vector2i = TileSetConstants.LOOKUP[1]
	var ramp_atlas: Vector2i = TileSetConstants.RAMP_COORDS[0]
	var t0 := _make_layer(ts, [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)], ground)
	var t1 := _make_layer(ts, [Vector2i(2, 1)], ramp_atlas)

	var stub := MapSystemStub.new()
	stub.elevation_layers = [t0, t1]

	var graph := NavMapBuilder.from_map_system(stub)   ## NO extra ramps -> purely derived.
	var path := graph.find_path(Vector2i(2, 0), 0, Vector2i(2, 1), 1)
	_ok(not path.is_empty(), "from_map_system(derived) cross-tier path is non-empty")
	if not path.is_empty():
		var first: Dictionary = path[0]
		var last: Dictionary = path[path.size() - 1]
		var fc: Vector2i = first["cell"]
		var ft: int = first["tier"]
		var lc: Vector2i = last["cell"]
		var lt: int = last["tier"]
		_ok(fc == Vector2i(2, 0) and ft == 0, "derived path starts at (2,0)@0 got (%s,%d)" % [fc, ft])
		_ok(lc == Vector2i(2, 1) and lt == 1, "derived path ends at (2,1)@1 got (%s,%d)" % [lc, lt])
		var tiers := {}
		for step in path:
			var t: int = step["tier"]
			tiers[t] = true
		_ok(tiers.has(0) and tiers.has(1), "derived cross-tier path visits both tiers")

	# Erase the ramp tile and rebuild: the derived ramp vanishes -> no cross-tier path.
	t1.set_cell(Vector2i(2, 1))   ## source_id defaults to -1 -> clears the cell.
	t1.update_internals()
	var graph_cleared := NavMapBuilder.from_map_system(stub)
	var blocked := graph_cleared.find_path(Vector2i(2, 0), 0, Vector2i(2, 1), 1)
	_ok(blocked.is_empty(), "from_map_system(derived) path is [] once the ramp tile is erased")

	t0.queue_free()
	t1.queue_free()
