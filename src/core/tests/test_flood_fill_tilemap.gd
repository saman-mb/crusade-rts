extends SceneTree
## Runtime tests that drive FloodFill against a REAL Godot 4.4 TileMapLayer + TileSet.
## Requires a Godot 4.4 runtime; authored + statically checked now, executed once a binary
## is available: godot --headless --script <this file>. Proves that compute() integrates with
## the live API -- read wraps get_cell_source_id/get_cell_atlas_coords, neighbors wraps
## get_surrounding_cells -- so ISO neighbor topology is honored and a real painted region fills.
##
## Godot 4.4 signatures (NO leading layer arg -- 4.4 dropped it):
##   set_cell(coords, source_id := -1, atlas_coords := Vector2i(-1,-1), alternative := 0)
##   get_cell_source_id(coords); get_cell_atlas_coords(coords); get_surrounding_cells(coords).

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
	var ts := _build_tileset()
	var source_id := ts.get_source_id(0)
	var atlas_a := Vector2i(0, 0)  ## tile (0,0) created below -> valid cell.
	var atlas_b := Vector2i(1, 0)  ## tile (1,0) created below -> a DIFFERENT valid identity.

	var layer := TileMapLayer.new()
	layer.tile_set = ts
	root.add_child(layer)

	# read/neighbors Callables wrap the live TileMapLayer API (same wrappers the runtime uses).
	var read := func(c: Vector2i) -> Dictionary:
		return { "src": layer.get_cell_source_id(c), "atlas": layer.get_cell_atlas_coords(c) }
	var neighbors := func(c: Vector2i) -> Array[Vector2i]:
		return layer.get_surrounding_cells(c)

	_test_real_region_fill(layer, source_id, atlas_a, atlas_b, read, neighbors)
	_test_unpainted_empty_fill(layer, read, neighbors)

	layer.queue_free()

	print("PASS %d / FAIL %d" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- helpers ---

## Increments counters; prints only on failure so passing runs stay quiet.
func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: %s" % msg)

## Exact int equality check with message.
func _i_eq(a: int, b: int, msg: String) -> void:
	_ok(a == b, "%s: expected %d got %d" % [msg, b, a])

## Minimal isometric DIAMOND_DOWN TileSet with two valid atlas tiles (0,0) and (1,0),
## backed by an in-memory ImageTexture (no GPU/atlas-file dependency). Mirrors the headless
## TileSet construction in test_brush_core_tilemap.gd / test_iso_coord_tilemap.gd.
func _build_tileset() -> TileSet:
	var ts := TileSet.new()
	ts.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	ts.tile_layout = TileSet.TILE_LAYOUT_DIAMOND_DOWN
	ts.tile_size = MapConstants.TILE_SIZE

	# Two texture regions wide so tiles (0,0) and (1,0) both exist.
	var img := Image.create(
		TileSetConstants.REGION_SIZE.x * 2, TileSetConstants.REGION_SIZE.y, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)

	var src := TileSetAtlasSource.new()
	src.texture = tex
	src.texture_region_size = TileSetConstants.REGION_SIZE
	ts.add_source(src)
	src.create_tile(Vector2i(0, 0))
	src.create_tile(Vector2i(1, 0))

	return ts

# --- tests ---

## Paints a genuinely contiguous ISO region (seed + its get_surrounding_cells ring, all
## identical) and asserts compute() returns exactly that set: unpainted neighbors and a
## same-source-but-different-atlas boundary cell are both excluded. Uses the live topology,
## so this proves FloodFill respects iso adjacency, not a hardcoded 4-neighbor grid.
func _test_real_region_fill(
		layer: TileMapLayer, source_id: int, atlas_a: Vector2i, atlas_b: Vector2i,
		read: Callable, neighbors: Callable) -> void:
	var seed := Vector2i(4, 4)

	# The region == seed plus its live iso neighbors, painted identically (src, atlas_a).
	var region: Array[Vector2i] = [seed]
	for n: Vector2i in layer.get_surrounding_cells(seed):
		if not region.has(n):
			region.append(n)
	for c: Vector2i in region:
		layer.set_cell(c, source_id, atlas_a)

	# A boundary cell: a neighbor of the first ring cell, outside the region, painted with a
	# DIFFERENT atlas -> must NOT be swept in (identity = src AND atlas).
	var boundary := Vector2i(-999, -999)
	for n: Vector2i in layer.get_surrounding_cells(region[1]):
		if not region.has(n):
			boundary = n
			break
	if boundary != Vector2i(-999, -999):
		layer.set_cell(boundary, source_id, atlas_b)
	layer.update_internals()

	# Bounds comfortably enclose the whole painted neighborhood.
	var bounds := Rect2i(-20, -20, 40, 40)
	var out := FloodFill.compute(seed, source_id, atlas_a, bounds, read, neighbors, 10000)

	_i_eq(out.size(), region.size(), "real iso region: fills exactly the painted identical set")
	var all_present := true
	for c: Vector2i in region:
		if not out.has(c):
			all_present = false
	_ok(all_present, "real iso region: every painted region cell is in the result")
	_ok(out[0] == seed, "real iso region: BFS order starts at seed")
	if boundary != Vector2i(-999, -999):
		_ok(not out.has(boundary), "real iso region: diff-atlas boundary cell excluded")

## Seed on an UNPAINTED cell (live API reports src -1) fills the empty region within small
## bounds and terminates -- proves the -1 empty identity round-trips through the real API and
## that compute() reproduces the TRUE iso-connected component (computed here by an independent
## BFS so we assert against real topology, not a hardcoded count that iso adjacency may split).
func _test_unpainted_empty_fill(layer: TileMapLayer, read: Callable, neighbors: Callable) -> void:
	# A patch of the map far from any painted cell is all empty (-1).
	var seed := Vector2i(50, 50)
	_i_eq(layer.get_cell_source_id(seed), -1, "unpainted seed reports src -1 via live API")

	var seed_id: Dictionary = read.call(seed)
	var bounds := Rect2i(48, 48, 5, 5)  # 5x5 empty window

	# Independent expected component: BFS the same iso topology, all cells empty in-bounds.
	var expected: Dictionary = {}
	var q: Array[Vector2i] = [seed]
	expected[seed] = true
	var i: int = 0
	while i < q.size():
		var c: Vector2i = q[i]
		i += 1
		for n: Vector2i in layer.get_surrounding_cells(c):
			if not expected.has(n) and bounds.has_point(n):
				expected[n] = true
				q.append(n)

	var out := FloodFill.compute(
		seed, seed_id["src"], seed_id["atlas"], bounds, read, neighbors, 10000)

	_i_eq(out.size(), expected.size(), "unpainted empty fill matches the true iso-connected component size")
	var matches := true
	for c: Vector2i in out:
		if not expected.has(c):
			matches = false
	_ok(matches, "unpainted empty fill contains only cells in the true connected component")
	_ok(out.has(seed), "unpainted empty fill includes the seed")
	_ok(out.size() >= 1 and out.size() <= 25, "unpainted empty fill stays within the 5x5 window and terminates")
