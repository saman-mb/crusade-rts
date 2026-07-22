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
	_test_layers_roundtrip()
	_test_objects_roundtrip()
	_test_alt_roundtrip()

	print("PASS %d / FAIL %d" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Nonzero alternative_tile survives the full save/load round-trip (#44). Every
## other case here paints alt 0; this proves a real alt is serialized and repainted
## rather than silently dropped or clamped to the base tile. Builds a TileSet that
## actually owns an alternative on (0,0) so the cell passes validation on load.
func _test_alt_roundtrip() -> void:
	var ts := _build_tileset()
	var sid := ts.get_source_id(0)
	var src := ts.get_source(sid) as TileSetAtlasSource
	var alt_id := src.create_alternative_tile(Vector2i(0, 0))
	_ok(alt_id > 0, "created a real alternative tile id (%d)" % alt_id)

	var s := TileMapLayer.new()
	s.tile_set = ts
	root.add_child(s)
	s.set_cell(Vector2i(2, 2), sid, Vector2i(0, 0), alt_id)  # nonzero alt

	var doc := MapSerializer.serialize_layers([s], ["ground"], [0])
	var path := "user://test_map_alt_roundtrip.json"
	_cleanup_files(path)
	_ok(MapFileIO.save_text(path, MapSerializer.to_json(doc)), "alt atomic save ok")
	var r := MapFileIO.load_text(path)
	_ok(r["ok"], "alt read back ok")

	var d := TileMapLayer.new()
	d.tile_set = ts
	root.add_child(d)
	var dst: Array[TileMapLayer] = [d]
	var res := MapLoader.load_into_layers(r["text"], dst, ts)
	_ok(res["ok"], "alt load ok")
	_i_eq(d.get_cell_source_id(Vector2i(2, 2)), sid, "alt cell source survived")
	_i_eq(d.get_cell_alternative_tile(Vector2i(2, 2)), alt_id, "nonzero alt survived round-trip")

	s.queue_free()
	d.queue_free()
	_cleanup_files(path)

## The classic terrain-only round-trip: serialize_layers -> save -> load_into_layers.
func _test_layers_roundtrip() -> void:
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

## Objects overlay round-trip (#43): paint terrain elevation layers PLUS a distinct
## objects layer, serialize_map -> save -> load_map into fresh elevation + objects
## targets. Proves object tiles survive save/reload, route to the objects overlay by
## KIND (not elevation), and never cross-bleed into the elevation stack (nor terrain
## into objects). A null objects target on load must drop object cells, not misroute.
func _test_objects_roundtrip() -> void:
	var ts := _build_tileset()
	var sid := ts.get_source_id(0)

	# --- SOURCE: 2 elevation layers + 1 objects layer, distinct cells. ---
	var elev0 := TileMapLayer.new()
	elev0.tile_set = ts
	root.add_child(elev0)
	var elev1 := TileMapLayer.new()
	elev1.tile_set = ts
	root.add_child(elev1)
	var obj := TileMapLayer.new()
	obj.tile_set = ts
	root.add_child(obj)

	elev0.set_cell(Vector2i(1, 1), sid, Vector2i(0, 0), 0)
	elev1.set_cell(Vector2i(2, 2), sid, Vector2i(0, 0), 0)
	# Objects at cells that collide with NO terrain cell, so bleed is detectable.
	obj.set_cell(Vector2i(7, 7), sid, Vector2i(0, 0), 0)
	obj.set_cell(Vector2i(8, 9), sid, Vector2i(0, 0), 0)

	var src_elev: Array[TileMapLayer] = [elev0, elev1]
	var doc := MapSerializer.serialize_map(src_elev, obj)

	# The objects entry must be tagged kind=objects at the OBJECTS_ELEVATION sentinel.
	var found_obj_entry := false
	for entry in doc[MapSchema.KEY_LAYERS]:
		if String(entry[MapSchema.KEY_LAYER_KIND]) == MapSchema.LAYER_KIND_OBJECTS:
			found_obj_entry = true
			_i_eq(int(entry[MapSchema.KEY_LAYER_ELEVATION]), MapSchema.OBJECTS_ELEVATION,
				"objects entry at OBJECTS_ELEVATION sentinel")
	_ok(found_obj_entry, "serialize_map emits an objects-kind entry")

	var path := "user://test_map_objects_roundtrip.json"
	_cleanup_files(path)
	_ok(MapFileIO.save_text(path, MapSerializer.to_json(doc)), "objects atomic save ok")
	var r := MapFileIO.load_text(path)
	_ok(r["ok"], "objects read back ok")

	# --- DESTINATION: fresh elevation stack + fresh objects layer. ---
	var d_elev0 := TileMapLayer.new()
	d_elev0.tile_set = ts
	root.add_child(d_elev0)
	var d_elev1 := TileMapLayer.new()
	d_elev1.tile_set = ts
	root.add_child(d_elev1)
	var d_obj := TileMapLayer.new()
	d_obj.tile_set = ts
	root.add_child(d_obj)
	var dst_elev: Array[TileMapLayer] = [d_elev0, d_elev1]

	# Pre-dirty the objects target to prove load_map clears it too.
	d_obj.set_cell(Vector2i(3, 3), sid, Vector2i(0, 0), 0)

	var res := MapLoader.load_map(r["text"], dst_elev, d_obj, ts)
	_ok(res["ok"], "load_map ok")

	# Stale objects cell gone; object cells landed on the OBJECTS layer only.
	_i_eq(d_obj.get_cell_source_id(Vector2i(3, 3)), -1, "load_map cleared stale objects cell")
	_i_eq(d_obj.get_cell_source_id(Vector2i(7, 7)), sid, "obj (7,7) survived to objects layer")
	_i_eq(d_obj.get_cell_source_id(Vector2i(8, 9)), sid, "obj (8,9) survived to objects layer")
	_i_eq(d_obj.get_used_cells().size(), 2, "objects layer cell count == 2")

	# Terrain survived on its elevation layers.
	_i_eq(d_elev0.get_cell_source_id(Vector2i(1, 1)), sid, "elev0 (1,1) survived")
	_i_eq(d_elev1.get_cell_source_id(Vector2i(2, 2)), sid, "elev1 (2,2) survived")

	# No cross-bleed EITHER direction: objects not on terrain, terrain not on objects.
	_i_eq(d_elev0.get_cell_source_id(Vector2i(7, 7)), -1, "obj cell absent from elev0")
	_i_eq(d_elev1.get_cell_source_id(Vector2i(7, 7)), -1, "obj cell absent from elev1")
	_i_eq(d_obj.get_cell_source_id(Vector2i(1, 1)), -1, "terrain cell absent from objects")

	# --- A terrain-only load target (null objects) must DROP object cells, not crash. ---
	var d2_elev0 := TileMapLayer.new()
	d2_elev0.tile_set = ts
	root.add_child(d2_elev0)
	var d2_elev1 := TileMapLayer.new()
	d2_elev1.tile_set = ts
	root.add_child(d2_elev1)
	var dst2_elev: Array[TileMapLayer] = [d2_elev0, d2_elev1]
	var res2 := MapLoader.load_map(r["text"], dst2_elev, null, ts)
	_ok(res2["ok"], "load_map ok with null objects target")
	_i_eq(d2_elev0.get_cell_source_id(Vector2i(1, 1)), sid, "terrain still loads with null objects")
	_ok((res2["diagnostics"] as Array).size() >= 1, "null objects target yields a diagnostic")
	# Anti-misroute: a dropped object cell must NOT land on any terrain layer.
	_i_eq(d2_elev0.get_cell_source_id(Vector2i(7, 7)), -1, "null-objects: obj cell not misrouted to elev0")
	_i_eq(d2_elev1.get_cell_source_id(Vector2i(7, 7)), -1, "null-objects: obj cell not misrouted to elev1")

	# --- Cleanup. ---
	elev0.queue_free()
	elev1.queue_free()
	obj.queue_free()
	d_elev0.queue_free()
	d_elev1.queue_free()
	d_obj.queue_free()
	d2_elev0.queue_free()
	d2_elev1.queue_free()
	_cleanup_files(path)

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
