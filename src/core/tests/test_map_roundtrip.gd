extends SceneTree
## End-to-end integration proof for the map save/load pipeline: the
## paint -> serialize -> atomic file write -> read back -> load-into-fresh-layers
## round-trip preserves every cell (pos, source, atlas, alt) across all elevation
## layers with no loss and no cross-layer bleed. Authored + statically checked now,
## executed once a binary is available: godot --headless --script <this file>.
##
## Drives REAL Godot 4.4 TileMapLayer nodes under an in-memory TileSet (no GPU /
## atlas file). Every painted cell uses atlas (0,0) / alt 0 -- the only tile the
## freshly create_tile'd atlas source owns -- so all cells survive MapValidator on
## load; a nonzero atlas or alt would be dropped as invalid.

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
	var ts := _build_tileset()
	var sid := ts.get_source_id(0)

	# --- 3 SOURCE layers, distinct painted cells, all atlas (0,0) / alt 0. ---
	var src0 := TileMapLayer.new()
	src0.tile_set = ts
	root.add_child(src0)
	var src1 := TileMapLayer.new()
	src1.tile_set = ts
	root.add_child(src1)
	var src2 := TileMapLayer.new()
	src2.tile_set = ts
	root.add_child(src2)

	src0.set_cell(Vector2i(1, 1), sid, Vector2i(0, 0), 0)
	src0.set_cell(Vector2i(2, 3), sid, Vector2i(0, 0), 0)
	src1.set_cell(Vector2i(4, 4), sid, Vector2i(0, 0), 0)
	src2.set_cell(Vector2i(0, 0), sid, Vector2i(0, 0), 0)
	src2.set_cell(Vector2i(5, 6), sid, Vector2i(0, 0), 0)

	var names: Array[String] = ["ground", "mid", "top"]
	var elevations: Array[int] = [0, 1, 2]

	var doc := MapSerializer.serialize_layers([src0, src1, src2], names, elevations)

	var path := "user://test_map_roundtrip.json"
	_cleanup_files(path)

	# --- Atomic file write, then read back. ---
	_ok(MapFileIO.save_text(path, MapSerializer.to_json(doc)), "atomic save ok")
	var r := MapFileIO.load_text(path)
	_ok(r["ok"], "read back ok")

	# --- 3 FRESH DESTINATION layers, same TileSet. ---
	var dst0 := TileMapLayer.new()
	dst0.tile_set = ts
	root.add_child(dst0)
	var dst1 := TileMapLayer.new()
	dst1.tile_set = ts
	root.add_child(dst1)
	var dst2 := TileMapLayer.new()
	dst2.tile_set = ts
	root.add_child(dst2)
	var dst: Array[TileMapLayer] = [dst0, dst1, dst2]

	# Pre-dirty a destination cell to prove the loader clears each layer first.
	dst0.set_cell(Vector2i(9, 9), sid, Vector2i(0, 0), 0)

	var res := MapLoader.load_into_layers(r["text"], dst, ts)
	_ok(res["ok"], "load ok")

	# The pre-dirtied stale cell must be gone after load.
	_i_eq(dst0.get_cell_source_id(Vector2i(9, 9)), -1, "loader cleared stale cell")

	# Each destination layer's used-cell set equals its original source layer's set.
	_ok(_same_cell_set(dst0, src0), "dst0 cell set == src0")
	_ok(_same_cell_set(dst1, src1), "dst1 cell set == src1")
	_ok(_same_cell_set(dst2, src2), "dst2 cell set == src2")

	# Source / atlas / alt survived the round-trip, one representative cell per layer.
	_i_eq(dst0.get_cell_source_id(Vector2i(1, 1)), sid, "dst0 (1,1) source survived")
	_v_eq(dst0.get_cell_atlas_coords(Vector2i(1, 1)), Vector2i(0, 0), "dst0 (1,1) atlas survived")
	_i_eq(dst0.get_cell_alternative_tile(Vector2i(1, 1)), 0, "dst0 (1,1) alt survived")

	_i_eq(dst1.get_cell_source_id(Vector2i(4, 4)), sid, "dst1 (4,4) source survived")
	_v_eq(dst1.get_cell_atlas_coords(Vector2i(4, 4)), Vector2i(0, 0), "dst1 (4,4) atlas survived")
	_i_eq(dst1.get_cell_alternative_tile(Vector2i(4, 4)), 0, "dst1 (4,4) alt survived")

	_i_eq(dst2.get_cell_source_id(Vector2i(5, 6)), sid, "dst2 (5,6) source survived")
	_v_eq(dst2.get_cell_atlas_coords(Vector2i(5, 6)), Vector2i(0, 0), "dst2 (5,6) atlas survived")
	_i_eq(dst2.get_cell_alternative_tile(Vector2i(5, 6)), 0, "dst2 (5,6) alt survived")

	# No cross-layer bleed: src0's (1,1) must not leak into layer 1.
	_i_eq(dst1.get_cell_source_id(Vector2i(1, 1)), -1, "no cross-bleed src0 -> dst1")

	# Exact cell counts per layer.
	_i_eq(dst0.get_used_cells().size(), 2, "dst0 cell count == 2")
	_i_eq(dst1.get_used_cells().size(), 1, "dst1 cell count == 1")
	_i_eq(dst2.get_used_cells().size(), 2, "dst2 cell count == 2")

	# --- Cleanup: free live nodes and remove the on-disk artifacts (never fails suite). ---
	src0.queue_free()
	src1.queue_free()
	src2.queue_free()
	dst0.queue_free()
	dst1.queue_free()
	dst2.queue_free()
	_cleanup_files(path)

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

## Exact Vector2i equality check with message.
func _v_eq(a: Vector2i, b: Vector2i, msg: String) -> void:
	_ok(a == b, "%s: expected %s got %s" % [msg, b, a])

## Order-independent equality of two layers' used-cell sets, via Dictionary
## membership (get_used_cells() order is not guaranteed by Godot).
func _same_cell_set(a: TileMapLayer, b: TileMapLayer) -> bool:
	var ca := a.get_used_cells()
	var cb := b.get_used_cells()
	if ca.size() != cb.size():
		return false
	var seen: Dictionary = {}
	for c in ca:
		seen[c] = true
	for c in cb:
		if not seen.has(c):
			return false
	return true

## Removes the json artifact plus its atomic-write siblings (.tmp/.bak) if present.
## Guarded so a missing file is a no-op and never trips the suite.
func _cleanup_files(path: String) -> void:
	for p in [path, path + ".tmp", path + ".bak"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)

## Builds a minimal isometric DIAMOND_DOWN TileSet with a single atlas source whose
## tile (0,0) exists, backed by an in-memory ImageTexture (no GPU/atlas file), so
## set_cell has a valid source_id + atlas coord. Only atlas (0,0) exists -- every
## painted cell must use it (alt 0) to survive validation on load.
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
