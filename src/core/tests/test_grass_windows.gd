extends GdTest
## Tests for the positional mega-tile window system (TileSetConstants window math
## + MapSerializer normalization). The window scheme is what makes the ground
## artwork seamless, so its invariants are load-bearing: stable positional
## mapping (incl. negative cells), all 32 windows distinct and colliding with no
## other tile coord, correct walkability classification, and save-normalization
## back to the canonical painted tiles so map files stay backward-compatible.


func _run() -> void:
	_test_window_index_range()
	_test_positional_determinism()
	_test_period()
	_test_negative_cells()
	_test_windows_distinct()
	_test_no_coord_collisions()
	_test_classification()
	_test_serializer_normalizes()


## window_index lands in [0, 32) over a big block incl. negatives.
func _test_window_index_range() -> void:
	var ok := true
	for y in range(-9, 9):
		for x in range(-9, 9):
			var idx := TileSetConstants.window_index(Vector2i(x, y))
			if idx < 0 or idx >= 32:
				ok = false
	_ok(ok, "window_index out of [0, 32)")


## Same cell -> same window, always.
func _test_positional_determinism() -> void:
	var same := true
	for i in range(40):
		var cell := Vector2i(i * 5 - 17, 23 - i * 3)
		if TileSetConstants.grass_window_coord(cell) != TileSetConstants.grass_window_coord(cell):
			same = false
	_ok(same, "grass_window_coord not deterministic")


## The window class repeats exactly on the (8,0)/(0,8) cell lattice -- the
## period that matches the mega texture's (512, 256) px screen period.
func _test_period() -> void:
	var ok := true
	for y in range(-4, 5):
		for x in range(-4, 5):
			var c := Vector2i(x, y)
			if TileSetConstants.window_index(c) != TileSetConstants.window_index(c + Vector2i(8, 0)):
				ok = false
			if TileSetConstants.window_index(c) != TileSetConstants.window_index(c + Vector2i(0, 8)):
				ok = false
			if TileSetConstants.window_index(c) != TileSetConstants.window_index(c + Vector2i(4, 4)):
				ok = false
	_ok(ok, "window class does not repeat on the expected lattice")


## Negative cells map like their positive lattice-mates (posmod, not %).
func _test_negative_cells() -> void:
	_i_eq(TileSetConstants.window_index(Vector2i(-8, -8)),
		TileSetConstants.window_index(Vector2i(0, 0)), "(-8,-8) != (0,0) class")
	_i_eq(TileSetConstants.window_index(Vector2i(-3, -5)),
		TileSetConstants.window_index(Vector2i(5, 3)), "(-3,-5) != (5,3) class")


## All 32 window indices actually occur over one period block.
func _test_windows_distinct() -> void:
	var seen := {}
	for y in range(8):
		for x in range(8):
			seen[TileSetConstants.window_index(Vector2i(x, y))] = true
	_i_eq(seen.size(), 32, "not all 32 window classes occur over an 8x8 block")


## Window coords collide with no LOOKUP / water / ramp coord.
func _test_no_coord_collisions() -> void:
	var ok := true
	for y in range(8):
		for x in range(8):
			var g := TileSetConstants.grass_window_coord(Vector2i(x, y))
			var w := TileSetConstants.water_window_coord(Vector2i(x, y))
			if TileSetConstants.LOOKUP.has(g) or TileSetConstants.LOOKUP.has(w):
				ok = false
			if g == TileSetConstants.WATER_ANIM_COORDS or w == TileSetConstants.WATER_ANIM_COORDS:
				ok = false
			if TileSetConstants.RAMP_COORDS.has(g) or TileSetConstants.RAMP_COORDS.has(w):
				ok = false
			if g == w:
				ok = false
	_ok(ok, "a window coord collides with another tile coord")


## is_grass/water predicates and walkability classify windows correctly.
func _test_classification() -> void:
	var g := TileSetConstants.grass_window_coord(Vector2i(3, 2))
	var w := TileSetConstants.water_window_coord(Vector2i(3, 2))
	_ok(TileSetConstants.is_grass_coord(g), "grass window not is_grass_coord")
	_ok(TileSetConstants.is_grass_coord(TileSetConstants.interior_grass_coord()), "(3,3) not is_grass_coord")
	_ok(TileSetConstants.is_water_coord(w), "water window not is_water_coord")
	_ok(TileSetConstants.is_water_coord(TileSetConstants.WATER_ANIM_COORDS), "(0,4) not is_water_coord")
	_ok(not TileSetConstants.is_grass_coord(w), "water window claims grass")
	_ok(not TileSetConstants.is_water_coord(g), "grass window claims water")
	_ok(TileSetConstants.coord_walkable(g), "grass window not walkable")
	_ok(not TileSetConstants.coord_walkable(w), "water window walkable (nav hole lost)")
	_ok(not TileSetConstants.coord_ramp(g) and not TileSetConstants.coord_ramp(w), "window claims ramp")


## Serializing a remapped layer writes ONLY canonical tiles (interior grass /
## legacy water, alt 0), so saves stay readable by older builds; and loading +
## re-applying reproduces the identical window field (full round trip).
func _test_serializer_normalizes() -> void:
	var img := Image.create(TileSetConstants.ATLAS_PX.x, TileSetConstants.ATLAS_PX.y, false, Image.FORMAT_RGBA8)
	var ts := TileSetBuilder.build_terrain_tileset(ImageTexture.create_from_image(img))
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	var src_id := ts.get_source_id(0)
	for y in range(6):
		for x in range(6):
			layer.set_cell(Vector2i(x, y), src_id,
				TileSetConstants.interior_grass_coord() if x < 4 else TileSetConstants.WATER_ANIM_COORDS, 0)
	TerrainVariation.apply(layer)
	var cells: Array = MapSerializer.serialize_layer(layer)
	var canonical := true
	for cdict in cells:
		var a: Array = cdict[MapSchema.KEY_CELL_ATLAS]
		var coord := Vector2i(int(a[0]), int(a[1]))
		var alt := int(cdict[MapSchema.KEY_CELL_ALT])
		if TileSetConstants.is_grass_window_coord(coord) or TileSetConstants.is_water_window_coord(coord):
			canonical = false
		if not (coord == TileSetConstants.interior_grass_coord() or coord == TileSetConstants.WATER_ANIM_COORDS):
			canonical = false
		if alt != 0:
			canonical = false
	_i_eq(cells.size(), 36, "serialized cell count")
	_ok(canonical, "serializer leaked window coords / nonzero alt into the doc")

	# Round trip: rebuild a layer from the doc, re-apply, expect identical coords.
	var layer2 := TileMapLayer.new()
	layer2.tile_set = ts
	for cdict in cells:
		var p: Array = cdict[MapSchema.KEY_CELL_POS]
		var a2: Array = cdict[MapSchema.KEY_CELL_ATLAS]
		layer2.set_cell(Vector2i(int(p[0]), int(p[1])), int(cdict[MapSchema.KEY_CELL_SOURCE]),
			Vector2i(int(a2[0]), int(a2[1])), int(cdict[MapSchema.KEY_CELL_ALT]))
	TerrainVariation.apply(layer2)
	var same := true
	for cell in layer.get_used_cells():
		if layer.get_cell_atlas_coords(cell) != layer2.get_cell_atlas_coords(cell):
			same = false
	_ok(same, "save -> load -> re-apply did not reproduce the window field")
	layer.free()
	layer2.free()
