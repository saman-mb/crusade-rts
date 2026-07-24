extends GdTest
## Runtime tests for TerrainVariation against a live TileMapLayer built with the
## real terrain TileSet. The pass now remaps solid grass / water onto POSITIONAL
## mega-tile window coords (seamless mega-texture crops), so the contract is:
## every grass cell shows grass_window_coord(cell) with alt 0, water shows its
## water window, remapping is deterministic/idempotent, remapped grass stays
## WALKABLE and remapped water stays NON-walkable (each window tile carries its
## own custom data), and transition/ramp tiles are untouched.


func _run() -> void:
	var ts := _build_tileset()
	_test_grass_remap(ts)
	_test_water_remap(ts)
	_test_legacy_alt_healed(ts)
	_test_idempotent(ts)
	_test_transitions_untouched(ts)
	_test_walkability(ts)
	_test_null_layer_is_noop()


## Terrain TileSet from an in-memory texture (no asset-import dependency).
func _build_tileset() -> TileSet:
	var img := Image.create(TileSetConstants.ATLAS_PX.x, TileSetConstants.ATLAS_PX.y, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)
	return TileSetBuilder.build_terrain_tileset(tex)


## A fresh layer with a w x h block of `coord` painted from `origin`.
func _painted_layer(ts: TileSet, coord: Vector2i, w: int, h: int, origin: Vector2i = Vector2i.ZERO, alt: int = 0) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	var src_id := ts.get_source_id(0)
	for y in range(h):
		for x in range(w):
			layer.set_cell(origin + Vector2i(x, y), src_id, coord, alt)
	return layer


## Every painted-grass cell remaps to exactly its positional window, alt 0.
## Negative cells included (posmod correctness).
func _test_grass_remap(ts: TileSet) -> void:
	var layer := _painted_layer(ts, TileSetConstants.interior_grass_coord(), 12, 12, Vector2i(-6, -6))
	TerrainVariation.apply(layer)
	var ok := true
	for cell in layer.get_used_cells():
		if layer.get_cell_atlas_coords(cell) != TileSetConstants.grass_window_coord(cell):
			ok = false
		if layer.get_cell_alternative_tile(cell) != 0:
			ok = false
	_ok(ok, "a grass cell did not remap to its positional window with alt 0")
	layer.free()


## Painted water (legacy animated tile) remaps to its positional water window.
func _test_water_remap(ts: TileSet) -> void:
	var layer := _painted_layer(ts, TileSetConstants.WATER_ANIM_COORDS, 8, 8)
	TerrainVariation.apply(layer)
	var ok := true
	for cell in layer.get_used_cells():
		if layer.get_cell_atlas_coords(cell) != TileSetConstants.water_window_coord(cell):
			ok = false
	_ok(ok, "a water cell did not remap to its positional window")
	layer.free()


## A legacy save's flip alternative (alt 1..3 on interior grass) is healed to a
## window with alt 0 rather than surviving the remap.
func _test_legacy_alt_healed(ts: TileSet) -> void:
	var layer := _painted_layer(ts, TileSetConstants.interior_grass_coord(), 4, 4, Vector2i.ZERO, 2)
	TerrainVariation.apply(layer)
	var ok := true
	for cell in layer.get_used_cells():
		if layer.get_cell_alternative_tile(cell) != 0:
			ok = false
		if not TileSetConstants.is_grass_window_coord(layer.get_cell_atlas_coords(cell)):
			ok = false
	_ok(ok, "a legacy flip alt survived the window remap")
	layer.free()


## Re-applying reproduces identical coords (deterministic => idempotent, and a
## reloaded already-remapped map re-derives the same field).
func _test_idempotent(ts: TileSet) -> void:
	var layer := _painted_layer(ts, TileSetConstants.interior_grass_coord(), 10, 10)
	TerrainVariation.apply(layer)
	var first: Dictionary = {}
	for cell in layer.get_used_cells():
		first[cell] = layer.get_cell_atlas_coords(cell)
	TerrainVariation.apply(layer)
	var same := true
	for cell in layer.get_used_cells():
		if layer.get_cell_atlas_coords(cell) != first[cell]:
			same = false
	_ok(same, "TerrainVariation.apply is not idempotent")
	layer.free()


## Transition (non-interior) and ramp tiles are untouched by the pass.
func _test_transitions_untouched(ts: TileSet) -> void:
	var edge := TileSetConstants.LOOKUP[5]   # a partial-mask transition tile
	var layer := _painted_layer(ts, edge, 4, 4)
	var src_id := ts.get_source_id(0)
	layer.set_cell(Vector2i(9, 9), src_id, TileSetConstants.RAMP_COORDS[0], 0)
	TerrainVariation.apply(layer)
	var ok := true
	for y in range(4):
		for x in range(4):
			if layer.get_cell_atlas_coords(Vector2i(x, y)) != edge:
				ok = false
	_ok(ok, "a transition tile was remapped")
	_v_eq(layer.get_cell_atlas_coords(Vector2i(9, 9)), TileSetConstants.RAMP_COORDS[0], "ramp tile touched")
	layer.free()


## The correctness-critical check, via the exact probe navigation uses: remapped
## grass stays walkable, remapped water stays a nav hole. Guards vacuousness by
## asserting cells actually moved onto window coords.
func _test_walkability(ts: TileSet) -> void:
	var grass := _painted_layer(ts, TileSetConstants.interior_grass_coord(), 8, 8)
	TerrainVariation.apply(grass)
	var probe := NavMapBuilder.walkable_query(grass)
	var all_walkable := true
	var on_windows := true
	for cell in grass.get_used_cells():
		if not bool(probe.call(cell)):
			all_walkable = false
		if not TileSetConstants.is_grass_window_coord(grass.get_cell_atlas_coords(cell)):
			on_windows = false
	_ok(all_walkable, "a remapped grass cell read as non-walkable (broken nav)")
	_ok(on_windows, "grass cells not on window coords; walkability check is vacuous")
	grass.free()

	var water := _painted_layer(ts, TileSetConstants.WATER_ANIM_COORDS, 6, 6)
	TerrainVariation.apply(water)
	var wprobe := NavMapBuilder.walkable_query(water)
	var none_walkable := true
	for cell in water.get_used_cells():
		if bool(wprobe.call(cell)):
			none_walkable = false
	_ok(none_walkable, "a remapped water cell read as walkable (nav hole lost)")
	water.free()


## A null layer is a safe no-op (no crash).
func _test_null_layer_is_noop() -> void:
	TerrainVariation.apply(null)
	_ok(true, "apply(null) did not crash")
