extends GdTest
## Runtime tests for TerrainVariation (#232) against a live TileMapLayer built with
## the real terrain TileSet. Proves the variation pass: assigns in-range per-cell
## alternatives, is deterministic/idempotent, actually spreads variants across a
## field, and -- the correctness-critical one -- keeps varied grass WALKABLE (each
## alternative carries its own TileData, so nav would break if variants defaulted
## to non-walkable). Executed headlessly: godot --headless --script <this file>.

const GRASS := TileSetConstants.INTERIOR_GRASS_MASK  # corner mask 15 -> interior grass


func _run() -> void:
	var ts := _build_tileset()
	_test_alts_in_range(ts)
	_test_idempotent(ts)
	_test_variation_spreads(ts)
	_test_variants_stay_walkable(ts)
	_test_null_layer_is_noop()


## Terrain TileSet from an in-memory texture (no asset-import dependency), matching
## test_tileset_builder's headless pattern.
func _build_tileset() -> TileSet:
	var img := Image.create(TileSetConstants.ATLAS_PX.x, TileSetConstants.ATLAS_PX.y, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)
	return TileSetBuilder.build_terrain_tileset(tex)


## A fresh layer filled with interior grass over an w x h block from (0,0).
func _grass_layer(ts: TileSet, w: int, h: int) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	var src_id := ts.get_source_id(0)
	var coord := TileSetConstants.interior_grass_coord()
	for y in range(h):
		for x in range(w):
			layer.set_cell(Vector2i(x, y), src_id, coord, 0)
	return layer


## Every grass cell gets an alternative in [0, GRASS_VARIANTS) after the pass.
func _test_alts_in_range(ts: TileSet) -> void:
	var layer := _grass_layer(ts, 12, 12)
	TerrainVariation.apply(layer)
	var count := TileSetConstants.GRASS_VARIANTS
	var ok := true
	for cell in layer.get_used_cells():
		var alt := layer.get_cell_alternative_tile(cell)
		if alt < 0 or alt >= count:
			ok = false
	_ok(ok, "a grass cell got an alternative outside [0, %d)" % count)
	layer.free()


## Re-applying the pass produces the same alternatives (deterministic => idempotent
## across reloads; the chosen alt round-trips on disk unchanged).
func _test_idempotent(ts: TileSet) -> void:
	var layer := _grass_layer(ts, 10, 10)
	TerrainVariation.apply(layer)
	var first: Dictionary = {}
	for cell in layer.get_used_cells():
		first[cell] = layer.get_cell_alternative_tile(cell)
	TerrainVariation.apply(layer)
	var same := true
	for cell in layer.get_used_cells():
		if layer.get_cell_alternative_tile(cell) != first[cell]:
			same = false
	_ok(same, "TerrainVariation.apply is not idempotent")
	layer.free()


## Over a block the pass actually uses more than one variant (otherwise it would
## not break the grid at all).
func _test_variation_spreads(ts: TileSet) -> void:
	var layer := _grass_layer(ts, 16, 16)
	TerrainVariation.apply(layer)
	var seen: Dictionary = {}
	for cell in layer.get_used_cells():
		seen[layer.get_cell_alternative_tile(cell)] = true
	_ok(seen.size() > 1, "variation collapsed to a single alternative")
	layer.free()


## The correctness-critical check: a varied (alt > 0) grass cell must still read as
## walkable through the exact probe navigation uses, so variants never punch holes
## in the walkable field. Asserts we actually exercised a non-base alternative.
func _test_variants_stay_walkable(ts: TileSet) -> void:
	var layer := _grass_layer(ts, 16, 16)
	TerrainVariation.apply(layer)
	var probe := NavMapBuilder.walkable_query(layer)
	var all_walkable := true
	var hit_variant := false
	for cell in layer.get_used_cells():
		if layer.get_cell_alternative_tile(cell) > 0:
			hit_variant = true
		if not bool(probe.call(cell)):
			all_walkable = false
	_ok(all_walkable, "a varied grass cell read as non-walkable (broken nav)")
	_ok(hit_variant, "no non-base alternative was exercised; walkability check is vacuous")
	layer.free()


## A null layer is a safe no-op (no crash).
func _test_null_layer_is_noop() -> void:
	TerrainVariation.apply(null)
	_ok(true, "apply(null) did not crash")
